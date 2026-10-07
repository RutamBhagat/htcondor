#!/bin/bash
# Read-only verification from the submit directory; never submits another job.
set -euo pipefail

if [[ $# -ne 3 || ! $1 =~ ^[0-9]+\.[0-9]+$ || -z $2 || -z $3 || $2 == "$3" ]]; then
  echo 'Usage: scripts/verify-hostname.sh <cluster.proc> <worker-hostname> <controller-hostname> (distinct hosts)' >&2
  exit 2
fi
job_id=$1
worker=$2
controller=$3
prefix=jobs/results/hostname.${job_id}

if ! grep -q '^005 ' "$prefix.log" || ! grep -q 'Normal termination (return value 0)' "$prefix.log"; then
  printf 'Job %s has no successful termination in %s.log\n' "$job_id" "$prefix" >&2
  exit 1
fi
if ! IFS= read -r actual_host < "$prefix.out"; then
  printf 'Cannot read hostname from %s.out\n' "$prefix" >&2
  exit 1
fi
if [[ $actual_host == "$controller" || $actual_host != "$worker" ]]; then
  printf 'Rejected %s: output host %q; expected worker %q, never controller %q\n' "$job_id" "$actual_host" "$worker" "$controller" >&2
  exit 1
fi
printf 'Verified %s executed on %s, not %s\n' "$job_id" "$actual_host" "$controller"
