#!/usr/bin/env bash
# Builds the static part of pkgs.hstin.de from what sync.sh wrote: one signed
# apt repository (suite stable, component main) and one signed dnf repository
# with the packages of every project, the package hstin-repo that sets both
# up, the install script, a download page per project, the projects' signed
# update metadata, and the keys. The release files stay in the store (R2);
# functions/ serves them under /apt/pool/, /rpm/pool/ and /dl/ (Pages takes
# static files up to 25 MiB). Every file is checked against the release's
# SHA256SUMS before its hash goes into the signed metadata.
#
#   scripts/build.sh OUT        (OUT must be named "out")
#
# Environment:
#   REPO_KEY   OpenPGP key id or fingerprint of the repository key in GNUPGHOME (required)
#   ROOT       sync.sh's output: projects.txt, projects/NAME/releases/TAG.sums, projects/NAME/updates/
#   STORE, R2_ENDPOINT, AWS_*   see store.sh
#   PKGS_URL   the site's own URL (default https://pkgs.hstin.de)
#   CACHE      downloaded packages (default a temporary directory)
# Needs apt-ftparchive (apt-utils), createrepo_c, rpmkeys (rpm), gpg, nfpm, sha256sum (and aws).
set -euo pipefail

out=${1:?usage: build.sh OUT}
: "${REPO_KEY:?REPO_KEY is not set}"
here=$(cd "$(dirname "$0")/.." && pwd)
root=${ROOT:?ROOT is not set (the output of sync.sh)}
base=${PKGS_URL:-https://pkgs.hstin.de}
host=${base#*://}
host=${host%%/*}
host=${host%%:*}
# shellcheck source=scripts/store.sh
. "$here/scripts/store.sh"
for t in apt-ftparchive createrepo_c rpmkeys gpg nfpm; do
	command -v "$t" > /dev/null || {
		echo "build.sh: $t not found" >&2
		exit 1
	}
done
[ "$(basename "$(realpath -m "$out")")" = out ] || {
	echo "build.sh: the output directory must be named out (it is deleted first)" >&2
	exit 2
}

mapfile -t names < <(grep -Ev '^[[:space:]]*(#|$)' "$root/projects.txt" | awk '{print $1}')
[ "${#names[@]}" -gt 0 ] || {
	echo "build.sh: no projects in $root/projects.txt" >&2
	exit 1
}

rm -rf "$out"
mkdir -p "$out"/{keys,apt/pool,apt/repo,rpm/pool,rpm/repo}
gpg --batch --armor --export "$REPO_KEY" > "$out/keys/hstin.asc"
gpg --batch --export "$REPO_KEY" > "$out/keys/hstin.gpg"
[ -s "$out/keys/hstin.gpg" ] || {
	echo "build.sh: key $REPO_KEY not in GNUPGHOME" >&2
	exit 1
}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cache=${CACHE:-$work/cache}
rpmkeys --dbpath "$work/rpmdb" --import "$out/keys/hstin.asc"
gpg --batch --armor --export-secret-keys "$REPO_KEY" > "$work/key.asc"
sign() { gpg --batch --yes --local-user "$REPO_KEY" "$@"; }

fetch() { # project tag file sha256 → path of a copy with that hash
	local f="$cache/$1/$2/$3"
	if [ -s "$f" ] && echo "$4  $f" | sha256sum -c --quiet --status -; then
		echo "$f"
		return
	fi
	mkdir -p "$(dirname "$f")"
	store_get "$1/$2/$3" "$f.tmp"
	echo "$4  $f.tmp" | sha256sum -c --quiet --status - || {
		echo "build.sh: $1/$2/$3 in the store does not match its SHA256SUMS" >&2
		exit 1
	}
	mv "$f.tmp" "$f"
	echo "$f"
}

# hstin-repo: the apt source and dnf repository with the key, so that a new
# URL or key arrives as an update (bump repo/VERSION).
repo_version=$(tr -d '[:space:]' < "$here/repo/VERSION")
cp "$out/keys/hstin.gpg" "$out/keys/hstin.asc" "$work/"
sed "s|@BASE@|$base|g" "$here/repo/hstin.sources" > "$work/hstin.sources"
sed "s|@BASE@|$base|g" "$here/repo/hstin.repo" > "$work/hstin.repo"
sed "s|@HOST@|$host|g" "$here/repo/hstin.pref" > "$work/hstin.pref"
for format in deb rpm; do
	if [ "$format" = deb ]; then
		files="  - {src: $work/hstin.sources, dst: /etc/apt/sources.list.d/hstin.sources, type: config|noreplace, file_info: {mode: 0644}}
  - {src: $work/hstin.gpg, dst: /usr/share/keyrings/hstin.gpg, file_info: {mode: 0644}}
  - {src: $work/hstin.pref, dst: /etc/apt/preferences.d/hstin.pref, file_info: {mode: 0644}}"
		target="$out/apt/repo/hstin-repo_${repo_version}_all.deb"
	else
		files="  - {src: $work/hstin.repo, dst: /etc/yum.repos.d/hstin.repo, type: config|noreplace, file_info: {mode: 0644}}
  - {src: $work/hstin.asc, dst: /etc/pki/rpm-gpg/RPM-GPG-KEY-hstin, file_info: {mode: 0644}}"
		target="$out/rpm/repo/hstin-repo-${repo_version}-1.noarch.rpm"
	fi
	cat > "$work/hstin-repo-$format.yaml" << YAML
name: hstin-repo
arch: all
platform: linux
version: "$repo_version"
release: "1"
maintainer: hstin <pkgs@hstin.de>
description: The hstin package repository ($base) and its signing key.
homepage: $base
license: Apache-2.0
contents:
$files
rpm:
  signature:
    key_file: $work/key.asc
YAML
	nfpm package -f "$work/hstin-repo-$format.yaml" -p "$format" -t "$target" > /dev/null
done
cp "$out/apt/repo/hstin-repo_${repo_version}_all.deb" "$out/hstin-repo.deb"
cp "$out/rpm/repo/hstin-repo-${repo_version}-1.noarch.rpm" "$out/hstin-repo.rpm"

summary=()
list=""
for name in "${names[@]}"; do
	[[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
		echo "build.sh: bad project name $name" >&2
		exit 1
	}
	case "$name" in apt | rpm | keys | dl | hstin*)
		echo "build.sh: project name $name is reserved" >&2
		exit 1
		;;
	esac
	rel="$root/projects/$name/releases"
	mapfile -t tags < <(find "$rel" -maxdepth 1 -name 'v*.sums' -printf '%f\n' 2> /dev/null | sed 's/\.sums$//' |
		grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V)
	for tag in "${tags[@]}"; do
		while read -r sum f; do
			case "$f" in *_linux_*.deb | *_linux_*.rpm) ;; *) continue ;; esac
			[[ "$f" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] && [[ "$f" != *..* ]] && [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || continue
			local_file=$(fetch "$name" "$tag" "$f" "$sum")
			if [[ "$f" == *.deb ]]; then
				mkdir -p "$out/apt/pool/$name/$tag"
				cp "$local_file" "$out/apt/pool/$name/$tag/"
			elif rpmkeys --dbpath "$work/rpmdb" --checksig "$local_file" | grep -q 'signatures OK'; then
				mkdir -p "$out/rpm/pool/$name/$tag"
				cp "$local_file" "$out/rpm/pool/$name/$tag/"
			else
				echo "build.sh: $name $f is not signed with the repository key; left out of dnf" >&2
			fi
		done < "$rel/$tag.sums"
	done

	# The project's download page and update metadata.
	mkdir -p "$out/$name"
	files=""
	latest=""
	if [ "${#tags[@]}" -gt 0 ]; then
		latest=${tags[-1]}
		while read -r sum f; do
			[[ "$f" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] && [[ "$f" != *..* ]] && [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || continue
			files+="<li><a href=\"$base/dl/$name/$latest/$f\">$f</a><br><code>$sum</code></li>"$'\n'
		done < "$rel/$latest.sums"
		files+="<li><a href=\"$base/dl/$name/$latest/SHA256SUMS\">SHA256SUMS</a></li>"$'\n'
		echo "$latest" > "$out/$name/latest.txt"
	fi
	awk -v files="$files" '{ if ($0 == "@FILES@") printf "%s", files; else print }' "$here/site/project.html" |
		sed -e "s|@PROJECT@|$name|g" -e "s|@BASE@|$base|g" -e "s|@LATEST@|${latest:-none yet}|g" > "$out/$name/index.html"
	if [ -s "$root/projects/$name/updates/keys.json" ]; then
		mkdir -p "$out/$name/updates"
		for f in "$root/projects/$name/updates/"*.json; do
			[ -s "$f.sig" ] || {
				echo "build.sh: $f has no signature" >&2
				exit 1
			}
			cp "$f" "$f.sig" "$out/$name/updates/"
		done
	fi
	list+="<li><a href=\"$name/\"><b>$name</b></a> ${latest:-}</li>"$'\n'
	summary+=("$name: ${#tags[@]} releases (${tags[*]:-})")
done

# apt: suite stable, component main.
(
	cd "$out/apt"
	for arch in amd64 arm64; do
		d=dists/stable/main/binary-$arch
		mkdir -p "$d"
		{
			apt-ftparchive --arch "$arch" packages pool
			apt-ftparchive --arch "$arch" packages repo
		} > "$d/Packages"
		gzip -9nkf "$d/Packages"
	done
	apt-ftparchive \
		-o APT::FTPArchive::Release::Origin=hstin -o APT::FTPArchive::Release::Label=hstin \
		-o APT::FTPArchive::Release::Suite=stable -o APT::FTPArchive::Release::Codename=stable \
		-o APT::FTPArchive::Release::Architectures="amd64 arm64" -o APT::FTPArchive::Release::Components=main \
		release dists/stable > "$work/Release"
	mv "$work/Release" dists/stable/Release
	sign --clearsign -o dists/stable/InRelease dists/stable/Release
	sign --armor --detach-sign -o dists/stable/Release.gpg dists/stable/Release
)

# rpm: one repository.
createrepo_c --quiet --general-compress-type=gz "$out/rpm" > /dev/null
sign --armor --detach-sign -o "$out/rpm/repodata/repomd.xml.asc" "$out/rpm/repodata/repomd.xml"

# The release files are served from R2, not from here.
rm -rf "$out/apt/pool" "$out/rpm/pool"

sed "s|@BASE@|$base|g" "$here/site/install.sh" > "$out/install.sh"
fpr=$(gpg --batch --with-colons --fingerprint "$REPO_KEY" 2> /dev/null | awk -F: '/^fpr/ {print $10; exit}')
awk -v list="$list" '{ if ($0 == "@PROJECTS@") printf "%s", list; else print }' "$here/site/index.html" |
	sed -e "s|@BASE@|$base|g" -e "s|@FINGERPRINT@|$fpr|g" > "$out/index.html"
cp "$here/site/_headers" "$out/"

printf '%s\n' "${summary[@]}"
echo "site: ${#names[@]} projects, hstin-repo $repo_version"
