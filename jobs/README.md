# Hostname job

On the controller, from the repository root:

```sh
condor_submit -dry-run /tmp/hostname.classad jobs/hostname.submit
condor_submit jobs/hostname.submit
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

Syntax reference: [HTCondor 25.0 condor_submit manual](https://htcondor.readthedocs.io/en/25.0/man-pages/condor_submit.html).
