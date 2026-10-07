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

See [BASELINE.md](BASELINE.md) for the HTCondor contract that migration must preserve.
Detailed method, raw CSV/JSON, and installation logs remain ignored under
`.temp/evidence/slice-2/openvox/`; summary is `installation.md` there.

References: [OpenVox installation guide](https://voxpupuli.org/openvox/install/),
[APT repository](https://apt.voxpupuli.org/), and the
[Ubuntu 24.04 OpenVox 9 package index](https://apt.voxpupuli.org/dists/ubuntu24.04/openvox9/binary-amd64/Packages).
The guide still illustrates OpenVox 8; the signed repository was checked for a
stable (not beta/RC) OpenVox 9 agent before choosing this version.
