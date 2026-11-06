#!/usr/bin/env bash
# Setup helpers of pkgs.hstin.de (README.md, "Setup"). Nothing is written
# into the repository.
#
#   repo-gpg      makes the OpenPGP key of the apt and dnf repositories in
#                 $HSTIN_PKGS_SECRETS (default ~/hstin-pkgs-secrets; better a
#                 directory in /dev/shm, so it never touches the disk):
#                 REPO_GPG_KEY (private: into the password manager, then the
#                 GitHub secret), hstin-repo-revocation.asc (into the password
#                 manager too) and hstin.asc (public)
#   environment   creates the environment "production" of hstin-de/pkgs that
#                 only main reaches; the deploy's secrets go there
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
	cp "$home/openpgp-revocs.d/$fpr.rev" "$dir/hstin-repo-revocation.asc"
	rm -rf "$home"
	cat << EOF
Public half: $dir/hstin.asc (the site publishes it as /keys/hstin.asc).
Revocation certificate: $dir/hstin-repo-revocation.asc (only if the key leaks).
Back up $dir/REPO_GPG_KEY: apt and dnf trust only this key. A new key can
arrive as an update of hstin-repo only while this one still signs; if it is
lost, every machine must install hstin-repo again by hand.
EOF
}

environment() {
	need gh "https://cli.github.com"
	gh api -X PUT "repos/$org/pkgs/environments/production" --input - > /dev/null << 'JSON'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
	if ! gh api "repos/$org/pkgs/environments/production/deployment-branch-policies" -q '.branch_policies[].name' | grep -qx main; then
		gh api -X POST "repos/$org/pkgs/environments/production/deployment-branch-policies" -f name=main -f type=branch > /dev/null
	fi
	echo "$org/pkgs: environment production (branch main only)."
}

mkdir -p "$dir"
chmod 700 "$dir"
cmd="${1:-help}"
[ $# -gt 0 ] && shift
case "$cmd" in
repo-gpg) repo_gpg ;;
environment) environment ;;
*) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" && exit 2 ;;
esac
