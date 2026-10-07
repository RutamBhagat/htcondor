#!/bin/bash
# Own one first-position peer rule; preserve OCI SSH/InstanceServices rules.
set -euo pipefail
if [[ $# != 2 || ! $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || ! $2 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || $1 == "$2" ]]; then
  echo 'Usage: firewall.sh PEER_PRIVATE_IPV4 OWN_PRIVATE_IPV4' >&2
  exit 2
fi
peer=$1
own=$2
rule="-A INPUT -s $peer/32 -d $own/32 -p tcp -m tcp --dport 9618 -j ACCEPT"
first=$(iptables -w -S INPUT | awk '/^-A INPUT/ {print;exit}')
if [[ $first != "$rule" ]]; then
  while iptables -w -C INPUT -s "$peer/32" -d "$own/32" -p tcp --dport 9618 -j ACCEPT 2>/dev/null; do
    iptables -w -D INPUT -s "$peer/32" -d "$own/32" -p tcp --dport 9618 -j ACCEPT
  done
  iptables -w -I INPUT 1 -s "$peer/32" -d "$own/32" -p tcp --dport 9618 -j ACCEPT
fi
# Persistence is separately guarded; a lost saved rule is repaired without
# creating duplicate live rules. No flushing or replacement of OCI rules.
saved_first=$(awk '/^-A INPUT/ {print;exit}' /etc/iptables/rules.v4 2>/dev/null || true)
if [[ $saved_first != "$rule" ]]; then
  netfilter-persistent save
fi
