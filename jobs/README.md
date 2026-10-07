# Hostname job

On the controller, from the repository root:

```sh
condor_submit -dry-run /tmp/hostname.classad jobs/hostname.submit
bash scripts/submit-hostname.sh 180
```

The single vanilla job transfers `hostname.sh` to the execute host's scratch
directory and returns stdout/stderr on exit. No shared filesystem is required.
It prints hostname, machine architecture, and UTC date; it needs Linux's
`/bin/sh`, `hostname`, `uname`, and `date`, but no architecture-specific binary.
The requirements explicitly reference `Arch` without constraining its value to
avoid HTCondor's default submit-host architecture restriction.

Results and the event log are written under `jobs/results/`, keyed by cluster
and process ID and ignored by Git. A dry run validates submission without
queueing or executing a job; it does not prove remote execution.

The submission script displays `condor_q` for the new job, then uses
`condor_wait -wait 180` on its event log. It also requires a normal zero-exit
termination: `condor_wait` alone returns success for aborted jobs too.
On timeout or failure it exits nonzero and preserves the job and log for
diagnosis; inspect `condor_q <id>` and remove with `condor_rm <id>` if unwanted.
Run it once, then diagnose the existing job rather than blindly resubmitting.
Successful termination does not by itself verify the worker hostname in stdout.

Syntax reference: [HTCondor 25.0 condor_submit manual](https://htcondor.readthedocs.io/en/25.0/man-pages/condor_submit.html).
