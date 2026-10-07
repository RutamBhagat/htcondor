#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SSH_KEY=${HTCONDOR_SSH_KEY:-"$HOME/.ssh/oci-eu-frankfurt"}
KNOWN_HOSTS=${HTCONDOR_KNOWN_HOSTS:-"$ROOT/.temp/known_hosts"}
POOL_CREDENTIAL=${HTCONDOR_POOL_CREDENTIAL:-"$ROOT/.temp/secrets/htcondor-pool-password"}

for command in tofu jq ssh tar; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$command" >&2
    exit 127
  fi
done

if [[ ! -f "$SSH_KEY" ]]; then
  printf 'SSH key is not a regular file: %s\n' "$SSH_KEY" >&2
  exit 2
fi
if [[ ! -f "$KNOWN_HOSTS" ]]; then
  printf 'Known-hosts file is not a regular file: %s\n' "$KNOWN_HOSTS" >&2
  exit 2
fi
if [[ ! -f "$POOL_CREDENTIAL" || -L "$POOL_CREDENTIAL" || ! -r "$POOL_CREDENTIAL" ]]; then
  printf 'Pool credential must be a readable regular file, not a symlink: %s\n' "$POOL_CREDENTIAL" >&2
  exit 2
fi

public_json=$(tofu -chdir="$ROOT/infra" output -json node_public_ips)
private_json=$(tofu -chdir="$ROOT/infra" output -json node_private_ips)
for json in "$public_json" "$private_json"; do
  if ! printf '%s' "$json" | jq -e 'type == "object" and (keys | sort) == ["controller","worker"] and all(.[]; type == "string" and length > 0)' >/dev/null; then
    echo 'OpenTofu outputs must contain exactly non-empty controller and worker addresses.' >&2
    exit 2
  fi
done

controller_public=$(printf '%s' "$public_json" | jq -er '.controller')
worker_public=$(printf '%s' "$public_json" | jq -er '.worker')
controller_private=$(printf '%s' "$private_json" | jq -er '.controller')
worker_private=$(printf '%s' "$private_json" | jq -er '.worker')

is_ipv4() {
  local value=$1
  local old_ifs=$IFS
  local part
  case "$value" in
    ""|*[!0-9.]*|.*|*..*|*.) return 1 ;;
  esac
  IFS=.
  set -- $value
  IFS=$old_ifs
  [[ $# -eq 4 ]] || return 1
  for part in "$@"; do
    [[ "$part" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
    (( 10#$part <= 255 )) || return 1
  done
}

for address in "$controller_public" "$worker_public" "$controller_private" "$worker_private"; do
  if ! is_ipv4 "$address"; then
    printf 'OpenTofu returned a non-canonical IPv4 address.\n' >&2
    exit 2
  fi
done
if [[ "$controller_public" == "$worker_public" || "$controller_private" == "$worker_private" ]]; then
  echo 'Controller and worker addresses must be distinct.' >&2
  exit 2
fi

SSH=(
  ssh
  -i "$SSH_KEY"
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=$KNOWN_HOSTS"
)

controller_stage=
worker_stage=

cleanup() {
  local original_status=$?
  local cleanup_status=0
  local status
  trap - EXIT
  set +e

  if [[ -n "$controller_stage" ]]; then
    "${SSH[@]}" "ubuntu@$controller_public" "rm -rf -- $controller_stage" >/dev/null
    status=$?
    if [[ $status -ne 0 ]]; then
      echo 'Failed to remove controller staging directory.' >&2
      cleanup_status=$status
    fi
  fi
  if [[ -n "$worker_stage" ]]; then
    "${SSH[@]}" "ubuntu@$worker_public" "rm -rf -- $worker_stage" >/dev/null
    status=$?
    if [[ $status -ne 0 && $cleanup_status -eq 0 ]]; then
      echo 'Failed to remove worker staging directory.' >&2
      cleanup_status=$status
    fi
  fi

  if [[ $original_status -ne 0 ]]; then
    exit "$original_status"
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT

create_stage() {
  local host=$1
  local stage
  stage=$("${SSH[@]}" "ubuntu@$host" 'umask 077; mktemp -d /tmp/htcondor-puppet.XXXXXX')
  if [[ ! "$stage" =~ ^/tmp/htcondor-puppet\.[A-Za-z0-9]{6}$ ]]; then
    echo 'Remote mktemp returned an unexpected staging path.' >&2
    return 2
  fi
  printf '%s\n' "$stage"
}

transfer_role() {
  local role=$1
  local host=$2
  local stage=$3
  local files=(
    "puppet/manifests/$role.pp"
    puppet/modules/htcondor/manifests/init.pp
    puppet/modules/htcondor/templates/role.epp
    puppet/modules/htcondor/templates/private-network.epp
    puppet/modules/htcondor/files/htcondor.asc
    puppet/modules/htcondor/files/credentials.sh
    puppet/modules/htcondor/files/firewall.sh
    scripts/install-openvox.sh
    scripts/with-pool-credential.py
  )
  local file
  for file in "${files[@]}"; do
    if [[ ! -f "$ROOT/$file" ]]; then
      printf 'Required orchestration source is missing: %s\n' "$file" >&2
      return 2
    fi
  done
  tar -C "$ROOT" -cf - "${files[@]}" |
    "${SSH[@]}" "ubuntu@$host" "umask 077; tar -xf - -C '$stage'"
}

ensure_openvox() {
  local role=$1
  local host=$2
  local stage=$3
  local status

  set +e
  "${SSH[@]}" "ubuntu@$host" \
    'if [[ ! -x /opt/puppetlabs/bin/puppet ]]; then exit 3; fi; [[ $(/opt/puppetlabs/bin/puppet --version) == 9.0.0 ]] || exit 4'
  status=$?
  set -e

  case "$status" in
    0)
      printf '%s: OpenVox 9.0.0 already installed\n' "$role"
      ;;
    3)
      "${SSH[@]}" "ubuntu@$host" "cd '$stage' && sudo -n bash scripts/install-openvox.sh"
      printf '%s: installed OpenVox 9.0.0\n' "$role"
      ;;
    *)
      printf '%s: unexpected OpenVox state (%s)\n' "$role" "$status" >&2
      return "$status"
      ;;
  esac
}

apply_role() {
  local role=$1
  local host=$2
  local stage=$3
  local own=$4
  local peer=$5
  local remote_command
  local status

  remote_command="cd '$stage' && sudo -n env FACTER_htcondor_cm=$controller_private FACTER_htcondor_own=$own FACTER_htcondor_peer=$peer python3 scripts/with-pool-credential.py -- /opt/puppetlabs/bin/puppet apply --modulepath='$stage/puppet/modules' --detailed-exitcodes --summarize 'puppet/manifests/$role.pp'"

  set +e
  "${SSH[@]}" "ubuntu@$host" "$remote_command" < "$POOL_CREDENTIAL"
  status=$?
  set -e

  case "$status" in
    0)
      printf '%s: already converged\n' "$role"
      ;;
    2)
      printf '%s: applied changes\n' "$role"
      ;;
    *)
      printf '%s: puppet apply failed (%s)\n' "$role" "$status" >&2
      return "$status"
      ;;
  esac
}

controller_stage=$(create_stage "$controller_public")
transfer_role controller "$controller_public" "$controller_stage"
worker_stage=$(create_stage "$worker_public")
transfer_role worker "$worker_public" "$worker_stage"

ensure_openvox controller "$controller_public" "$controller_stage"
ensure_openvox worker "$worker_public" "$worker_stage"

apply_role controller "$controller_public" "$controller_stage" "$controller_private" "$worker_private"
apply_role worker "$worker_public" "$worker_stage" "$worker_private" "$controller_private"
