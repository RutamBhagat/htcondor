# htcondor

This project was created with [Better-T-Stack](https://github.com/AmanVarshney01/create-better-t-stack), a modern TypeScript stack.

## Features

- **TypeScript** - For type safety and improved developer experience

## Getting Started

First, install the dependencies:

```bash
bun install
```

Then, run the development server:

```bash
bun run dev
```

## Environment Configuration

Each app owns its environment schema in `.env.schema`. Varlock generates `src/env.ts` during installation; run `bun run env:generate` after changing a schema. Commit schemas, and keep secrets in ignored env files or your deployment platform.

Import the generated `ENV` accessor in application code. Shared database and auth packages receive configuration or initialized clients from the application. See [Varlock's monorepo guide](https://varlock.dev/guides/monorepos/).

Bun's automatic env loading is disabled in `bunfig.toml`; the framework integration or server bootstrap loads Varlock. Node deployments must include Varlock and its dependencies alongside the app schema.

Run standalone Node/Bun tools that use Varlock from the owning app directory so they load that app's schema and env files. `env:generate` only generates TypeScript files; it does not initialize environment values in a subsequent command.

## Project Structure

```
htcondor/
├── apps/
```

## Available Scripts

- `bun run dev`: Start all applications in development mode
- `bun run build`: Build all applications
- `bun run check-types`: Check TypeScript types across all apps
- `bun run test`: Run local bootstrap regressions; live SSH tests are skipped
- `bun run test:live`: Also run read-only checks against both provisioned HTCondor hosts

## HTCondor bootstrap checks

The first-install entry point is `scripts/bootstrap-node.sh`; copy it together with
`scripts/lib/bootstrap-checks.sh`, preserving their relative paths. Run as root with
`controller|worker CM_PRIVATE_IP OWN_PRIVATE_IP PEER_PRIVATE_IP`, and supply the
pool password on stdin, never as an argument. It refuses an existing installation.
No Python runtime is required by the bootstrap or its tests.

Tests use Bun/TypeScript locally and Bash on the hosts. Live checks require OpenTofu
outputs in `infra/`, SSH access, and noninteractive sudo. Defaults are
`~/.ssh/oci-eu-frankfurt` and `.temp/known_hosts`; override with `HTCONDOR_SSH_KEY`
and `HTCONDOR_KNOWN_HOSTS`. Strict host-key checking remains enabled. Checks read
credential metadata only, not secret contents, and make no host configuration changes.
They verify registration, not successful job execution.
