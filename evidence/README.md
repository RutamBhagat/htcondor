# Sanitized verification evidence

This directory contains only stable outcomes that are safe to publish. The [sanitized transcript](verification.txt) contains selected output from the final checks.

Raw OCI responses, OpenTofu state, live addresses, host keys, credentials, resource IDs, and transient logs stay under ignored `.temp/` paths.

## Remote execution

Source proof: Slice 1 completion at `982c898`, re-proved after the Slice 2 rebuild at `4054d68`.

- Controller role: `MASTER COLLECTOR NEGOTIATOR SCHEDD`. The role has no `STARTD`.
- Worker role: `MASTER STARTD`.
- `condor_status` advertised the worker Execute slot and no controller Execute slot.
- Final rebuilt-pool job `2.0` terminated normally with exit status 0.
- Returned stdout began:

  ```text
  worker
  x86_64
  ```

- The verifier required the exact worker hostname and explicitly rejected controller execution.

## Configuration convergence

Source proof: Slice 2 completion at `4054d68`.

- The OpenVox/Puppet migration applied the measured HTCondor contract on both hosts.
- Each role catalog contains 39 managed resources.
- The immediate second apply on both original hosts reported zero managed changes.
- After the clean rebuild, the immediate second apply again reported zero managed changes. Both hosts returned Puppet detailed exit status 0.
- Full converged-catalog measurements retained roughly 493 MiB available RAM on the controller. The worker retained roughly 488 MiB, with zero swap.

Files in `puppet/manifests/` and `puppet/modules/htcondor/` define the relevant desired state. Guarded helpers receive secrets only as runtime inputs.

## Clean rebuild

Source proof: Slice 2 completion at `4054d68`.

- Before rebuild, authoritative OCI state showed one preserved unrelated A1 and two state-managed E2 micros. Active boot storage totaled 147 GB.
- The inspected destroy plan deleted only the two E2 instances. The A1 and its 47 GB boot disk remained.
- The inspected recreate plan created only two `VM.Standard.E2.1.Micro` instances with 50 GB boot disks.
- Both replacement hosts were Ubuntu 24.04/x86_64 and had neither OpenVox nor HTCondor before repository automation.
- `scripts/apply-config.sh` restored the pool without undocumented host configuration repair.
- The rebuild exposed a first-boot package race. `scripts/install-openvox.sh` now waits for cloud-init with a time limit before changing packages.
- A fresh post-rebuild job then executed on the worker.

## Network boundary

The committed OpenTofu policy in `infra/main.tf` has exactly two ingress purposes:

- SSH/TCP 22 from `var.admin_cidr`, which rejects `0.0.0.0/0`.
- HTCondor/TCP 9618 from `var.vcn_cidr` only.

Live regressions verified that HTCondor listeners bind to private node addresses. Private worker/controller communication succeeded. Public TCP/9618 probes failed as required.

## CI negative control

`.github/workflows/verify.yml` defines the CI gate. During Slice 3, a deliberate syntax error made the validation command fail. Clean checks passed after restoration.

The negative-control transcript stays ignored under `.temp/evidence/slice-3/`. The repository contains only the durable workflow.
