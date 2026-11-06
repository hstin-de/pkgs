#!/usr/bin/env bash
# The two keys of pkgs.hstin.de that are made, not copied from a dashboard
# (README.md, "Setup"). Nothing is written into the repository.
#
#   repo-gpg          makes the OpenPGP key of the apt and dnf repositories in
#                     $HSTIN_PKGS_SECRETS (default ~/hstin-pkgs-secrets):
#                     REPO_GPG_KEY (private: back it up, then a GitHub secret)
#                     and hstin.asc (public)
#   deploy-key REPO   makes a key with which REPO (e.g. otterlink) pushes into
#                     this repository (publish.yml): its public half becomes a
#                     deploy key here, its private half the secret
#                     PKGS_DEPLOY_KEY of REPO; it is kept nowhere else
set -euo pipefail
umask 077

dir="${HSTIN_PKGS_SECRETS:-$HOME/hstin-pkgs-secrets}"
org="${HSTIN_ORG:-hstin-de}"

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
	GNUPGHOME=$home gpg --batch --armor --export "$fpr" > "$dir/hstin.asc"
	chmod 644 "$dir/hstin.asc"
	rm -rf "$home"
	cat << EOF
Public half: $dir/hstin.asc (the site publishes it as /keys/hstin.asc).
Back up $dir/REPO_GPG_KEY: apt and dnf trust only this key. A new key can
arrive as an update of hstin-repo only while this one still signs; if it is
lost, every machine must install hstin-repo again by hand.
EOF
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

mkdir -p "$dir"
chmod 700 "$dir"
cmd="${1:-help}"
[ $# -gt 0 ] && shift
case "$cmd" in
repo-gpg) repo_gpg ;;
deploy-key) deploy_key "$@" ;;
*) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" && exit 2 ;;
esac
