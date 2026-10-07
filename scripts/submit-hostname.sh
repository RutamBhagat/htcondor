#!/bin/bash
# Run on the controller from the repository root. Timeout leaves the job
# available for diagnosis: condor_q <id>; condor_rm <id> if no longer wanted.
set -euo pipefail

wait_seconds=${1:-180}
if [[ $# -gt 1 || ! $wait_seconds =~ ^[1-9][0-9]*$ ]]; then
  echo 'Usage: scripts/submit-hostname.sh [positive-wait-seconds]' >&2
  exit 2
fi

submitted=$(condor_submit -terse jobs/hostname.submit)
printf 'Submitted %s\n' "$submitted"
# This submit file queues exactly one process. Reject unexpected output.
if [[ ! $submitted =~ ^([0-9]+)\.0[[:space:]]+-[[:space:]]+([0-9]+)\.0$ || ${BASH_REMATCH[1]} != "${BASH_REMATCH[2]}" ]]; then
  echo 'Unexpected submission result; inspect condor_q before retrying.' >&2
  exit 1
fi
job_id=${BASH_REMATCH[1]}.0
log=jobs/results/hostname.${job_id}.log
condor_q "$job_id"
if ! condor_wait -wait "$wait_seconds" "$log" "$job_id"; then
  printf 'Wait failed for %s; inspect condor_q %s and %s. Job not removed.\n' "$job_id" "$job_id" "$log" >&2
  exit 1
fi
# condor_wait also succeeds for aborted jobs. A zero exit is not enough.
if ! grep -q '^005 ' "$log" || ! grep -q 'Normal termination (return value 0)' "$log"; then
  printf 'Job %s did not terminate successfully; inspect %s.\n' "$job_id" "$log" >&2
  exit 1
fi
printf 'Completed %s successfully; results: jobs/results/hostname.%s.{out,err,log}\n' "$job_id" "$job_id"
