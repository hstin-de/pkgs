#!/usr/bin/env bash
# Checks a deployed pkgs.hstin.de against the site built for it: the signed
# apt metadata, hstin-repo, and the latest release's SHA256SUMS of each
# project through the functions (from R2).
#
#   scripts/check.sh BASE OUT
set -euo pipefail

base=${1:?usage: check.sh BASE OUT}
out=${2:?usage: check.sh BASE OUT}
curl -fsS "$base/apt/dists/stable/InRelease" | grep -q "Components: main"
curl -fsSI "$base/hstin-repo.deb" > /dev/null
curl -fsSI "$base/hstin-repo.pkg.tar.zst" > /dev/null
curl -fsSI "$base/arch/x86_64/hstin.db.sig" > /dev/null
for latest in "$out"/*/latest.txt; do
	[ -e "$latest" ] || continue
	project=$(basename "$(dirname "$latest")")
	tag=$(cat "$latest")
	curl -fsS -r 0-0 -o /dev/null "$base/dl/$project/$tag/SHA256SUMS"
	echo "ok: $project $tag from R2"
done
echo "ok: $base"
