# pkgs.hstin.de

One signed apt and dnf repository with the packages of the projects of hstin, their download pages and their signed
update metadata.

## Using it

```sh
# Debian, Ubuntu
cd "$(mktemp -d)" && curl -fsSLO https://pkgs.hstin.de/hstin-repo.deb && sudo apt install ./hstin-repo.deb && sudo apt update
sudo apt install otterlink

# Fedora, RHEL
sudo dnf install https://pkgs.hstin.de/hstin-repo.rpm
sudo dnf install otterlink

# or the script (it installs hstin-repo, then the packages named)
cd "$(mktemp -d)" && curl -fsSLO https://pkgs.hstin.de/install.sh && less install.sh && sudo sh install.sh otterlink
```

`hstin-repo` holds the apt source (`deb https://pkgs.hstin.de/apt stable main`) or dnf repository and the key, so a
change of either arrives as an update. Its packages never replace a distribution package of the same name (apt pin
priority 100, dnf `priority=100`).

Repository key fingerprint: *(added after the key is made)*

## How it works

- Projects only make **GitHub releases** (published, not prereleases, tags `vX.Y.Z`) and keep their signed update
  metadata on their branch `pkgs` (`updates/*.json` + `.json.sig`). Then they start the deploy here
  (`workflow_dispatch`, through the trigger app). They hold no key and no credential of pkgs.
- **`deploy.yml`**, environment `production` (main only):
  - `scripts/sync.sh` reads the releases with the **reader app** (contents: read on the projects). For every release
    not stored yet it checks each asset against the SHA-256 digest GitHub recorded and requires every deb and rpm to
    be named `NAME` or `NAME-*` (so no project can ship `hstin-repo` or another project's package). It signs the rpms
    with the repository key and uploads everything to R2, with `SHA256SUMS` last. A release failing a check stays out,
    with a warning. The newest 8 good releases per project are kept; older ones are removed.
  - `scripts/build.sh` builds the apt and dnf metadata, checks every package against the release's `SHA256SUMS`, and
    signs the metadata. It also builds `hstin-repo`, the pages and the install script.
  - A second job deploys to **Cloudflare Pages** with wrangler from `package-lock.json`. That job never sees the
    repository key.
- **Cloudflare R2** (bucket `hstin-pkgs`, private, written only by `deploy.yml`) holds the release files as
  `NAME/<tag>/<file>`. The Pages functions (`functions/`, `src/dl.js`) serve them under `/apt/pool/`, `/rpm/pool/` and
  `/dl/`, always as downloads (never as pages of this site). Pages takes static files only up to 25 MiB.

### Who holds what

| Secret | Where | Can do | Back up? |
|---|---|---|---|
| `REPO_GPG_KEY` | pkgs, environment `production` | sign the apt/dnf metadata and rpms | **yes**, with the revocation certificate |
| `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` | pkgs, `production` | read/write the bucket | no, make a new token |
| `CLOUDFLARE_ACCOUNT_ID` | pkgs, `production` | (the R2 endpoint, not secret) | no |
| `CLOUDFLARE_API_TOKEN` | pkgs, `production` | deploy any Pages project of the account | no, make a new token |
| `READER_APP_CLIENT_ID`, `READER_APP_KEY` | pkgs, `production` | read the projects' repositories | no, make a new app key |
| `PKGS_APP_CLIENT_ID`, `PKGS_APP_KEY` | each project | start this deploy (actions: write here) | no, make a new app key |

Accepted risks:

- **Function requests** count against the Workers plan (Free: 100,000 a day). Someone can use them up, and then
  `/dl/` and the package pools fail until the next day. Workers Paid with a rate limit fixes that.
- **No `Valid-Until`** in the apt metadata, like most third-party repositories. An attacker who could serve an old
  copy of the site would need pkgs.hstin.de's TLS certificate.
- **Old Pages deployments** stay reachable at `<hash>.hstin-pkgs.pages.dev`. Only someone who points their sources
  there gets old metadata.

## Adding a project

1. Add `NAME OWNER/REPO` to `projects.txt`. The project may only publish packages named `NAME` and `NAME-*`.
2. Install the reader app on the repository (*Settings → GitHub Apps → hstin-pkgs-reader → Configure*).
3. Give the repository the trigger app's `PKGS_APP_CLIENT_ID` and `PKGS_APP_KEY`, and after a release (or new update
   metadata on its branch `pkgs`) run:

   ```yaml
   - id: app
     uses: actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510 # v3.3.0
     with:
       client-id: ${{ secrets.PKGS_APP_CLIENT_ID }}
       private-key: ${{ secrets.PKGS_APP_KEY }}
       owner: hstin-de
       repositories: pkgs
       permission-actions: write
   - run: gh workflow run deploy.yml -R hstin-de/pkgs
     env:
       GH_TOKEN: ${{ steps.app.outputs.token }}
   ```

## Setup (once)

Cloudflare:

1. R2: a bucket `hstin-pkgs` (no public access, no custom domain). Under *Manage API tokens*, a token with *Object
   Read & Write* on that bucket.
2. Workers & Pages: a Pages project `hstin-pkgs` by *Direct Upload*, custom domain `pkgs.hstin.de`. The R2 binding
   comes from `wrangler.toml` with each deploy.
3. *My Profile → API Tokens*: a token with *Account → Cloudflare Pages → Edit*.

GitHub (organization `hstin-de`, *Settings → Developer settings → GitHub Apps → New GitHub App*, no webhook, *Only
on this account*):

1. `hstin-pkgs-reader`: repository permission *Contents: Read-only*. Install it on the projects' repositories only
   (not on pkgs). Generate a private key.
2. `hstin-pkgs-trigger`: repository permission *Actions: Read and write*. Install it on `pkgs` only. Generate a
   private key.

Then:

- `scripts/secrets.sh environment` creates the environment `production` (main only).
- `scripts/secrets.sh repo-gpg` makes the repository key.
- Set the secrets of the table with `gh secret set NAME --env production --repo hstin-de/pkgs`; for the trigger app,
  `--repo hstin-de/PROJECT` instead.
- `gh workflow run deploy.yml --repo hstin-de/pkgs`.

Bump `repo/VERSION` when the key or the URL of the repository changes: installed machines get the new `hstin-repo`.

## Tests

`bun test src/` checks the function. `go test -count=1 -v ./e2e/` serves test releases of two projects on a fake
GitHub API: a prerelease, a draft, a release with another project's package and one with a wrong digest. It brings
them into a local store with `sync.sh`, builds the site, serves it with `wrangler pages dev`, and installs from it
with `hstin-repo`, the install script, apt and dnf in Debian and Fedora containers (Docker).
