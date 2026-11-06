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
# Needs apt-ftparchive (apt-utils), createrepo_c, rpmkeys (rpm), repo-add (pacman-package-manager, makepkg), gpg,
# nfpm, jq, sha256sum (and aws).
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
for t in apt-ftparchive createrepo_c rpmkeys repo-add gpg nfpm jq; do
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
mkdir -p "$out"/{keys,apt/pool,apt/repo,rpm/pool,rpm/repo,arch/x86_64,arch/aarch64}
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

# hstin-repo: the apt source, dnf repository or pacman mirrorlist with the key,
# so that a new URL or key arrives as an update (bump repo/VERSION).
repo_version=$(tr -d '[:space:]' < "$here/repo/VERSION")
# nfpm writes an Arch pkgver as X.Y.Z.
arch_version=$(awk -F. '{ printf "%s.%s.%s", $1, ($2 == "" ? 0 : $2), ($3 == "" ? 0 : $3) }' <<< "$repo_version")
cp "$out/keys/hstin.gpg" "$out/keys/hstin.asc" "$work/"
sed "s|@BASE@|$base|g" "$here/repo/hstin.sources" > "$work/hstin.sources"
sed "s|@BASE@|$base|g" "$here/repo/hstin.repo" > "$work/hstin.repo"
sed "s|@HOST@|$host|g" "$here/repo/hstin.pref" > "$work/hstin.pref"
sed "s|@BASE@|$base|g" "$here/repo/hstin-mirrorlist" > "$work/hstin-mirrorlist"
fpr=$(gpg --batch --with-colons --fingerprint "$REPO_KEY" 2> /dev/null | awk -F: '/^fpr/ {print $10; exit}')
echo "$fpr:4:" > "$work/hstin-trusted"
: > "$work/hstin-revoked"
for format in deb rpm archlinux; do
	scripts=""
	if [ "$format" = deb ]; then
		files="  - {src: $work/hstin.sources, dst: /etc/apt/sources.list.d/hstin.sources, type: config|noreplace, file_info: {mode: 0644}}
  - {src: $work/hstin.gpg, dst: /usr/share/keyrings/hstin.gpg, file_info: {mode: 0644}}
  - {src: $work/hstin.pref, dst: /etc/apt/preferences.d/hstin.pref, file_info: {mode: 0644}}"
		target="$out/apt/repo/hstin-repo_${repo_version}_all.deb"
	elif [ "$format" = rpm ]; then
		files="  - {src: $work/hstin.repo, dst: /etc/yum.repos.d/hstin.repo, type: config|noreplace, file_info: {mode: 0644}}
  - {src: $work/hstin.asc, dst: /etc/pki/rpm-gpg/RPM-GPG-KEY-hstin, file_info: {mode: 0644}}"
		target="$out/rpm/repo/hstin-repo-${repo_version}-1.noarch.rpm"
	elif [ "$format" = archlinux ]; then
		files="  - {src: $work/hstin-mirrorlist, dst: /etc/pacman.d/hstin-mirrorlist, type: config|noreplace, file_info: {mode: 0644}}
  - {src: $work/hstin.gpg, dst: /usr/share/pacman/keyrings/hstin.gpg, file_info: {mode: 0644}}
  - {src: $work/hstin-trusted, dst: /usr/share/pacman/keyrings/hstin-trusted, file_info: {mode: 0644}}
  - {src: $work/hstin-revoked, dst: /usr/share/pacman/keyrings/hstin-revoked, file_info: {mode: 0644}}"
		scripts="scripts:
  postinstall: $here/repo/hstin-repo.install.sh
archlinux:
  scripts:
    postupgrade: $here/repo/hstin-repo.install.sh"
		target="$work/hstin-repo-${arch_version}-1-any.pkg.tar.zst"
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
$scripts
YAML
	nfpm package -f "$work/hstin-repo-$format.yaml" -p "$format" -t "$target" > /dev/null
done
cp "$out/apt/repo/hstin-repo_${repo_version}_all.deb" "$out/hstin-repo.deb"
cp "$out/rpm/repo/hstin-repo-${repo_version}-1.noarch.rpm" "$out/hstin-repo.rpm"
# The Arch one with its signature: `pacman -U URL` fetches URL.sig and checks
# it (the key is trusted first, as with any repository on Arch).
mkdir -p "$work/arch"
cp "$work/hstin-repo-${arch_version}-1-any.pkg.tar.zst" "$work/arch/"
sign --no-armor --detach-sign -o "$work/arch/hstin-repo-${arch_version}-1-any.pkg.tar.zst.sig" "$work/hstin-repo-${arch_version}-1-any.pkg.tar.zst"
cp "$work/arch/hstin-repo-${arch_version}-1-any.pkg.tar.zst" "$out/hstin-repo.pkg.tar.zst"
cp "$work/arch/hstin-repo-${arch_version}-1-any.pkg.tar.zst.sig" "$out/hstin-repo.pkg.tar.zst.sig"
for a in x86_64 aarch64; do
	cp "$work/arch/hstin-repo-${arch_version}-1-any.pkg.tar.zst" "$work/arch/hstin-repo-${arch_version}-1-any.pkg.tar.zst.sig" "$out/arch/$a/"
done
# files.json: which release (project/tag in the store) holds an Arch package
# file, for the function serving /arch/<arch>/<file>.
echo '{"x86_64":{},"aarch64":{}}' > "$work/arch.json"

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
		cp "$rel/$tag.sums" "$work/current.sums"
		while read -r sum f; do
			case "$f" in *_linux_*.deb | *_linux_*.rpm | *_linux_amd64.pkg.tar.zst | *_linux_arm64.pkg.tar.zst) ;; *) continue ;; esac
			if ! [[ "$f" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || [[ "$f" == *..* ]] || ! [[ "$sum" =~ ^[0-9a-f]{64}$ ]]; then
				continue
			fi
			if [[ "$f" == *.pkg.tar.zst ]]; then
				# Arch: only with the signature sync.sh made.
				sig=$(awk -v n="$f.sig" '$2 == n { print $1 }' "$rel/$tag.sums")
				[[ "$sig" =~ ^[0-9a-f]{64}$ ]] || continue
				a=x86_64
				[[ "$f" != *_arm64.pkg.tar.zst ]] || a=aarch64
				mkdir -p "$work/arch/$a"
				cp "$(fetch "$name" "$tag" "$f" "$sum")" "$work/arch/$a/$f"
				cp "$(fetch "$name" "$tag" "$f.sig" "$sig")" "$work/arch/$a/$f.sig"
				jq --arg a "$a" --arg f "$f" --arg at "$name/$tag" '.[$a][$f] = $at | .[$a][$f + ".sig"] = $at' \
					"$work/arch.json" > "$work/arch.json.new" && mv "$work/arch.json.new" "$work/arch.json"
				continue
			fi
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
		done < "$work/current.sums"
	done

	# The project's download page and update metadata.
	mkdir -p "$out/$name"
	files=""
	latest=""
	if [ "${#tags[@]}" -gt 0 ]; then
		latest=${tags[-1]}
		while read -r sum f; do
			if ! [[ "$f" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || [[ "$f" == *..* ]] || ! [[ "$sum" =~ ^[0-9a-f]{64}$ ]]; then
				continue
			fi
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

# Arch: one repository "hstin" per architecture, the database signed; the
# packages (and their .sig) are served from R2 (files.json), hstin-repo from
# here.
for a in x86_64 aarch64; do
	pkgs=("$out/arch/$a"/hstin-repo-*.pkg.tar.zst)
	[ ! -d "$work/arch/$a" ] || mapfile -t -O 1 pkgs < <(find "$work/arch/$a" -name '*.pkg.tar.zst' | sort)
	repo-add -q "$work/arch/hstin-$a.db.tar.gz" "${pkgs[@]}" > /dev/null
	for db in db files; do
		cp "$work/arch/hstin-$a.$db.tar.gz" "$out/arch/$a/hstin.$db.tar.gz"
		cp "$work/arch/hstin-$a.$db.tar.gz" "$out/arch/$a/hstin.$db"
		for f in "hstin.$db" "hstin.$db.tar.gz"; do
			sign --no-armor --detach-sign -o "$out/arch/$a/$f.sig" "$out/arch/$a/$f"
		done
	done
done
cp "$work/arch.json" "$out/arch/files.json"

# The release files are served from R2, not from here.
rm -rf "$out/apt/pool" "$out/rpm/pool"

sed "s|@BASE@|$base|g" "$here/site/install.sh" > "$out/install.sh"
awk -v list="$list" '{ if ($0 == "@PROJECTS@") printf "%s", list; else print }' "$here/site/index.html" |
	sed -e "s|@BASE@|$base|g" -e "s|@FINGERPRINT@|$fpr|g" > "$out/index.html"
cp "$here/site/_headers" "$out/"
# A 404 page: without one Pages answers unknown paths with index.html and 200
# (pacman -U URL would take it for URL.sig).
cp "$here/site/404.html" "$out/"

printf '%s\n' "${summary[@]}"
echo "site: ${#names[@]} projects, hstin-repo $repo_version"
