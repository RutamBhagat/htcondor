# Two-node HTCondor lab on OCI

[![verify](https://github.com/RutamBhagat/htcondor/actions/workflows/verify.yml/badge.svg)](https://github.com/RutamBhagat/htcondor/actions/workflows/verify.yml)

A reproducible two-node [HTCondor](https://htcondor.org/) pool on Oracle Cloud Infrastructure (OCI). OpenTofu provisions the network and compute resources. Standalone OpenVox/Puppet code configures each Ubuntu host.

The lab shows remote batch execution, configuration convergence, repeatable rebuilds, protected credential handling, and private scheduler traffic.

## Architecture

```text
                             OCI VCN
                    +-----------------------+
SSH from admin CIDR |                       |
------------------->| controller            |
                    | CentralManager        |
                    | Submit                |
                    |        |              |
                    |        | TCP/9618     |
                    |        v              |
                    | worker                |
                    | Execute               |
                    |                       |
                    +-----------------------+
```

The controller schedules jobs but does not execute them. The worker executes jobs but does not accept submissions.

| Layer | Responsibility |
| --- | --- |
| OpenTofu | OCI VCN, subnet, routing, security rules, and two E2 micro instances |
| OpenVox/Puppet | HTCondor packages, configuration, credentials, firewall rules, and services |
| systemd | HTCondor service supervision |
| HTCondor | Job scheduling, file transfer, and remote execution |

OCI permits SSH only from the configured administrator CIDR. It permits HTCondor TCP/9618 only inside the VCN. HTCondor also binds to each private node address.

## Verified behavior

| Claim | Result |
| --- | --- |
| Remote execution | A job submitted on `controller` completed on `worker`. The controller has no Execute daemon. |
| Configuration convergence | Both role catalogs own the measured HTCondor state. A second apply reported no managed changes. |
| Reproducible lifecycle | OpenTofu recreated both nodes. Repository automation restored the pool without manual host repair. |
| Restricted scheduler network | Private HTCondor communication succeeded. Public TCP/9618 checks failed as required. |
| Credential-free CI | CI validates OpenTofu, tests the scripts, checks TypeScript and Puppet syntax, and runs ShellCheck without OCI credentials. |

See [the sanitized evidence](evidence/README.md) for the recorded results and test boundaries.

## Prerequisites

- An OCI tenancy with Always Free E2 micro capacity
- An OCI CLI profile with a valid security token
- An Ubuntu 24.04 amd64 image OCID
- [OpenTofu](https://opentofu.org/) 1.10 or later
- [Bun](https://bun.sh/) 1.4.2
- Bash, Python 3, `jq`, `tar`, SSH, and `ssh-keyscan`
- An administrator IPv4 CIDR and an SSH key pair

> [!IMPORTANT]
> This repository creates OCI resources. Review every OpenTofu plan before you apply it.

## Deploy the lab

Run all commands from the repository root.

### 1. Configure OpenTofu

Create `infra/lab.auto.tfvars`. Git ignores all `*.tfvars` files because they can contain account and network data.

```hcl
compartment_id      = "ocid1.compartment.oc1..example"
region              = "eu-frankfurt-1"
oci_config_profile  = "DEFAULT"
availability_domain = "example:EU-FRANKFURT-1-AD-3"
image_id            = "ocid1.image.oc1.eu-frankfurt-1.example"
admin_cidr          = "203.0.113.10/32"
ssh_public_key      = "ssh-ed25519 AAAA..."
```

The image must run Ubuntu 24.04 on amd64. `admin_cidr` cannot be `0.0.0.0/0`.

### 2. Create the pool credential

Generate the 256-bit pool credential locally. The scripts require a lowercase, newline-terminated, 64-character hexadecimal value.

```bash
install -d -m 700 .temp/secrets
umask 077
python3 -c 'import secrets; print(secrets.token_hex(32))' \
  > .temp/secrets/htcondor-pool-password
chmod 600 .temp/secrets/htcondor-pool-password
```

> [!WARNING]
> Keep the credential in the ignored `.temp/` directory. Do not pass it through arguments, environment variables, logs, or OpenTofu state.

### 3. Provision the OCI resources

```bash
tofu -chdir=infra fmt -check -recursive
tofu -chdir=infra init
tofu -chdir=infra validate
tofu -chdir=infra plan -out=lab.tfplan
tofu -chdir=infra show lab.tfplan
tofu -chdir=infra apply lab.tfplan
```

The configuration creates one controller, one worker, and a 50 GB boot volume for each node.

### 4. Record trusted SSH host keys

Collect three matching observations for each new address. Compare the displayed fingerprints with a trusted source before you accept them.

```bash
install -d -m 700 .temp/hostkeys
: > .temp/known_hosts

for role in controller worker; do
  host=$(tofu -chdir=infra output -json node_public_ips \
    | jq -r --arg role "$role" '.[$role]')

  for attempt in 1 2 3; do
    ssh-keyscan -T 10 "$host" 2>/dev/null \
      | sort > ".temp/hostkeys/$role.$attempt"
  done

  cmp ".temp/hostkeys/$role.1" ".temp/hostkeys/$role.2"
  cmp ".temp/hostkeys/$role.1" ".temp/hostkeys/$role.3"
  ssh-keygen -lf ".temp/hostkeys/$role.1"
  cat ".temp/hostkeys/$role.1" >> .temp/known_hosts
done

chmod 600 .temp/known_hosts
```

### 5. Configure both nodes

Set the SSH key path for your OCI instances. The orchestration script installs OpenVox 9.0.0 when needed and applies the correct role catalog.

```bash
export HTCONDOR_SSH_KEY="$HOME/.ssh/oci-eu-frankfurt"
export HTCONDOR_KNOWN_HOSTS="$PWD/.temp/known_hosts"
export HTCONDOR_POOL_CREDENTIAL="$PWD/.temp/secrets/htcondor-pool-password"

scripts/apply-config.sh
scripts/apply-config.sh
```

The first command configures the nodes. The second command must report `already converged` for both roles.

## Submit and verify a job

Stage only the example job and its helpers on the controller.

```bash
controller=$(tofu -chdir=infra output -json node_public_ips \
  | jq -r '.controller')

ssh_opts=(
  -i "$HTCONDOR_SSH_KEY"
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile="$HTCONDOR_KNOWN_HOSTS"
)

tar -cf - jobs scripts/submit-hostname.sh scripts/verify-hostname.sh \
  | ssh "${ssh_opts[@]}" "ubuntu@$controller" \
      'rm -rf ~/htcondor-job && mkdir ~/htcondor-job && tar -xf - -C ~/htcondor-job'

ssh "${ssh_opts[@]}" "ubuntu@$controller" \
  'cd ~/htcondor-job && condor_status && bash scripts/submit-hostname.sh 180'
```

The submission command returns a `cluster.process` identifier. Use it to verify the returned output.

```bash
ssh "${ssh_opts[@]}" "ubuntu@$controller" \
  'cd ~/htcondor-job && bash scripts/verify-hostname.sh <cluster.process> worker controller'
```

The check fails unless the job completed successfully on `worker` and not on `controller`.

## Local validation

These credential-free checks match the main CI path:

```bash
tofu -chdir=infra fmt -check -recursive
tofu -chdir=infra init -backend=false -input=false
tofu -chdir=infra validate
tofu -chdir=infra test

bun install --frozen-lockfile
bun run test
bunx --no-install tsc --noEmit

/opt/puppetlabs/bin/puppet parser validate \
  puppet/manifests/*.pp puppet/modules/htcondor/manifests/*.pp
shellcheck scripts/*.sh
```

The Puppet parser and ShellCheck steps require the tools installed by the [CI workflow](.github/workflows/verify.yml). On a supported host with OpenVox installed, run the catalog contract check separately:

```bash
python3 scripts/tests/check-puppet-catalogs.py
```

Run `bun run test:live` for read-only SSH regressions against an existing deployment. Live tests use the same `HTCONDOR_SSH_KEY` and `HTCONDOR_KNOWN_HOSTS` values. CI excludes them.

## Repository layout

| Path | Purpose |
| --- | --- |
| `infra/` | OCI resources, input contracts, outputs, and mocked OpenTofu tests |
| `puppet/` | OpenVox/Puppet role manifests, the local HTCondor module, and migration baseline |
| `scripts/` | Installation, orchestration, credential, submission, verification, and test helpers |
| `jobs/` | Architecture-independent hostname job with file transfer enabled |
| `evidence/` | Sanitized outcomes from remote execution, convergence, rebuild, and network checks |

Raw plans, state, addresses, host keys, credentials, and transient logs remain ignored under `.temp/`.

## Scope

This repository is a two-node lab. It does not include high availability, autoscaling, production observability, or CERN-scale capacity.

OpenVox runs through standalone `puppet apply`. The lab does not use Puppet Server, PuppetDB, Foreman, or r10k. OpenTofu state remains local. Public addresses exist only for restricted SSH administration. HTCondor traffic uses private addresses.
