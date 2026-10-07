#!/bin/bash
# First-install bootstrap only; desired-state ownership moves to OpenVox in Slice 2.
# Run as root over SSH, with the pool password supplied on stdin (never argv).
# Usage: bootstrap-node.sh controller|worker CM_PRIVATE_IP OWN_PRIVATE_IP PEER_PRIVATE_IP
set +x
set -euo pipefail
# shellcheck disable=SC1091 # Runtime-relative helper; bootstrap is copied with lib/.
source "$(dirname "${BASH_SOURCE[0]}")/lib/bootstrap-checks.sh"

if [ "$#" -ne 4 ] || [[ "$1" != controller && "$1" != worker ]]; then
    echo 'Usage: bootstrap-node.sh controller|worker CM_PRIVATE_IP OWN_PRIVATE_IP PEER_PRIVATE_IP' >&2
    exit 2
fi
role=$1
cm=$2
own=$3
peer=$4
for address in "$cm" "$own" "$peer"; do
    if ! valid_pool_ipv4 "$address"; then
        echo 'Pool addresses must be private, non-loopback IPv4 addresses' >&2
        exit 2
    fi
done
if [[ "$own" == "$peer" ]] || [[ "$role" == controller && "$cm" != "$own" ]] || [[ "$role" == worker && "$cm" != "$peer" ]]; then
    echo 'Addresses do not match the two-node topology' >&2
    exit 2
fi
if ! IFS= read -r GET_HTCONDOR_PASSWORD || [[ ! "$GET_HTCONDOR_PASSWORD" =~ ^[0-9a-f]{64}$ ]]; then
    echo 'Expected one newline-terminated 256-bit hex pool password on stdin' >&2
    exit 2
fi
if [ "$(id -u)" -ne 0 ]; then
    echo 'Run as root' >&2
    exit 2
fi
if [ -f /etc/condor/condor_config ]; then
    echo 'Existing HTCondor installation: refusing to overwrite or reinstall' >&2
    exit 1
fi
# These are present in the measured OCI Ubuntu image. Do not silently drop persistence.
dpkg-query -W iptables-persistent netfilter-persistent >/dev/null
systemctl is-enabled --quiet netfilter-persistent
ip -4 address show | grep -F "inet $own/" >/dev/null

installer=$(mktemp)
trap 'rm -f "$installer"; unset GET_HTCONDOR_PASSWORD' EXIT
curl -fsSL --connect-timeout 10 --max-time 60 https://get.htcondor.org -o "$installer"
bash -n "$installer"
sha256sum "$installer"
export GET_HTCONDOR_PASSWORD
if [ "$role" = controller ]; then
    install_role=--central-manager
else
    install_role=--execute
fi
# Never dry-run with the real password: upstream dry-run prints it.
timeout 15m bash "$installer" --no-dry-run --channel lts "$install_role" "$cm"
unset GET_HTCONDOR_PASSWORD

if [ "$role" = controller ]; then
    # Official installer cannot be run twice; role metaknobs compose additively.
    printf 'CONDOR_HOST = %s\nuse role:get_htcondor_submit\n' "$cm" > /etc/condor/config.d/01-submit.config
    chmod 0644 /etc/condor/config.d/01-submit.config
fi
printf 'NETWORK_INTERFACE = %s\nBIND_ALL_INTERFACES = FALSE\n' "$own" > /etc/condor/config.d/02-private-network.config
chmod 0644 /etc/condor/config.d/02-private-network.config

# Preserve OCI's SSH and InstanceServices rules; permit only the other pool node.
if ! iptables -w -C INPUT -s "$peer/32" -d "$own/32" -p tcp --dport 9618 -j ACCEPT 2>/dev/null; then
    iptables -w -I INPUT 1 -s "$peer/32" -d "$own/32" -p tcp --dport 9618 -j ACCEPT
fi
netfilter-persistent save

# Verify the actual installed configuration, not assumptions about upstream defaults.
daemons=$(condor_config_val DAEMON_LIST)
if ! valid_daemon_roles "$role" "$daemons"; then
    printf 'Unexpected daemon roles: %s\n' "$daemons" >&2
    exit 1
fi
test "$(condor_config_val CONDOR_HOST)" = "$cm"
test "$(condor_config_val NETWORK_INTERFACE)" = "$own"
test "$(condor_config_val BIND_ALL_INTERFACES | tr '[:upper:]' '[:lower:]')" = false
systemctl restart condor
systemctl is-active --quiet condor
condor_version
printf '%s DAEMON_LIST = %s\n' "$role" "$daemons"
