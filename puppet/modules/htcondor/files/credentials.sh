#!/bin/bash
# Official credential tools, with protected input and no secret command arguments.
set +x
set -euo pipefail
if [[ $# != 3 || ($1 != key && $1 != token) || $3 != /* ]]; then
  echo 'Usage: credentials.sh key PROTECTED_INPUT OUTPUT | token IDENTITY OUTPUT' >&2
  exit 2
fi
mode=$1
input=$2
output=$3
[[ ! -L $output ]] || { echo 'Refusing a symlink credential destination.' >&2; exit 1; }
# Adopt the existing credential; this helper deliberately does not rotate keys.
[[ ! -s $output ]] || exit 0
umask 077
scratch=$(mktemp "${output}.XXXXXX")
trap 'rm -f "$scratch"; unset password' EXIT
if [[ $mode == key ]]; then
  [[ -f $input && ! -L $input && $(stat -c '%a:%u:%g' "$input") == 600:0:0 ]] || {
    echo 'Expected root:root/0600 protected credential input.' >&2; exit 1;
  }
  if ! IFS= read -r password < "$input" || [[ ! $password =~ ^[0-9a-f]{64}$ ]]; then
    echo 'Expected newline-terminated 256-bit hex pool password.' >&2; exit 1
  fi
  # Preserve upstream's stdin representation: no trailing newline is passed.
  if ! printf '%s' "$password" | _CONDOR_SEC_PASSWORD_FILE="$scratch" condor_store_cred add -c -i - >/dev/null 2>&1; then
    echo 'Pool key generation failed.' >&2; exit 1
  fi
  unset password
else
  [[ $input =~ ^condor@[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid daemon identity.' >&2; exit 2; }
  if ! condor_token_create -identity "$input" > "$scratch" 2>/dev/null; then
    echo 'Daemon token generation failed.' >&2; exit 1
  fi
fi
[[ -s $scratch ]] || { echo 'Credential tool produced an empty file.' >&2; exit 1; }
chmod 0600 "$scratch"
mv -f "$scratch" "$output"
