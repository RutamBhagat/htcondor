# Working HTCondor contract before OpenVox ownership

Measured read-only on both live hosts on **2026-10-07**, before any OpenVox
installation or manifest application. Source revision:
`982c898740ee7f93de25dfec22f298256759585f`. This is a migration baseline, **not**
a claim that Puppet already manages the pool.

`<controller-private>`, `<worker-private>`, and `<peer-private>` below are
placeholders for generated inventory, never literal manifest values. No live
addresses or credential contents are included.

## Packages and repository

Both hosts: Ubuntu 24.04.5 LTS, `x86_64`; installed Debian package
`condor = 25.0.14-1+ubu24`, architecture `amd64`.

```text
$CondorVersion: 25.0.14 2026-08-30 BuildID: 947353 PackageID: 25.0.14-1+ubu24 $
$CondorPlatform: X86_64-Ubuntu_24.04 $
```

`apt-cache policy condor` confirms installed and candidate versions agree and
come from the HTCondor repository, not Ubuntu's older `23.4.0` package.
Active entries in `/etc/apt/sources.list.d/htcondor.list`:

```text
deb [signed-by=/etc/apt/keyrings/htcondor.asc] https://htcss-downloads.chtc.wisc.edu/repo/ubuntu/25.0 noble main
deb-src [signed-by=/etc/apt/keyrings/htcondor.asc] https://htcss-downloads.chtc.wisc.edu/repo/ubuntu/25.0 noble main
```

Beta/alpha/snapshot entries are commented out. Source list and public key file
are `root:root`, mode `0644`. Public key file SHA256 on both hosts:
`5c20981408b66912dff7aa60116ee1e3915c7e0ed800a17a4099a4b0c830aafc`.
`iptables-persistent` and `netfilter-persistent` are installed at `1.0.20`.
This snapshot is version-specific; changing packages requires retesting it.

## Configuration files and evaluation order

`/etc/condor/condor_config` is package-owned. It sets:

```text
LOCAL_CONFIG_FILE = /etc/condor/condor_config.local
REQUIRE_LOCAL_CONFIG_FILE = false
LOCAL_CONFIG_DIR = /usr/share/condor/config.d,/etc/condor/config.d
```

`condor_config_val -config` lists the main file, the following `/etc/condor/config.d`
files in order, then `condor_config.local` (which is **absent** on both hosts).

| File | Controller | Worker |
| --- | --- | --- |
| `00-security` | present | present |
| `01-central-manager.config` | present | absent |
| `01-submit.config` | present | absent |
| `01-execute.config` | absent | present |
| `02-private-network.config` | present | present |
| `10-stash-plugin.conf` | present | present |

All existing configuration files above are `root:root`, mode `0644`.
`00-security` is package-owned and selects `use security:recommended` on this
version. `10-stash-plugin.conf` is owned by `pelican-osdf-compat`, not the lab;
it appends `$(LIBEXEC)/stash_plugin` to `FILETRANSFER_PLUGINS`. Do not purge
unrelated package configuration while replacing the role/network files.

Controller `01-central-manager.config`:

```text
CONDOR_HOST = <controller-private>
use role:get_htcondor_central_manager
```

Controller `01-submit.config`:

```text
CONDOR_HOST = <controller-private>
use role:get_htcondor_submit
```

Worker `01-execute.config`:

```text
CONDOR_HOST = <controller-private>
use role:get_htcondor_execute
```

Each host's `02-private-network.config`:

```text
NETWORK_INTERFACE = <own-private>
BIND_ALL_INTERFACES = FALSE
```

Measured `DAEMON_LIST`: controller `MASTER COLLECTOR NEGOTIATOR SCHEDD`;
worker `MASTER STARTD`. The shared-port helper also runs on both hosts.
The submit metaknob composes with the controller role; the controller must
never acquire STARTD. Preserve missing opposite-role files, not just the final
DAEMON_LIST. `condor_config_val -verbose` identifies the source of the effective
controller DAEMON_LIST as the submit file and worker DAEMON_LIST as the execute file.

## Authentication and credential boundary

The role metaknobs expand to `use security:get_htcondor_idtokens` plus their
respective native role. Measured security expansion uses recommended security,
sets `TRUST_DOMAIN = $(CONDOR_HOST)`, and appends `ANONYMOUS` to READ/client methods
for compatibility. Effective settings are identical on both hosts:

| Setting | Measured value |
| --- | --- |
| `SEC_DEFAULT_AUTHENTICATION` | `required` |
| `SEC_DEFAULT_ENCRYPTION` | `required` |
| `SEC_DEFAULT_INTEGRITY` | `required` |
| `SEC_DEFAULT_AUTHENTICATION_METHODS` | `FS,IDTOKENS,KERBEROS,SCITOKENS,SSL` |
| `SEC_CLIENT_AUTHENTICATION_METHODS` | default methods plus `ANONYMOUS` |
| `SEC_READ_AUTHENTICATION` | `OPTIONAL` |
| `SEC_ENABLE_MATCH_PASSWORD_AUTHENTICATION` | `true` |
| `TRUST_DOMAIN` | controller private address |
| `ALLOW_READ`, `ALLOW_WRITE` | `*` |
| `ALLOW_DAEMON` | `condor@* condor@password` |
| `ALLOW_NEGOTIATOR` | `condor@* condor@password` |
| `ALLOW_ADMINISTRATOR` | `condor@* condor@password root@*` |

This is upstream IDTOKENS bootstrap security, **not** a switch to host-based or
unauthenticated WRITE access. Local submission uses the official FS-capable
security model; the bootstrap provisions the shared signing key and daemon
IDTOKEN for cross-host communication. The observed method list is configuration,
not a claim that every connection negotiated one particular method.

Both hosts have:

| Path | Owner/group | Mode |
| --- | --- | --- |
| `/etc/condor/passwords.d` | root:root | `0700` |
| `/etc/condor/tokens.d` | root:root | `0700` |
| `/etc/condor/passwords.d/POOL` | root:root | `0600` |
| `/etc/condor/tokens.d/condor@<controller-private>` | root:root | `0600` |

`SEC_PASSWORD_FILE` and `SEC_TOKEN_POOL_SIGNING_KEY_FILE` both resolve to
`/etc/condor/passwords.d/POOL`. The existing pool password is held locally outside
Git; bootstrap receives it via stdin/environment. Do not embed it in manifests,
argv, tracing, or evidence. Credential contents were not read by these host probes.

Controller-only artifacts: `/etc/condor/{hostcert.pem,trust_domain_ca.pem}` are
`root:root/0644`; `{hostkey.pem,trust_domain_ca_privkey.pem}` are
`root:root/0600`. All four are absent on the worker. These are not the effective
SSL server paths: those remain package defaults under `/etc/ssl/`. Do not assume
matching certificate inventories or delete controller artifacts during migration.

`CERTIFICATE_MAPFILE`, `AUTH_SSL_CLIENT_CAFILE`, and `AUTH_SSL_SERVER_CAFILE` are
undefined on both hosts. Explicit READ encryption/integrity and per-DAEMON,
NEGOTIATOR, ADVERTISE_STARTD and ADVERTISE_SCHEDD authentication-method overrides
are also undefined; preserve the distinction between absent overrides and
explicit values. `condor_config_val` exits nonzero for undefined parameters.

## Service and runtime permissions

Service is `condor.service`, active and enabled on both hosts. Package-owned unit:
`/usr/lib/systemd/system/condor.service`; no drop-ins. It starts
`/usr/sbin/condor_master -f` with no User/Group override (root service context).
Reload sends HUP; restart is `on-failure`. Optional environment file
`/etc/sysconfig/condor` is absent. Do not replace the packaged unit unnecessarily.

Account `condor` exists with home `/var/lib/condor`, shell `/usr/sbin/nologin`
(observed UID 111/GID 112; use names, not hardcoded numbers).

| Runtime directory | Owner/group | Mode |
| --- | --- | --- |
| `/var/run/condor`, `/var/lock/condor` | condor:condor | `0775` |
| `/var/log/condor` | condor:root | `0755` |
| `/var/spool/condor`, `/var/lib/condor/execute` | condor:condor | `0755` |

Configured `CRED_STORE_DIR=/var/lib/condor/cred_dir` is absent on both hosts;
this is separate from the root-only pool key/token directories.

## Private networking and host firewall

Both `CONDOR_HOST` values resolve to the controller private address; each
`NETWORK_INTERFACE` is its own private address. Each actual TCP/9618 listener
binds only to that address. Public TCP/9618 probes fail; private worker registration
and the completed remote job provide the positive path.

First INPUT rule on each host, before OCI image's terminal reject:

```text
-A INPUT -s <peer-private>/32 -d <own-private>/32 -p tcp -m tcp --dport 9618 -j ACCEPT
```

It is present in both live iptables and `/etc/iptables/rules.v4`.
`netfilter-persistent.service` is active and enabled. Preserve established/related,
ICMP, loopback, SSH, and unrelated OCI InstanceServices rules; permitting OCI VCN
TCP/9618 alone is insufficient without the measured guest-firewall allowance.
OpenTofu owns the VCN-only cloud rule, not these guest rules.

## Capacity and behavior baseline

E2 micro shape is unchanged. Both machines report 1,000,349,696 bytes RAM and no
swap. At discovery, MemAvailable was controller **569,962,496 bytes**, worker
**564,981,760 bytes**. These are idle point-in-time headroom measurements, **not**
OpenVox installation/apply peak-memory evidence; that measurement is the next task.
`NUM_CPUS` resolves to 2 (detected guest CPUs), `START=True`; explicit NUM_SLOTS,
NUM_SLOTS_TYPE_1, and SLOT_TYPE_1_PARTITIONABLE are undefined. Slice 1 reports one
worker Execute ad; do not confuse detected vCPUs with E2's fractional OCPU budget.
Keep the lab to one small job at a time.

At recording time, all three live bootstrap regressions passed (29 assertions),
and the existing job 1.0 verifier confirmed worker output and normal exit 0.
No new job was submitted. Recheck these after ownership migration:

```sh
HTCONDOR_LIVE_TEST=1 bun test scripts/tests/bootstrap-live.test.ts
# From the submit directory on the controller:
bash scripts/verify-hostname.sh <cluster.proc> worker controller
```

## Collection and references

Read-only SSH probes captured package policy/source/key hash, configuration-file
contents and `-verbose` sources, metaknob expansions, unit/account metadata,
credential **metadata only**, live/persisted firewall rules, and idle memory.
Full methods and raw/sanitized measurements stay ignored under
`.temp/contract/` and `.temp/evidence/slice-2/`.

Consulted [condor_config_val reference](https://htcondor.readthedocs.io/en/25.0/man-pages/condor_config_val.html)
and [get_htcondor installed configuration](https://htcondor.readthedocs.io/en/25.0/man-pages/get_htcondor.html),
plus current documentation through Context7 `/htcondor/htcondor`.
No packages, services, credentials, or firewall rules were changed by this task.
