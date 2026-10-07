# Standalone OpenVox agent

Both Ubuntu 24.04/amd64 E2 hosts have **OpenVox 9.0.0** installed via Vox Pupuli's
signed APT repository. Only `openvox9-release` and `openvox-agent` were installed;
no existing package was upgraded or removed. No Puppet Server was installed.
`/opt/puppetlabs/bin/puppet --version` returns `9.0.0`.

The agent service is deliberately **masked and inactive**. Installation's
postinst tries to enable `puppet.service`; the persistent mask prevents polling
an unconfigured server. The resulting masked-unit message during installation
is expected. Use standalone `puppet apply`, not a running agent daemon.

On a fresh supported host, from the repository root:

```sh
sudo bash scripts/install-openvox.sh --check
sudo python3 scripts/lib/measure-memory.py /tmp/openvox-install-memory -- \
  bash scripts/install-openvox.sh
/opt/puppetlabs/bin/puppet --version
sudo python3 scripts/lib/measure-memory.py /tmp/openvox-smoke-memory -- \
  /opt/puppetlabs/bin/puppet apply --detailed-exitcodes --summarize \
  --execute 'notice("standalone agent smoke: no managed host resources")'
```

Output directories must not already exist; retain `samples.csv` and
`summary.json`. Commands/arguments are recorded in the summary: never pass
credentials as arguments. Run Python's sampler only on Linux; its RSS units are
Linux KiB. It preserves the command exit status, including detailed apply codes:
0 unchanged, 2 changed, 4 failures, 6 changes plus failures (1 other error).

The installer pins the stable `9.0.0-1+ubuntu24.04` package, verifies the repository
release package checksum, requires successful APT metadata refresh, and refuses
removals or installation/upgrades of unrelated packages. It is first-install-only:
it refuses an existing configuration-management stack. Diagnose partial failures
rather than blindly rerunning or unmasking the service.

## Measured E2 headroom

Measured 2026-10-07, with HTCondor running, 954.0 MiB RAM, no swap. Samples every
0.25 seconds, plus kernel child `ru_maxrss`:

| Host / command | Sampled peak unavailable RAM (MiB) | Minimum available (MiB) | Child max RSS (MiB) |
| --- | ---: | ---: | ---: |
| controller / install | 493.4 | 460.6 | 174.6 |
| worker / install | 493.7 | 460.3 | 174.3 |
| controller / smoke apply | 464.4 | 489.6 | 69.3 |
| worker / smoke apply | 461.1 | 492.9 | 69.2 |

All four commands exited 0. Neither host swapped or recorded an OOM event in the
installation window. Fresh HTCondor regressions passed, the existing worker job
still verifies, and captured role/security/configuration/credential metadata
matches the pre-install baseline byte-for-byte.

“Unavailable” is global `MemTotal - MemAvailable`, not incremental memory used by
OpenVox. The requested interval was 250 ms; observed maximum gaps were 543 ms
(controller install), 349 ms (worker install), 301 ms (controller apply), and
343 ms (worker apply). Brief global peaks can be missed. Kernel child max RSS is the
largest child-process high-water mark, not total simultaneous process-tree RSS.
This smoke apply contains no managed host resources; **real module apply peaks
still require measurement when the catalog exists**. No capacity increase was
needed for the tested installation/smoke workload; larger-catalog capacity remains
unproven. No swap, parallel jobs, or infrastructure resize was added.

## HTCondor desired-state code (not applied yet)

`manifests/controller.pp` and `manifests/worker.pp` use one local module,
`modules/htcondor`. No Forge dependencies or server are required. The module owns
the signed HTCondor repository/key, pinned Condor package, role/security/private
binding files, opposite-role absence, credential permissions, runtime directory
ownership, Condor service, and the peer-only live/persistent guest firewall rule.
It preserves unrelated package configuration, queue data, SSH, and OCI rules.

From a staged repository root on the target Ubuntu host, with private addresses
from generated inventory (not literal placeholders):

```sh
sudo env FACTER_htcondor_cm="$cm" FACTER_htcondor_own="$own" \
  FACTER_htcondor_peer="$peer" /opt/puppetlabs/bin/puppet apply \
  --modulepath="$PWD/puppet/modules" --noop --detailed-exitcodes --summarize \
  puppet/manifests/controller.pp  # worker.pp on the worker
```

The facts are non-secret topology only. A fresh install additionally requires
`/run/htcondor-pool-password` as a root:root/0600 regular file containing the
newline-terminated 64-character lowercase hex credential. Credential values are
never catalog parameters, facts, file content, or command arguments. Existing
nonempty key/token files are adopted, not regenerated; key rotation is not
supported by this first migration. SSH orchestration is the next checklist item.

### Protected credential input

`scripts/with-pool-credential.py` runs one trusted command as root, reading exactly
one credential line from stdin. It publishes `/run/htcondor-pool-password` only
after writing a complete 0600 file in a private 0700 directory. An existing file
or symlink is never overwritten. The child gets no credential stdin, argv, or
new environment variable; it reads the protected path only when necessary.

With the public script already staged on a host, a harmless transfer smoke check
from the local repository root is:

```sh
ssh -i "$key" -o BatchMode=yes -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$known_hosts" "ubuntu@$host" \
  "cd '$staged_repo' && sudo -n python3 scripts/with-pool-credential.py -- /opt/puppetlabs/bin/puppet --version" \
  < .temp/secrets/htcondor-pool-password
```

For the eventual apply, replace the version command with the correct standalone
apply command and its non-secret topology facts. Never use a literal password in
shell commands or tracing, and never add the credential to the source archive.
The local source must remain ignored and mode 0600. Input must be a file/closed
pipe, not interactive stdin. The wrapper's strict single-line boundary deliberately
rejects extra trailing data; the existing bootstrap/helper readline behavior is
unchanged.

The wrapper preserves command exit codes (including Puppet's change code 2),
terminates its private child process group on interruption/completion, and removes
only its own input inode and scratch directory. Cleanup failures return nonzero.
INT/TERM/HUP cleanup is tested; SIGKILL, a kernel crash, or filesystem failure can
leave a root-only file. Inspect and remove stale input explicitly before retrying;
the wrapper will not silently replace it. This is not a sandbox or log redactor:
run only trusted catalog/helpers that never print credential contents.

Native package/file/service resources cover ordinary state. Guarded execs cover
APT metadata refresh, preventing first-install daemon startup before credentials,
official key/token generation, and preserving the OCI firewall while inserting
one first-position peer rule. Service refreshes occur only on managed changes.

Deliberate first-apply formatting deltas: omit inactive repository entries and
role comments, and replace the pinned package's security version conditional
with its effective `use security:recommended`. Noop plans on both hosts show
only those three file normalizations plus the two new helper scripts; credentials,
private binding, runtime permissions, packages, and firewall are already aligned.
Both noop runs exited 0 despite five planned file changes: **noop exit 0 is not
convergence proof**. Real application, measured catalog memory, second no-change
application, and clean rebuild remain unverified.

Validation from the repository root on an Ubuntu 24.04 host with the agent installed:

```sh
/opt/puppetlabs/bin/puppet parser validate puppet/manifests/*.pp puppet/modules/htcondor/manifests/*.pp
python3 scripts/tests/check-puppet-catalogs.py
bun run test
```

The catalog checker compiles both real role entrypoints, checks resources and
rendered templates, and rejects missing/empty/noncanonical/public addresses and
wrong topology. It preserves the measured bootstrap's accepted reserved-private
ranges. Removing private-address classification in disposable staged code made
the checker fail, proving the negative cases are not merely rejected by topology.
Helper tests cover first-position/persistent firewall repair and repeat safety,
OCI rule preservation, credential adoption, private atomic writes, secret-output
suppression, symlinks, malformed input, and failure propagation. Actual HTCondor
credential CLIs were additionally tested using disposable dummy keys/tokens;
no real pool credential was read or changed.

See [BASELINE.md](BASELINE.md) for the HTCondor contract that migration must preserve.
Detailed method, raw CSV/JSON, and installation logs remain ignored under
`.temp/evidence/slice-2/openvox/`; summary is `installation.md` there.

References: [OpenVox installation guide](https://voxpupuli.org/openvox/install/),
[APT repository](https://apt.voxpupuli.org/), and the
[Ubuntu 24.04 OpenVox 9 package index](https://apt.voxpupuli.org/dists/ubuntu24.04/openvox9/binary-amd64/Packages).
The guide still illustrates OpenVox 8; the signed repository was checked for a
stable (not beta/RC) OpenVox 9 agent before choosing this version.
