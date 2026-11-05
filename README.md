# pkgs.hstin.de

Signed apt and dnf repositories, download pages and update metadata for the projects of hstin.

- **pkgs.hstin.de** (Cloudflare Pages): repository metadata, install scripts, pages, keys, and each project's signed
  update metadata (`NAME/updates/`). Built by `scripts/build.sh`, deployed by `.github/workflows/deploy.yml`.
- **dl.hstin.de** (Cloudflare R2, bucket `hstin-dl`): the release files, as `NAME/<tag>/<file>`. Pages redirects the
  repositories' package paths there (Pages takes files up to 25 MiB). The last 8 releases per project are kept.

## Using it

```sh
curl -fsSL https://pkgs.hstin.de/otterlink/install.sh | sudo sh
```

apt has one component per project (`deb https://pkgs.hstin.de/apt stable NAME`, key `keys/hstin.gpg`), dnf one
repository per project (`rpm/NAME/NAME.repo`, key `keys/hstin.asc`).

## Adding a project

1. Add its name to `projects.txt`.
2. `scripts/secrets.sh deploy-key NAME`, then `scripts/secrets.sh set` (the organization secrets now include it).
3. Sign its rpm packages with the repository key (`REPO_GPG_KEY`; unsigned rpm packages stay out of the dnf
   repository) and, if it likes, ship `keys/hstin.gpg` and its `apt/NAME.sources` / `rpm/NAME/NAME.repo` in its
   packages, so later changes of either arrive with updates.
4. Publish from its release workflow: upload an artifact with `files/` (the release's files) and/or `updates/`
   (signed `*.json` + `*.json.sig`), then

   ```yaml
   pkgs:
     needs: [upload]
     uses: hstin-de/pkgs/.github/workflows/publish.yml@main
     with: { project: NAME, tag: v1.2.3, artifact: pkgs }
     secrets: inherit
   ```

## Setup (once)

```sh
scripts/secrets.sh repo-gpg       # the repository key
scripts/secrets.sh cloudflare     # Pages token, account ID, R2 token
scripts/secrets.sh set
```

In Cloudflare: an R2 bucket `hstin-dl` with the custom domain `dl.hstin.de`, and a Pages project `hstin-pkgs` (direct
upload) with the custom domain `pkgs.hstin.de`.

## Tests

`go test -count=1 -v ./e2e/` builds a site from signed test packages of two projects and installs from it with apt and
dnf in Debian and Fedora containers (Docker).
