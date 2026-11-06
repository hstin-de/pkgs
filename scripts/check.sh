#!/usr/bin/env bash
# Checks a deployed pkgs.hstin.de: the signed apt metadata, hstin-repo, and a
# release file through the functions (from R2), if any project has one.
#
#   scripts/check.sh [BASE]
set -euo pipefail

base=${1:-https://pkgs.hstin.de}
root=$(cd "$(dirname "$0")/.." && pwd)
curl -fsS "$base/apt/dists/stable/InRelease" | grep -q "Components: main"
curl -fsSI "$base/hstin-repo.deb" > /dev/null
list=$(find "$root/projects" -path '*/releases/v*.txt' | sort -V | tail -1)
if [ -n "$list" ]; then
	project=$(basename "$(dirname "$(dirname "$list")")")
	tag=$(basename "$list" .txt)
	file=$(head -1 "$list")
	curl -fsS -r 0-0 -o /dev/null "$base/dl/$project/$tag/$file"
	echo "ok: $base, $project $tag $file from R2"
else
	echo "ok: $base (no releases yet)"
fi
