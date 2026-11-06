#!/usr/bin/env bash
# Publishes a project's release on pkgs.hstin.de: uploads its files to
# the R2 bucket (served at pkgs.hstin.de/dl/), records the file list, drops the oldest
# releases beyond KEEP from both, takes over its signed update metadata, and
# commits and pushes this repository (which deploys the site).
#
#   scripts/publish.sh PROJECT [TAG] DIR
#
# DIR/files/ are the release's files (with TAG), DIR/updates/ the project's
# signed update metadata (*.json and *.json.sig); either may be missing.
#
# Environment: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY (an R2 API token),
# R2_ENDPOINT (https://<account>.r2.cloudflarestorage.com), R2_BUCKET (default
# hstin-dl), KEEP (default 8), DRY_RUN=1 to change nothing remote.
set -euo pipefail

project=${1:?usage: publish.sh PROJECT [TAG] DIR}
if [ $# -eq 3 ]; then tag=$2 dir=$3; else tag="" dir=${2:?usage: publish.sh PROJECT [TAG] DIR}; fi
root=$(cd "$(dirname "$0")/.." && pwd)
bucket=${R2_BUCKET:-hstin-dl}
keep=${KEEP:-8}
[[ "$project" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
	echo "publish.sh: bad project name $project" >&2
	exit 2
}
[ -z "$tag" ] || [[ "$tag" =~ ^v[0-9][A-Za-z0-9.+-]*$ ]] || {
	echo "publish.sh: bad tag $tag" >&2
	exit 2
}
grep -Ev '^[[:space:]]*(#|$)' "$root/projects.txt" | awk '{print $1}' | grep -qx "$project" || {
	echo "publish.sh: $project is not in projects.txt" >&2
	exit 2
}
s3() {
	if [ -n "${DRY_RUN:-}" ]; then
		echo "dry run: aws s3 $*"
	else
		aws s3 "$@" --endpoint-url "${R2_ENDPOINT:?R2_ENDPOINT is not set}" --only-show-errors
	fi
}

rel="$root/projects/$project/releases"
mkdir -p "$rel"
if [ -n "$tag" ]; then
	[ -d "$dir/files" ] || {
		echo "publish.sh: no $dir/files for $tag" >&2
		exit 2
	}
	: > "$rel/$tag.txt"
	for f in "$dir/files"/*; do
		n=$(basename "$f")
		[[ "$n" =~ ^[A-Za-z0-9._+-]+$ ]] || {
			echo "publish.sh: bad file name $n" >&2
			exit 2
		}
		echo "$n" >> "$rel/$tag.txt"
	done
	LC_ALL=C sort -o "$rel/$tag.txt" "$rel/$tag.txt"
	[ -s "$rel/$tag.txt" ] || {
		echo "publish.sh: $dir/files is empty" >&2
		exit 2
	}
	s3 cp "$dir/files/" "s3://$bucket/$project/$tag/" --recursive
	echo "uploaded $(wc -l < "$rel/$tag.txt") files to $bucket/$project/$tag/"
fi
mapfile -t old < <(find "$rel" -maxdepth 1 -name 'v*.txt' -printf '%f\n' | sed 's/\.txt$//' | sort -V | head -n "-$keep")
for t in "${old[@]}"; do
	s3 rm "s3://$bucket/$project/$t/" --recursive
	rm "$rel/$t.txt"
	echo "removed $project $t"
done
if [ -d "$dir/updates" ]; then
	mkdir -p "$root/projects/$project/updates"
	for f in "$dir/updates"/*.json; do
		[ -s "$f.sig" ] || {
			echo "publish.sh: $f has no signature" >&2
			exit 2
		}
		cp "$f" "$f.sig" "$root/projects/$project/updates/"
	done
fi

cd "$root"
git add -A "projects/$project"
if git diff --cached --quiet; then
	echo "nothing changed"
	exit 0
fi
git -c user.name="${GIT_AUTHOR_NAME:-pkgs publish}" -c user.email="${GIT_AUTHOR_EMAIL:-pkgs@hstin.de}" \
	commit -qm "$project: ${tag:-update metadata}"
[ -n "${DRY_RUN:-}" ] && exit 0
for _ in 1 2 3 4 5; do
	git push -q origin HEAD:main && exit 0
	git pull -q --rebase origin main
done
echo "publish.sh: push failed" >&2
exit 1
