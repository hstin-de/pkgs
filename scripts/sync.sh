#!/usr/bin/env bash
# Brings the releases of every project in projects.txt from GitHub into the
# store (store.sh) and writes what build.sh reads:
#
#   OUT/projects.txt
#   OUT/projects/NAME/releases/TAG.sums   (sha256sum lines of the stored files)
#   OUT/projects/NAME/updates/*.json(.sig)
#
# A project's line in projects.txt is "NAME OWNER/REPO". Its releases are the
# newest KEEP published, non-prerelease GitHub releases tagged vX.Y.Z that
# pass the checks. One that is not in the store yet is downloaded; every asset must match the SHA-256
# digest GitHub recorded, every deb and rpm must be named NAME or NAME-*, rpms
# are signed with the repository key; then the files are uploaded, SHA256SUMS
# last (a release without it is incomplete and done again). A release failing
# a check is left out with a warning; the other releases and projects go on.
# Stored releases beyond those are removed. The signed update metadata comes
# from the project's branch `pkgs`, directory updates/.
#
#   scripts/sync.sh OUT
#
# Environment:
#   GH_TOKEN    read access to the projects' repositories (the reader app)
#   GITHUB_API  default https://api.github.com
#   STORE, R2_ENDPOINT, AWS_*   see store.sh
#   REPO_KEY    key id or fingerprint of the repository key in GNUPGHOME
#   KEEP        releases kept per project (default 8)
#   ROOT        the directory with projects.txt (default this repository)
# Needs curl, jq, dpkg-deb, rpm, rpmsign, rpmkeys, gpg, sha256sum (and aws).
set -euo pipefail

out=${1:?usage: sync.sh OUT}
: "${GH_TOKEN:?GH_TOKEN is not set}"
: "${REPO_KEY:?REPO_KEY is not set}"
here=$(cd "$(dirname "$0")/.." && pwd)
root=${ROOT:-$here}
api=${GITHUB_API:-https://api.github.com}
keep=${KEEP:-8}
[[ "$keep" =~ ^[1-9][0-9]*$ ]] || {
	echo "sync.sh: KEEP must be a positive number" >&2
	exit 2
}
# shellcheck source=scripts/store.sh
. "$here/scripts/store.sh"

name_re='^[a-z0-9][a-z0-9-]*$'
repo_re='^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$'
tag_re='^v[0-9]+\.[0-9]+\.[0-9]+$'
file_re='^[A-Za-z0-9][A-Za-z0-9._+-]*$'

warn() {
	echo "sync.sh: $*" >&2
	# A warning in the workflow's summary.
	[ -z "${GITHUB_ACTIONS:-}" ] || echo "::warning::$*"
}
die() {
	echo "sync.sh: $*" >&2
	exit 1
}

# get URL FILE [ACCEPT]: prints the HTTP status. The token goes to the API
# host only (curl drops it on redirects to another host).
get() {
	curl -sS -L --retry 3 -o "$2" -w '%{http_code}' \
		-H "Authorization: Bearer $GH_TOKEN" -H "Accept: ${3:-application/vnd.github+json}" \
		-H "X-GitHub-Api-Version: 2022-11-28" "$1"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
gpg --batch --armor --export "$REPO_KEY" > "$work/key.asc"
[ -s "$work/key.asc" ] || die "key $REPO_KEY not in GNUPGHOME"
rpmkeys --dbpath "$work/rpmdb" --import "$work/key.asc"

# fetch NAME REPO TAG: downloads, checks and signs the release into
# $work/rel and writes $work/SHA256SUMS; fails (after a warning) on any check.
fetch() {
	local name=$1 repo=$2 tag=$3 d="$work/rel" code f url digest pkg n=0
	rm -rf "$d"
	mkdir -p "$d"
	code=$(get "$api/repos/$repo/releases/tags/$tag" "$work/release.json")
	[ "$code" = 200 ] || {
		warn "$name $tag: release: HTTP $code"
		return 1
	}
	while IFS=$'\t' read -r f url digest; do
		if ! [[ "$f" =~ $file_re ]] || [[ "$f" == *..* ]] || [ "$f" = SHA256SUMS ]; then
			warn "$name $tag: asset name $f not allowed, left out"
			continue
		fi
		[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
			warn "$name $tag: $f has no SHA-256 digest"
			return 1
		}
		code=$(get "$url" "$d/$f" application/octet-stream)
		[ "$code" = 200 ] || {
			warn "$name $tag: $f: HTTP $code"
			return 1
		}
		echo "${digest#sha256:}  $f" | (cd "$d" && sha256sum -c --quiet --status -) || {
			warn "$name $tag: $f does not match the digest GitHub recorded"
			return 1
		}
		pkg=""
		case "$f" in
		*.deb) pkg=$(dpkg-deb -f "$d/$f" Package) || pkg="?" ;;
		*.rpm) pkg=$(rpm -qp --nosignature --qf '%{NAME}' "$d/$f" 2> /dev/null) || pkg="?" ;;
		esac
		if [ -n "$pkg" ] && [ "$pkg" != "$name" ] && [[ "$pkg" != "$name"-* ]]; then
			warn "$name $tag: $f is the package \"$pkg\"; $name may only publish $name and $name-*"
			return 1
		fi
		if [[ "$f" == *.rpm ]]; then
			rpmsign --addsign --define "_gpg_name $REPO_KEY" "$d/$f" > /dev/null
			rpmkeys --dbpath "$work/rpmdb" --checksig "$d/$f" | grep -q 'signatures OK' || {
				warn "$name $tag: signing $f failed"
				return 1
			}
		fi
		n=$((n + 1))
	done < <(jq -r '.assets[] | [.name, .url, (.digest // "")] | @tsv' "$work/release.json")
	[ "$n" -gt 0 ] || {
		warn "$name $tag: no assets"
		return 1
	}
	(cd "$d" && find . -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort | xargs sha256sum) > "$work/SHA256SUMS"
}

mapfile -t lines < <(grep -Ev '^[[:space:]]*(#|$)' "$root/projects.txt")
[ "${#lines[@]}" -gt 0 ] || die "no projects in $root/projects.txt"
rm -rf "$out"
mkdir -p "$out/projects"
: > "$out/projects.txt"
for line in "${lines[@]}"; do
	read -r name repo _ <<< "$line"
	[[ "$name" =~ $name_re ]] || die "bad project name $name"
	case "$name" in apt | rpm | keys | dl | hstin*) die "project name $name is reserved" ;; esac
	[[ "${repo:-}" =~ $repo_re ]] || die "$name: no OWNER/REPO in projects.txt"
	echo "$name $repo" >> "$out/projects.txt"
	rel="$out/projects/$name/releases"
	mkdir -p "$rel"

	code=$(get "$api/repos/$repo/releases?per_page=100" "$work/releases.json")
	[ "$code" = 200 ] || die "$name: the releases of $repo: HTTP $code (is the reader app installed there?)"
	mapfile -t all < <(jq -r '.[] | select(.draft == false and .prerelease == false) | .tag_name' "$work/releases.json" |
		grep -E "$tag_re" | sort -rV)
	tags=()
	for tag in "${all[@]}"; do
		[ "${#tags[@]}" -lt "$keep" ] || break
		if store_has "$name/$tag/SHA256SUMS"; then
			store_get "$name/$tag/SHA256SUMS" "$rel/$tag.sums"
		else
			fetch "$name" "$repo" "$tag" || continue
			while read -r _ f; do
				store_put "$work/rel/$f" "$name/$tag/$f"
			done < "$work/SHA256SUMS"
			store_put "$work/SHA256SUMS" "$name/$tag/SHA256SUMS"
			cp "$work/SHA256SUMS" "$rel/$tag.sums"
			echo "$name $tag: stored $(wc -l < "$work/SHA256SUMS") files"
		fi
		tags+=("$tag")
	done

	# Releases the store holds that are no longer among the kept ones.
	while read -r have; do
		[ -n "$have" ] || continue
		if [ "${#tags[@]}" -eq 0 ]; then
			warn "$name: no release could be kept; the stored ones stay"
			break
		fi
		printf '%s\n' "${tags[@]}" | grep -qxF "$have" && continue
		store_rm "$name" "$have"
		echo "$name $have: removed"
	done < <(store_dirs "$name")

	# The signed update metadata from the branch pkgs.
	code=$(get "$api/repos/$repo/contents/updates?ref=pkgs" "$work/updates.json")
	case "$code" in
	200)
		u="$out/projects/$name/updates"
		mkdir -p "$u"
		while read -r f; do
			[ -n "$f" ] || continue
			code=$(get "$api/repos/$repo/contents/updates/$f?ref=pkgs" "$u/$f" application/vnd.github.raw)
			[ "$code" = 200 ] || die "$name: updates/$f: HTTP $code"
		done < <(jq -r '.[] | select(.type == "file") | .name' "$work/updates.json" | grep -E '^[a-z0-9-]+\.json(\.sig)?$' || true)
		for f in "$u"/*.json; do
			[ -e "$f" ] || continue
			[ -s "$f.sig" ] || {
				warn "$name: updates/$(basename "$f") has no signature; the update metadata stays out"
				rm -rf "$u"
				break
			}
		done
		;;
	404) ;;
	*) die "$name: updates of $repo: HTTP $code" ;;
	esac
done
echo "sync: ${#lines[@]} projects"
