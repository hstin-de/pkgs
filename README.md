# pkgs.hstin.de

One signed apt and dnf repository with the packages of the projects of hstin, their download pages and their signed
update metadata.

## Using it

```sh
# Debian, Ubuntu
curl -fsSLo /tmp/hstin-repo.deb https://pkgs.hstin.de/hstin-repo.deb
sudo apt install /tmp/hstin-repo.deb && sudo apt update
sudo apt install otterlink

# Fedora, RHEL
sudo dnf install https://pkgs.hstin.de/hstin-repo.rpm
sudo dnf install otterlink

# or the script (it installs hstin-repo, then the packages named)
curl -fsSLO https://pkgs.hstin.de/install.sh && less install.sh && sudo sh install.sh otterlink
```

`hstin-repo` holds the apt source (`deb https://pkgs.hstin.de/apt stable main`) or dnf repository and the key, so a
change of either arrives as an update. The start page shows the key's fingerprint and the steps by hand.

## How it works

- **Cloudflare Pages** (project `hstin-pkgs`, custom domain `pkgs.hstin.de`): the repository metadata, `hstin-repo`,
  the install script, a download page per project (`NAME/`), the projects' update metadata (`NAME/updates/`) and the
  keys, built by `scripts/build.sh` and deployed by `.github/workflows/deploy.yml`.
- **Cloudflare R2** (bucket `hstin-dl`, private): the release files as `NAME/<tag>/<file>`, the last 8 releases per
  project. The Pages functions (`functions/`, `src/dl.js`) serve them under `/apt/pool/`, `/rpm/pool/` and `/dl/`
  (ranges and conditional requests included). Pages takes static files only up to 25 MiB.
- Package names are one namespace across projects. rpm packages must be signed with the repository key; unsigned ones
  stay out of the dnf repository.
- Function requests count against the Workers plan (Free: 100,000 a day); everything else is static.

## Adding a project

1. Add its name to `projects.txt`.
2. `scripts/secrets.sh deploy-key NAME`, then `scripts/secrets.sh set` (the organization secrets now include it).
3. Sign its rpm packages with the repository key (organization secret `REPO_GPG_KEY`).
4. Publish from its release workflow: upload an artifact with `files/` (the release's files) and/or `updates/`
   (signed `*.json` + `*.json.sig`), then

   ```yaml
   pkgs:
     needs: [upload]
     uses: hstin-de/pkgs/.github/workflows/publish.yml@main
     with: { project: NAME, tag: v1.2.3, artifact: pkgs }
     secrets: inherit
   ```

   The files go to R2, the file list and metadata into `projects/NAME/`; that push deploys the site.

## Setup (once)

In Cloudflare:

1. R2: a bucket `hstin-dl` (no public access), and under *Manage API tokens* a token with *Object Read & Write* on it.
2. Pages: a project `hstin-pkgs` (*Direct Upload*), custom domain `pkgs.hstin.de`. The R2 binding comes from
   `wrangler.toml` with each deploy.
3. An API token with *Account → Cloudflare Pages → Edit*, and the account ID.

Then:

```sh
scripts/secrets.sh repo-gpg       # the repository key (back up ~/hstin-pkgs-secrets)
scripts/secrets.sh cloudflare     # the tokens and the account ID
scripts/secrets.sh deploy-key otterlink
scripts/secrets.sh set
gh workflow run deploy --repo hstin-de/pkgs
```

Bump `repo/VERSION` when the key or the URL of the repository changes: installed machines get the new `hstin-repo`.

## Tests

`bun test src/` checks the function. `go test -count=1 -v ./e2e/` publishes signed test packages of two projects into
a local R2 bucket, builds the site, serves it with `wrangler pages dev`, and installs from it with `hstin-repo`, the
install script, apt and dnf in Debian and Fedora containers (Docker).
