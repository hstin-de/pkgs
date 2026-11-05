#!/usr/bin/env bash
# Builds the static site of pkgs.hstin.de for every project in projects.txt:
# one signed apt repository with a component per project, a signed dnf
# repository per project, a download page and an install script per project,
# the projects' signed update metadata, and the keys. The packages themselves
# are on dl.hstin.de (Cloudflare R2, put there by publish.sh): the site only
# redirects to them (Cloudflare Pages takes files up to 25 MiB).
#
#   scripts/build.sh SITE
#
# Environment:
#   REPO_KEY   OpenPGP key id or fingerprint of the repository key in GNUPGHOME (required)
#   RELEASES   how many releases per project the repositories hold (default 5)
#   DL_URL     where the files are, as <project>/<tag>/<file> (default https://dl.hstin.de)
#   PKGS_URL   the site's own URL in the repository files (default https://pkgs.hstin.de)
#   ROOT       the repository with projects.txt and projects/ (default this script's)
#   CACHE      downloaded packages (default ~/.cache/hstin-pkgs)
# Needs apt-ftparchive (apt-utils), createrepo_c, rpmkeys (rpm), gpg, curl.
set -euo pipefail

site=${1:?usage: build.sh SITE}
: "${REPO_KEY:?REPO_KEY is not set}"
here=$(cd "$(dirname "$0")/.." && pwd)
root=${ROOT:-$here}
releases=${RELEASES:-5}
dl=${DL_URL:-https://dl.hstin.de}
base=${PKGS_URL:-https://pkgs.hstin.de}
cache=${CACHE:-$HOME/.cache/hstin-pkgs}
for t in apt-ftparchive createrepo_c rpmkeys gpg curl; do
	command -v "$t" > /dev/null || {
		echo "build.sh: $t not found" >&2
		exit 1
	}
done

mapfile -t names < <(grep -Ev '^[[:space:]]*(#|$)' "$root/projects.txt" | awk '{print $1}')
[ "${#names[@]}" -gt 0 ] || {
	echo "build.sh: no projects in $root/projects.txt" >&2
	exit 1
}

case "$(realpath -m "$site")" in "$here" | "$here/site" | "$here/scripts" | "$here/projects" | /)
	echo "build.sh: $site is not an output directory" >&2
	exit 2
	;;
esac
rm -rf "$site"
mkdir -p "$site"/{keys,apt}
gpg --batch --armor --export "$REPO_KEY" > "$site/keys/hstin.asc"
gpg --batch --export "$REPO_KEY" > "$site/keys/hstin.gpg"
[ -s "$site/keys/hstin.gpg" ] || {
	echo "build.sh: key $REPO_KEY not in GNUPGHOME" >&2
	exit 1
}
rpmdb=$(mktemp -d)
trap 'rm -rf "$rpmdb"' EXIT
rpmkeys --dbpath "$rpmdb" --import "$site/keys/hstin.asc"
sign() { gpg --batch --yes --local-user "$REPO_KEY" "$@"; }
esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

redirects="$site/_redirects"
: > "$redirects"
summary=()
list=""

for name in "${names[@]}"; do
	[[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
		echo "build.sh: bad project name $name" >&2
		exit 1
	}
	rel="$root/projects/$name/releases"
	mapfile -t all < <(find "$rel" -maxdepth 1 -name 'v*.txt' -printf '%f\n' 2> /dev/null | sed 's/\.txt$//' | sort -V)
	start=$((${#all[@]} > releases ? ${#all[@]} - releases : 0))
	tags=("${all[@]:start}")
	for tag in "${tags[@]}"; do
		while read -r f; do
			case "$f" in *_linux_*.deb | *_linux_*.rpm) ;; *) continue ;; esac
			[[ "$f" =~ ^[A-Za-z0-9._+-]+$ ]] || continue
			local_file="$cache/$name/$tag/$f"
			if [ ! -s "$local_file" ]; then
				mkdir -p "$(dirname "$local_file")"
				curl -fsSL --retry 3 -o "$local_file.tmp" "$dl/$name/$tag/$f"
				mv "$local_file.tmp" "$local_file"
			fi
			if [[ "$f" == *.deb ]]; then
				mkdir -p "$site/apt/pool/$name/$tag"
				cp "$local_file" "$site/apt/pool/$name/$tag/"
				echo "/apt/pool/$name/$tag/$f $dl/$name/$tag/$f 302" >> "$redirects"
			elif rpmkeys --dbpath "$rpmdb" --checksig "$local_file" | grep -q 'signatures OK'; then
				mkdir -p "$site/rpm/$name/pool/$tag"
				cp "$local_file" "$site/rpm/$name/pool/$tag/"
				echo "/rpm/$name/pool/$tag/$f $dl/$name/$tag/$f 302" >> "$redirects"
			else
				echo "build.sh: $name $f is not signed with the repository key; left out" >&2
			fi
		done < "$rel/$tag.txt"
	done

	# apt: the project's component.
	for arch in amd64 arm64; do
		d="$site/apt/dists/stable/$name/binary-$arch"
		mkdir -p "$d"
		if [ -d "$site/apt/pool/$name" ]; then
			(cd "$site/apt" && apt-ftparchive --arch "$arch" packages "pool/$name") > "$d/Packages"
		else
			: > "$d/Packages"
		fi
		gzip -9nkf "$d/Packages"
	done
	cat > "$site/apt/$name.sources" << SRC
Types: deb
URIs: $base/apt
Suites: stable
Components: $name
Signed-By: /usr/share/keyrings/hstin.gpg
SRC

	# rpm: the project's repository.
	mkdir -p "$site/rpm/$name"
	createrepo_c --quiet --general-compress-type=gz "$site/rpm/$name" > /dev/null
	sign --armor --detach-sign -o "$site/rpm/$name/repodata/repomd.xml.asc" "$site/rpm/$name/repodata/repomd.xml"
	cat > "$site/rpm/$name/$name.repo" << REPO
[hstin-$name]
name=$name (pkgs.hstin.de)
baseurl=$base/rpm/$name
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-hstin
REPO

	# The project's pages and update metadata.
	mkdir -p "$site/$name"
	sed -e "s|@PROJECT@|$name|g" -e "s|@BASE@|$base|g" "$here/site/install.sh" > "$site/$name/install.sh"
	files=""
	latest=""
	if [ "${#all[@]}" -gt 0 ]; then
		latest=${all[-1]}
		while read -r f; do
			[[ "$f" =~ ^[A-Za-z0-9._+-]+$ ]] || continue
			files+="<li><a href=\"$dl/$name/$latest/$f\">$f</a></li>"$'\n'
		done < "$rel/$latest.txt"
	fi
	awk -v files="$files" '{ if ($0 == "@FILES@") printf "%s", files; else print }' "$here/site/project.html" |
		sed -e "s|@PROJECT@|$name|g" -e "s|@BASE@|$base|g" -e "s|@LATEST@|${latest:-none yet}|g" > "$site/$name/index.html"
	if [ -s "$root/projects/$name/updates/keys.json" ]; then
		mkdir -p "$site/$name/updates"
		for f in "$root/projects/$name/updates/"*.json; do
			[ -s "$f.sig" ] || {
				echo "build.sh: $f has no signature" >&2
				exit 1
			}
			cp "$f" "$f.sig" "$site/$name/updates/"
		done
	fi
	list+="<li><a href=\"$name/\"><b>$name</b></a> $(echo "${latest:-}" | esc): <code>curl -fsSL $base/$name/install.sh | sudo sh</code></li>"$'\n'
	summary+=("$name: ${#tags[@]} of ${#all[@]} releases in the repositories (${tags[*]:-})")
done

# apt: one suite for every component.
(
	cd "$site/apt"
	apt-ftparchive \
		-o APT::FTPArchive::Release::Origin=hstin -o APT::FTPArchive::Release::Label=hstin \
		-o APT::FTPArchive::Release::Suite=stable -o APT::FTPArchive::Release::Codename=stable \
		-o APT::FTPArchive::Release::Architectures="amd64 arm64" \
		-o APT::FTPArchive::Release::Components="${names[*]}" \
		release dists/stable > Release.tmp
	mv Release.tmp dists/stable/Release
	sign --clearsign -o dists/stable/InRelease dists/stable/Release
	sign --armor --detach-sign -o dists/stable/Release.gpg dists/stable/Release
)
rm -rf "$site/apt/pool"
find "$site/rpm" -mindepth 2 -maxdepth 2 -type d -name pool -exec rm -rf {} +

lines=$(wc -l < "$redirects")
[ "$lines" -le 2000 ] || {
	echo "build.sh: $lines redirects, Pages allows 2000" >&2
	exit 1
}

awk -v list="$list" '{ if ($0 == "@PROJECTS@") printf "%s", list; else print }' "$here/site/index.html" |
	sed "s|@BASE@|$base|g" > "$site/index.html"
cp "$here/site/_headers" "$site/"

printf '%s\n' "${summary[@]}"
echo "site: ${#names[@]} projects, $lines package redirects"
