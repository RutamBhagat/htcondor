# Two-node HTCondor lab on OCI

[![verify](https://github.com/RutamBhagat/htcondor/actions/workflows/verify.yml/badge.svg)](https://github.com/RutamBhagat/htcondor/actions/workflows/verify.yml)

Two-node HTCondor pool on Linux, provisioned with OpenTofu and managed with OpenVox/Puppet code, proving remote batch execution, configuration convergence, reproducible lifecycle automation, and restricted scheduler networking.

## What is proven

| Claim | Evidence |
| --- | --- |
| Remote batch execution | A job submitted on `controller` completed on `worker`; the controller has no Execute daemon. See [evidence/README.md](evidence/README.md#remote-execution). |
| OpenVox/Puppet ownership | Both role catalogs own the measured HTCondor state; an immediate second apply reported zero managed changes. See [configuration convergence](evidence/README.md#configuration-convergence). |
| Reproducible lifecycle | Both E2 nodes were destroyed, recreated with OpenTofu, and restored from repository automation without undocumented host configuration repair. See [clean rebuild](evidence/README.md#clean-rebuild). |
| Private scheduler path | TCP/9618 is allowed by OCI only from the VCN CIDR; live regressions reject public reachability while private HTCondor communication succeeds. See [network boundary](evidence/README.md#network-boundary). |
| Credential-free CI validation | GitHub Actions runs OpenTofu format/init/validate, Puppet parser validation, and ShellCheck without OCI credentials. The workflow intentionally never plans or applies cloud resources. |

## Architecture

```text
Internet
   |
SSH from admin CIDR only
   |
+---------------- OCI VCN ----------------+
|                                          |
| controller                               | worker
| CentralManager + Submit  -- TCP/9618 --> | Execute
| private address                          | private address
+------------------------------------------+
```

Responsibility boundaries are deliberately narrow:

```text
OpenTofu       -> OCI infrastructure and network policy
OpenVox/Puppet -> Linux desired state
systemd        -> HTCondor service supervision
HTCondor       -> scheduling and remote execution
```

## Repository map

- `infra/` — OCI VCN, scoped security list, public subnet, and exactly two `VM.Standard.E2.1.Micro` instances.
- `puppet/` — standalone OpenVox/Puppet manifests and the local HTCondor module.
- `scripts/apply-config.sh` — stages the minimum files to each node, installs OpenVox when absent, and applies the correct role catalog.
- `jobs/` — one architecture-independent HTCondor job with file transfer enabled.
- `scripts/submit-hostname.sh` and `scripts/verify-hostname.sh` — bounded submission and returned-output verification.
- `evidence/` — sanitized, stable verification results; raw plans, addresses, state, credentials, and transient logs remain ignored under `.temp/`.

## Reproduce

Prerequisites: OpenTofu, OCI CLI/profile access, `jq`, SSH/`ssh-keyscan`, Python 3, an administrator CIDR, and an SSH key pair.

Generate the pool credential locally without printing it:

```sh
install -d -m 700 .temp/secrets
umask 077
python3 -c 'import secrets; print(secrets.token_hex(32))' \
  > .temp/secrets/htcondor-pool-password
chmod 600 .temp/secrets/htcondor-pool-password
```

Create an ignored `infra/lab.auto.tfvars` with the required tenancy/image/availability-domain values and your administrator CIDR/public key, then inspect before applying:

```sh
tofu -chdir=infra fmt -check -recursive
tofu -chdir=infra init
tofu -chdir=infra validate
tofu -chdir=infra plan -out=lab.tfplan
tofu -chdir=infra show lab.tfplan
tofu -chdir=infra apply lab.tfplan
```

Establish repeatable SSH host-key observations for the two newly created public addresses. Review the resulting fingerprints before using them as trust material; do not disable host-key checking:

```sh
install -d -m 700 .temp/hostkeys
: > .temp/known_hosts
for role in controller worker; do
  host=$(tofu -chdir=infra output -json node_public_ips | jq -r --arg role "$role" '.[$role]')
  for attempt in 1 2 3; do
    ssh-keyscan -T 10 "$host" 2>/dev/null | sort > ".temp/hostkeys/$role.$attempt"
  done
  cmp ".temp/hostkeys/$role.1" ".temp/hostkeys/$role.2"
  cmp ".temp/hostkeys/$role.1" ".temp/hostkeys/$role.3"
  ssh-keygen -lf ".temp/hostkeys/$role.1"
  cat ".temp/hostkeys/$role.1" >> .temp/known_hosts
done
chmod 600 .temp/known_hosts
```

With those fingerprints reviewed and the intended SSH key selected, converge both hosts:

```sh
HTCONDOR_SSH_KEY="$HOME/.ssh/oci-eu-frankfurt" \
HTCONDOR_KNOWN_HOSTS="$PWD/.temp/known_hosts" \
HTCONDOR_POOL_CREDENTIAL="$PWD/.temp/secrets/htcondor-pool-password" \
  scripts/apply-config.sh

# Run the same command again: both roles must report "already converged".
HTCONDOR_SSH_KEY="$HOME/.ssh/oci-eu-frankfurt" \
HTCONDOR_KNOWN_HOSTS="$PWD/.temp/known_hosts" \
HTCONDOR_POOL_CREDENTIAL="$PWD/.temp/secrets/htcondor-pool-password" \
  scripts/apply-config.sh
```

Stage only the job and its two helpers to the controller, then submit there:

```sh
controller=$(tofu -chdir=infra output -json node_public_ips | jq -r '.controller')
ssh_opts=(
  -i "$HOME/.ssh/oci-eu-frankfurt"
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile="$PWD/.temp/known_hosts"
)
tar -cf - jobs scripts/submit-hostname.sh scripts/verify-hostname.sh |
  ssh "${ssh_opts[@]}" "ubuntu@$controller" \
    'rm -rf ~/htcondor-job && mkdir ~/htcondor-job && tar -xf - -C ~/htcondor-job'
ssh "${ssh_opts[@]}" "ubuntu@$controller" \
  'cd ~/htcondor-job && condor_status && bash scripts/submit-hostname.sh 180'
# Use the returned cluster.process identifier:
ssh "${ssh_opts[@]}" "ubuntu@$controller" \
  'cd ~/htcondor-job && bash scripts/verify-hostname.sh <cluster.process> worker controller'
```

Local, credential-free validation is the same mechanism used by CI:

```sh
tofu -chdir=infra fmt -check -recursive
tofu -chdir=infra init -backend=false -input=false
tofu -chdir=infra validate
/opt/puppetlabs/bin/puppet parser validate \
  puppet/manifests/*.pp puppet/modules/htcondor/manifests/*.pp
shellcheck scripts/*.sh
```

`bun run test` additionally exercises the repository's local bootstrap, orchestration, job, helper, and catalog contracts. `bun run test:live` enables read-only SSH regressions against an existing deployment.

## CERN role → repository evidence

| Role signal | Evidence in this repository |
| --- | --- |
| Linux administration | Ubuntu hosts; pinned packages; files, ownership, permissions, firewall state, and systemd services managed explicitly. |
| Scripting / automation | Bounded bootstrap, orchestration, credential handling, submission, and verification scripts with local regression tests. |
| Puppet / OpenVox | Declarative role manifests, local HTCondor module, protected credential handoff, and a clean second apply. |
| Terraform / OpenTofu | OCI lifecycle, exact E2 micro allocation, security-list policy, and native mocked infrastructure tests. |
| Batch systems | Real HTCondor CentralManager + Submit → Execute flow across two Linux machines. |
| Configuration changes | Measured working contract migrated into desired state and proven convergent after rebuild. |
| Testing / validation | OpenTofu, Puppet parser, and ShellCheck gates in CI; local unit/contract/live regressions remain separate. |
| Git discipline | Small evidence-backed commits by mechanism, with secrets/state/generated live data excluded from version control. |

## Limits

This is intentionally a two-node lab: no HA, no autoscaling, no production observability, and no claim of CERN-scale capacity. It uses standalone `puppet apply`, not Foreman, Puppet Server, PuppetDB, or r10k. OpenTofu state is local. Public SSH is used for lab administration and restricted to the configured administrator CIDR. HTCondor scheduler traffic stays on private addresses, and TCP/9618 is not exposed publicly.

The retained Better-T-Stack/Bun workspace is incidental starter code; it was left in place because removing harmless boilerplate does not improve the infrastructure evidence.
