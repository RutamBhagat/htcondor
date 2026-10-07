# Sanitized verification evidence

This directory contains only stable outcomes that are safe to publish. Raw OCI responses, OpenTofu plans/state, live addresses, SSH host keys, pool credentials, resource IDs, and transient logs stay under ignored `.temp/` paths.

## Remote execution

Source proof: Slice 1 completion at `982c898`, re-proved after the Slice 2 rebuild at `4054d68`.

- Controller role: `MASTER COLLECTOR NEGOTIATOR SCHEDD`; no `STARTD`.
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
- After the clean rebuild, the immediate second apply again reported zero managed changes on both hosts with Puppet detailed exit status 0.
- Full converged-catalog measurements on the 1 GB E2 micros retained roughly 493 MiB available RAM on the controller and 488 MiB on the worker, with zero swap.

The relevant desired state is visible in `puppet/manifests/` and `puppet/modules/htcondor/`; secrets are inputs to guarded helpers, never manifest/catalog content.

## Clean rebuild

Source proof: Slice 2 completion at `4054d68`.

- Before rebuild, authoritative OCI state showed the preserved unrelated A1 plus the two state-managed E2 micros and 147 GB of active boot storage.
- The inspected destroy plan deleted only the two E2 instances; the A1 and its 47 GB boot disk remained.
- The inspected recreate plan created only two `VM.Standard.E2.1.Micro` instances with 50 GB boot disks.
- Both replacement hosts were Ubuntu 24.04/x86_64 and had neither OpenVox nor HTCondor before repository automation.
- `scripts/apply-config.sh` restored the pool without undocumented host configuration repair.
- The rebuild exposed a first-boot package race; the fix was made upstream in `scripts/install-openvox.sh` by waiting, with a bound, for cloud-init before package mutation.
- A fresh post-rebuild job then executed on the worker.

## Network boundary

The committed OpenTofu policy in `infra/main.tf` has exactly two ingress purposes:

- SSH/TCP 22 from `var.admin_cidr`, which rejects `0.0.0.0/0`.
- HTCondor/TCP 9618 from `var.vcn_cidr` only.

Live regressions independently verified that HTCondor listeners bind to private node addresses, private worker/controller communication succeeds, and TCP/9618 is not reachable through the nodes' public addresses.

## CI negative control

The repository's CI gate is `.github/workflows/verify.yml`. Slice 3 completion includes a deliberate temporary syntax corruption: the intended parser/validation command must fail for that malformed input, after which the change is reverted and the clean checks rerun. The negative-control transcript remains ignored under `.temp/evidence/slice-3/`; only the durable workflow is committed.
