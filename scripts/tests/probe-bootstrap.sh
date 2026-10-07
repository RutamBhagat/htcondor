#!/bin/bash
# Read-only, run with bootstrap-checks.sh prepended as root via SSH stdin.
# Argument: controller|worker. Emits metadata only, never credentials.
set +x
set -euo pipefail
valid_daemon_roles "$1" "$(condor_config_val DAEMON_LIST)"
valid_pool_ipv4 "$(condor_config_val NETWORK_INTERFACE)"
for key in DAEMON_LIST CONDOR_HOST NETWORK_INTERFACE BIND_ALL_INTERFACES; do
    value=$(condor_config_val "$key")
    printf 'CONFIG\t%s\t%s\n' "$key" "$value"
done
printf 'SERVICE\tactive\t%s\n' "$(systemctl is-active condor)"
printf 'SERVICE\tenabled\t%s\n' "$(systemctl is-enabled condor)"
ps -C condor_master,condor_collector,condor_negotiator,condor_schedd,condor_startd,condor_shared_port -o args= |
    awk '{printf "PROCESS\t%s\n", $1}'
ss -H -ltn '( sport = :9618 )' | awk '{printf "LISTENER\t%s\n", $4}'
for key in SEC_PASSWORD_DIRECTORY SEC_TOKEN_SYSTEM_DIRECTORY; do
    directory=$(condor_config_val "$key")
    printf 'CREDENTIAL\tdirectory\t%s\n' "$(stat -c '%a:%u' "$directory")"
    found=false
    for path in "$directory"/*; do
        [ -f "$path" ] || continue
        found=true
        printf 'CREDENTIAL\tfile\t%s\n' "$(stat -c '%a:%u' "$path")"
    done
    if [ "$found" != true ]; then
        echo 'Missing bootstrap credentials' >&2
        exit 1
    fi
done
