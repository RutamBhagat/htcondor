#!/bin/bash
# Agent-only, pinned Ubuntu 24.04/amd64 installation. No Puppet Server/catalog.
set +x
set -euo pipefail

if [[ $# -gt 1 || (${1:-} != '' && ${1:-} != --check) ]]; then
  echo 'Usage: scripts/install-openvox.sh [--check]' >&2
  exit 2
fi
[[ $(id -u) == 0 ]] || { echo 'Run as root.' >&2; exit 1; }
# shellcheck disable=SC1091 # Host OS metadata is supplied by Ubuntu.
. /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 && $(dpkg --print-architecture) == amd64 ]] || {
  echo 'Only Ubuntu 24.04 amd64 is supported.' >&2; exit 1;
}
for tool in curl sha256sum apt-get dpkg dpkg-query systemctl python3 timeout cloud-init; do
  command -v "$tool" >/dev/null
done
# Refuse to replace existing configuration-management stacks.
if [[ -e /opt/puppetlabs/bin/puppet ]] || command -v puppet >/dev/null; then
  echo 'Configuration-management software already installed; inspect before migrating.' >&2
  exit 1
fi
for package in openvox-agent puppet-agent puppetserver openvox-server; do
  status=$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)
  if [[ $status == installed ]]; then
    echo 'Configuration-management package already installed; inspect before migrating.' >&2
    exit 1
  fi
done
dpkg-query -W -f='${db:Status-Status}' lsb-release | grep -qx installed
printf 'Supported host: %s, Ubuntu %s, amd64\n' "$(hostname)" "$VERSION_ID"
[[ ${1:-} != --check ]] || exit 0

# Fresh OCI images may still be finishing cloud-init package work when SSH first
# becomes available. Wait for that bounded lifecycle signal instead of racing
# dpkg's frontend lock or deleting lock files.
timeout 180s cloud-init status --wait >/dev/null

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
curl -fsSL --connect-timeout 10 --max-time 90 \
  https://apt.voxpupuli.org/openvox9-release-ubuntu24.04.deb -o "$scratch/release.deb"
printf '%s  %s\n' 4f8ffd4d5cc5d47b61e95d8d7ded2ba80d7eb902e478178ea988a5649e5777d3 "$scratch/release.deb" | sha256sum -c -
# postinst enables puppet.service; a persistent mask prevents agent polling.
systemctl mask puppet.service
export DEBIAN_FRONTEND=noninteractive
# This release package supplies APT's signing key; agent downloads are verified
# by APT against its signed repository metadata.
dpkg -i "$scratch/release.deb"
apt-get update --error-on=any
version=9.0.0-1+ubuntu24.04
apt-get -s --no-install-recommends install "openvox-agent=$version" > "$scratch/apt-plan"
# This slice must not replace HTCondor or upgrade unrelated software.
if grep -q '^Remv ' "$scratch/apt-plan" || grep '^Inst ' "$scratch/apt-plan" | grep -qv '^Inst openvox-agent '; then
  echo 'Unexpected package changes; refusing installation.' >&2
  exit 1
fi
apt-get install -y --no-install-recommends "openvox-agent=$version"
systemctl mask --now puppet.service
[[ $(systemctl is-enabled puppet.service) == masked ]]
if systemctl is-active --quiet puppet.service; then echo 'Unexpected running Puppet agent.' >&2; exit 1; fi
[[ $(dpkg-query -W -f='${Version}' openvox-agent) == "$version" ]]
[[ $(/opt/puppetlabs/bin/puppet --version) == 9.0.0 ]]
printf 'Standalone agent installed: %s; puppet.service masked, no server.\n' "$version"
