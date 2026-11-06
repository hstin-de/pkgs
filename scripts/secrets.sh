#!/usr/bin/env bash
# Prepares the secrets of pkgs.hstin.de: one file per secret in
# $HSTIN_PKGS_SECRETS (default ~/hstin-pkgs-secrets), uploaded with `set`.
# Nothing is written into the repository.
#
#   repo-gpg          the OpenPGP key of the apt and dnf repositories; its public
#                     half as hstin.asc/hstin.gpg for the projects' packages
#   cloudflare        the Pages and R2 tokens and the account ID
#   deploy-key REPO   a key with which REPO (e.g. otterlink) pushes into this
#                     repository (publish.yml); added and set right away
#   status            which secrets exist
#   set               upload them: the repository key and the R2 token as
#                     organization secrets for this repository and the projects
#                     of projects.txt, the Pages token for this repository
set -euo pipefail
umask 077

dir="${HSTIN_PKGS_SECRETS:-$HOME/hstin-pkgs-secrets}"
org="${HSTIN_ORG:-hstin-de}"
root=$(cd "$(dirname "$0")/.." && pwd)

die() {
	echo "error: $*" >&2
	exit 1
}
need() { command -v "$1" > /dev/null || die "$1 not found${2:+ ($2)}"; }
put() {
	printf '%s' "$2" > "$dir/$1"
	echo "  $1"
}
fresh() { [ ! -e "$1" ] || die "$1 exists; delete it first if you really want a new one"; }

repo_gpg() {
	need gpg
	local home fpr
	fresh "$dir/REPO_GPG_KEY"
	home=$(mktemp -d)
	GNUPGHOME=$home gpg --batch --passphrase '' --quick-gen-key "hstin packages <pkgs@hstin.de>" rsa4096 sign never 2> /dev/null
	fpr=$(GNUPGHOME=$home gpg --batch --list-keys --with-colons 2> /dev/null | awk -F: '/^fpr/ {print $10; exit}')
	echo "Repository key $fpr:"
	put REPO_GPG_KEY "$(GNUPGHOME=$home gpg --batch --armor --export-secret-keys "$fpr")"
	put REPO_GPG_FINGERPRINT "$fpr"
	GNUPGHOME=$home gpg --batch --armor --export "$fpr" > "$dir/hstin.asc"
	GNUPGHOME=$home gpg --batch --export "$fpr" > "$dir/hstin.gpg"
	chmod 644 "$dir/hstin.asc" "$dir/hstin.gpg"
	rm -rf "$home"
	cat << EOF
Public half: $dir/hstin.asc and hstin.gpg (projects ship them in their
packages). Back up $dir/REPO_GPG_KEY: apt and dnf trust only this key.
EOF
}

cloudflare() {
	local v
	echo "Cloudflare (dashboard → My Profile → API Tokens, and R2 → Manage API tokens):"
	read -rsp "API token with 'Cloudflare Pages: Edit': " v
	echo
	put CLOUDFLARE_API_TOKEN "$v"
	read -rp "Account ID: " v
	put CLOUDFLARE_ACCOUNT_ID "$v"
	read -rp "R2 token Access Key ID (Object Read & Write on the bucket hstin-dl): " v
	put R2_ACCESS_KEY_ID "$v"
	read -rsp "R2 token Secret Access Key: " v
	echo
	put R2_SECRET_ACCESS_KEY "$v"
}

deploy_key() {
	need gh "https://cli.github.com"
	need ssh-keygen
	local repo="${1:?usage: $0 deploy-key REPO}" k
	k=$(mktemp -d)/key
	ssh-keygen -q -t ed25519 -N '' -C "publish from $org/$repo" -f "$k"
	gh repo deploy-key add "$k.pub" --repo "$org/pkgs" --allow-write --title "publish from $repo"
	gh secret set PKGS_DEPLOY_KEY --repo "$org/$repo" < "$k"
	rm -rf "$(dirname "$k")"
	echo "$org/$repo may now push into $org/pkgs (secret PKGS_DEPLOY_KEY)."
}

org_secrets=(REPO_GPG_KEY REPO_GPG_FINGERPRINT CLOUDFLARE_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY)
repo_secrets=(CLOUDFLARE_API_TOKEN)

status() {
	local s
	echo "$dir:"
	for s in "${org_secrets[@]}" "${repo_secrets[@]}"; do
		if [ -s "$dir/$s" ]; then echo "  ok       $s"; else echo "  missing  $s"; fi
	done
}

set_secrets() {
	need gh "https://cli.github.com"
	local s repos n=0
	repos=$(grep -Ev '^[[:space:]]*(#|$)' "$root/projects.txt" | awk '{print $1}' | paste -sd, -)
	repos="pkgs${repos:+,$repos}"
	for s in "${org_secrets[@]}"; do
		[ -s "$dir/$s" ] || continue
		gh secret set "$s" --org "$org" --visibility selected --repos "$repos" < "$dir/$s"
		n=$((n + 1))
	done
	for s in "${repo_secrets[@]}"; do
		[ -s "$dir/$s" ] || continue
		gh secret set "$s" --repo "$org/pkgs" < "$dir/$s"
		n=$((n + 1))
	done
	echo "$n secrets set ($org: $repos)"
}

mkdir -p "$dir"
chmod 700 "$dir"
cmd="${1:-status}"
[ $# -gt 0 ] && shift
case "$cmd" in
repo-gpg) repo_gpg ;;
cloudflare) cloudflare ;;
deploy-key) deploy_key "$@" ;;
status) status ;;
set) set_secrets ;;
*) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" && exit 2 ;;
esac
