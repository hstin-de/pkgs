#!/bin/sh
# Installs @PROJECT@ from @BASE@: sets up its signed apt component or dnf
# repository, then installs the package (default @PROJECT@).
#
#   curl -fsSL @BASE@/@PROJECT@/install.sh | sudo sh [-s -- PACKAGE]
set -eu

project=@PROJECT@
pkg=${1:-$project}
base=${PKGS_URL:-@BASE@}
case "$pkg" in "" | *[!a-z0-9.+-]*)
	echo "bad package name $pkg" >&2
	exit 2
	;;
esac
[ "$(id -u)" = 0 ] || {
	echo "run as root (sudo sh)" >&2
	exit 1
}

fetch() {
	if command -v curl > /dev/null; then curl -fsSL "$1" -o "$2"; else wget -qO "$2" "$1"; fi
}

if command -v apt-get > /dev/null; then
	fetch "$base/keys/hstin.gpg" /usr/share/keyrings/hstin.gpg
	chmod 644 /usr/share/keyrings/hstin.gpg
	fetch "$base/apt/$project.sources" "/etc/apt/sources.list.d/$project.sources"
	apt-get update -o "Dir::Etc::sourcelist=sources.list.d/$project.sources" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0
	DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
elif command -v dnf > /dev/null || command -v yum > /dev/null; then
	mkdir -p /etc/pki/rpm-gpg
	fetch "$base/keys/hstin.asc" /etc/pki/rpm-gpg/RPM-GPG-KEY-hstin
	fetch "$base/rpm/$project/$project.repo" "/etc/yum.repos.d/$project.repo"
	if command -v dnf > /dev/null; then dnf install -y "$pkg"; else yum install -y "$pkg"; fi
else
	echo "no apt or dnf: see the project's releases on GitHub" >&2
	exit 1
fi
echo "$pkg installed."
