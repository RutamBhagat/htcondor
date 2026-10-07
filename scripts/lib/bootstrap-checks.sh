#!/bin/bash
# Shared bootstrap guards. Preserve the measured Ubuntu ipaddress classification
# (including reserved private ranges), without requiring Python on the nodes.
valid_pool_ipv4() {
    local a b c d octet
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r a b c d <<< "$1"
    for octet in "$a" "$b" "$c" "$d"; do
        [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( octet <= 255 )) || return 1
    done
    # Exclude unspecified and loopback, as the original bootstrap did.
    (( a == 127 || (a == 0 && b == 0 && c == 0 && d == 0) )) && return 1
    (( a == 0 || a == 10 || a >= 240 ||
       (a == 169 && b == 254) ||
       (a == 172 && b >= 16 && b <= 31) ||
       (a == 192 && b == 0 && c == 0 && d != 9 && d != 10) ||
       (a == 192 && b == 0 && c == 2) ||
       (a == 192 && b == 168) ||
       (a == 198 && (b == 18 || b == 19)) ||
       (a == 198 && b == 51 && c == 100) ||
       (a == 203 && b == 0 && c == 113) ))
}

valid_daemon_roles() {
    local actual daemon expected
    local -a names
    case "$1" in
        controller) expected='MASTER COLLECTOR NEGOTIATOR SCHEDD' ;;
        worker) expected='MASTER STARTD' ;;
        *) return 1 ;;
    esac
    actual=$(printf '%s' "$2" | tr ',[:space:]' ' ')
    [[ "$actual" =~ [^[:space:]] ]] || return 1
    read -r -a names <<< "$actual"
    # Match sets, not ordering or duplicates; SharedPort is optional in the list.
    for daemon in "${names[@]}"; do
        [[ "$daemon" == SHARED_PORT || " $expected " == *" $daemon "* ]] || return 1
    done
    for daemon in $expected; do
        [[ " $actual " == *" $daemon "* ]] || return 1
    done
}
