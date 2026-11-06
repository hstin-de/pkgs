# shellcheck shell=bash
# The release files' store, sourced by sync.sh and build.sh. STORE is
# s3://BUCKET (R2 through the S3 API at R2_ENDPOINT, with AWS_ACCESS_KEY_ID
# and AWS_SECRET_ACCESS_KEY) or a local directory (the tests). Keys are
# <project>/<tag>/<file>.

: "${STORE:?STORE is not set (s3://BUCKET or a directory)}"

store_s3() { aws s3 "$@" --endpoint-url "${R2_ENDPOINT:?R2_ENDPOINT is not set}" --only-show-errors; }

# store_get KEY FILE: copies the object to FILE; fails if it does not exist.
store_get() {
	case "$STORE" in
	s3://*) store_s3 cp "$STORE/$1" "$2" ;;
	*) cp "$STORE/$1" "$2" ;;
	esac
}

# store_has KEY
store_has() {
	case "$STORE" in
	s3://*) aws s3api head-object --bucket "${STORE#s3://}" --key "$1" --endpoint-url "$R2_ENDPOINT" > /dev/null 2>&1 ;;
	*) [ -f "$STORE/$1" ] ;;
	esac
}

# store_put FILE KEY
store_put() {
	case "$STORE" in
	s3://*) store_s3 cp "$1" "$STORE/$2" ;;
	*)
		mkdir -p "$(dirname "$STORE/$2")"
		cp "$1" "$STORE/$2.tmp" && mv "$STORE/$2.tmp" "$STORE/$2"
		;;
	esac
}

# store_dirs PROJECT: the tags the store holds for PROJECT, one per line.
store_dirs() {
	case "$STORE" in
	s3://*) store_s3 ls "$STORE/$1/" | awk '$1 == "PRE" { sub(/\/$/, "", $2); print $2 }' ;;
	*) [ ! -d "$STORE/$1" ] || find "$STORE/$1" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' ;;
	esac
}

# store_rm PROJECT TAG: removes PROJECT/TAG/ (its sums first, so a half
# removed release is never taken for a complete one).
store_rm() {
	case "$STORE" in
	s3://*)
		store_s3 rm "$STORE/$1/$2/SHA256SUMS" || true
		store_s3 rm "$STORE/$1/$2/" --recursive
		;;
	*) rm -f "$STORE/$1/$2/SHA256SUMS" && rm -rf "${STORE:?}/$1/$2" ;;
	esac
}
