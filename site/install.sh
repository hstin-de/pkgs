#!/bin/sh
# Sets up the hstin package repository (@BASE@) by installing hstin-repo,
# which brings the apt source, dnf repository or pacman mirrorlist and the
# signing key along, then installs the packages given, if any. Afterwards:
# apt install PACKAGE, dnf install PACKAGE or pacman -Syu PACKAGE. On Arch,
# installing packages upgrades the whole system (pacman -Syu): Arch does not
# support partial upgrades.
#
#   cd "$(mktemp -d)" && curl -fsSLO @BASE@/install.sh && less install.sh && sudo sh install.sh [PACKAGE…]
#
# Everything runs from main, called on the last line: a broken download runs
# nothing.
set -eu

main() {
	base=${PKGS_URL:-@BASE@}
	for p in "$@"; do
		case "$p" in "" | -* | *[!a-z0-9.+-]*)
			echo "bad package name $p" >&2
			exit 2
			;;
		esac
	done
	[ "$(id -u)" = 0 ] || {
		echo "run as root (sudo sh install.sh)" >&2
		exit 1
	}
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT
	chmod 755 "$tmp"

	if command -v apt-get > /dev/null; then
		fetch "$base/hstin-repo.deb" "$tmp/hstin-repo.deb"
		chmod 644 "$tmp/hstin-repo.deb"
		DEBIAN_FRONTEND=noninteractive apt-get install -y "$tmp/hstin-repo.deb"
		apt-get update
		[ $# -eq 0 ] || DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
		cmd="apt install"
	elif command -v dnf > /dev/null || command -v yum > /dev/null; then
		dnf=dnf
		command -v dnf > /dev/null || dnf=yum
		fetch "$base/hstin-repo.rpm" "$tmp/hstin-repo.rpm"
		"$dnf" install -y "$tmp/hstin-repo.rpm"
		[ $# -eq 0 ] || "$dnf" install -y "$@"
		cmd="$dnf install"
	elif command -v pacman > /dev/null; then
		fetch "$base/hstin-repo.pkg.tar.zst" "$tmp/hstin-repo.pkg.tar.zst"
		pacman -U --needed --noconfirm "$tmp/hstin-repo.pkg.tar.zst"
		if ! grep -q '^\[hstin\]' /etc/pacman.conf; then
			printf '\n[hstin]\nInclude = /etc/pacman.d/hstin-mirrorlist\n' >> /etc/pacman.conf
		fi
		[ $# -eq 0 ] || pacman -Syu --needed --noconfirm "$@"
		cmd="pacman -Syu"
	else
		echo "no apt, dnf or pacman: see $base for downloads" >&2
		exit 1
	fi
	echo "The hstin repository is set up${1:+, installed: $*}. More with: $cmd PACKAGE"
}

# fetch URL FILE: HTTPS only (redirects included) when the URL is HTTPS.
fetch() {
	case "$1" in
	https://*)
		if command -v curl > /dev/null; then
			curl -fsSL --proto '=https' --tlsv1.2 "$1" -o "$2"
		else
			wget -q --https-only -O "$2" "$1"
		fi
		;;
	*) if command -v curl > /dev/null; then curl -fsSL "$1" -o "$2"; else wget -qO "$2" "$1"; fi ;;
	esac
}

main "$@"
