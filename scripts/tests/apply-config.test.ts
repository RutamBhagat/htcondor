import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dir, "../..");
const script = join(root, "scripts/apply-config.sh");
let scratch = "";

function executable(path: string, body: string) {
  writeFileSync(path, body);
  chmodSync(path, 0o755);
}

beforeEach(() => {
  scratch = mkdtempSync(join(tmpdir(), "apply-config-test-"));
  mkdirSync(join(scratch, "bin"));
  writeFileSync(join(scratch, "key"), "fixture-key\n");
  writeFileSync(join(scratch, "known_hosts"), "fixture-host-key\n");
  writeFileSync(join(scratch, "credential"), "a".repeat(64) + "\n");
  chmodSync(join(scratch, "credential"), 0o600);

  executable(join(scratch, "bin/tofu"), `#!/usr/bin/env bash
set -eu
name=\${!#}
case "$name" in
  node_public_ips)
    if [[ -n \${FAKE_PUBLIC_JSON+x} ]]; then
      printf '%s\\n' "$FAKE_PUBLIC_JSON"
    else
      printf '%s\\n' '{"controller":"198.51.100.10","worker":"203.0.113.20"}'
    fi
    ;;
  node_private_ips)
    if [[ -n \${FAKE_PRIVATE_JSON+x} ]]; then
      printf '%s\\n' "$FAKE_PRIVATE_JSON"
    else
      printf '%s\\n' '{"controller":"10.0.0.10","worker":"10.0.0.20"}'
    fi
    ;;
  *)
    echo "unexpected tofu output: $*" >&2
    exit 64
    ;;
esac
`);

  executable(join(scratch, "bin/ssh"), `#!/usr/bin/env bash
set -eu
log=$FAKE_LOG
dest=\${@: -2:1}
command=\${@: -1}
printf 'SSH %s %s\\n' "$dest" "$command" >> "$log"
case "$command" in
  *"mktemp -d /tmp/htcondor-puppet.XXXXXX"*)
    case "$dest" in
      *198.51.100.10) echo /tmp/htcondor-puppet.C0A001 ;;
      *203.0.113.20) echo /tmp/htcondor-puppet.W0B002 ;;
      *) exit 65 ;;
    esac
    ;;
  *"tar -xf - -C "*)
    /usr/bin/tar -tf - | while IFS= read -r item; do
      printf 'ARCHIVE %s %s\\n' "$dest" "$item" >> "$log"
    done
    ;;
  *"/opt/puppetlabs/bin/puppet --version"*)
    case "$dest" in
      *198.51.100.10) exit "\${FAKE_CONTROLLER_OPENVOX_STATUS:-0}" ;;
      *203.0.113.20) exit "\${FAKE_WORKER_OPENVOX_STATUS:-0}" ;;
      *) exit 65 ;;
    esac
    ;;
  *"sudo -n bash scripts/install-openvox.sh"*)
    printf 'INSTALL %s\\n' "$dest" >> "$log"
    case "$dest" in
      *198.51.100.10) exit "\${FAKE_CONTROLLER_INSTALL_STATUS:-0}" ;;
      *203.0.113.20) exit "\${FAKE_WORKER_INSTALL_STATUS:-0}" ;;
      *) exit 65 ;;
    esac
    ;;
  *"with-pool-credential.py -- "*)
    bytes=$(cat | wc -c | tr -d ' ')
    printf 'CREDENTIAL_BYTES %s %s\\n' "$dest" "$bytes" >> "$log"
    case "$command" in
      *controller.pp*) exit "\${FAKE_CONTROLLER_STATUS:-0}" ;;
      *worker.pp*) exit "\${FAKE_WORKER_STATUS:-0}" ;;
      *) exit 66 ;;
    esac
    ;;
  *"rm -rf -- /tmp/htcondor-puppet."*)
    printf 'CLEANUP %s\\n' "$dest" >> "$log"
    ;;
  *)
    echo "unexpected ssh command: $command" >&2
    exit 67
    ;;
esac
`);
});

afterEach(() => rmSync(scratch, { recursive: true, force: true }));

function run(extra: Record<string, string> = {}) {
  const log = join(scratch, "calls.log");
  const result = spawnSync("bash", [script], {
    cwd: root,
    encoding: "utf8",
    env: {
      ...process.env,
      PATH: join(scratch, "bin") + ":" + process.env.PATH,
      HTCONDOR_SSH_KEY: join(scratch, "key"),
      HTCONDOR_KNOWN_HOSTS: join(scratch, "known_hosts"),
      HTCONDOR_POOL_CREDENTIAL: join(scratch, "credential"),
      FAKE_LOG: log,
      ...extra,
    },
  });
  return { result, log: (() => { try { return readFileSync(log, "utf8"); } catch { return ""; } })() };
}

describe("apply-config orchestration", () => {
  test("reads tofu outputs, stages only required role code, and applies both topology roles", () => {
    const { result, log } = run({ FAKE_CONTROLLER_STATUS: "2", FAKE_WORKER_STATUS: "0" });
    expect([result.status, result.stderr]).toEqual([0, ""]);
    expect(result.stdout).toContain("controller: applied changes");
    expect(result.stdout).toContain("worker: already converged");

    const controllerArchive = log.split("\n").filter((line) => line.startsWith("ARCHIVE ubuntu@198.51.100.10 "));
    const workerArchive = log.split("\n").filter((line) => line.startsWith("ARCHIVE ubuntu@203.0.113.20 "));
    const common = [
      "puppet/modules/htcondor/manifests/init.pp",
      "puppet/modules/htcondor/templates/role.epp",
      "puppet/modules/htcondor/templates/private-network.epp",
      "puppet/modules/htcondor/files/htcondor.asc",
      "puppet/modules/htcondor/files/credentials.sh",
      "puppet/modules/htcondor/files/firewall.sh",
      "scripts/install-openvox.sh",
      "scripts/with-pool-credential.py",
    ];
    expect(controllerArchive.map((line) => line.replace(/^ARCHIVE ubuntu@198\.51\.100\.10 /, "")).sort())
      .toEqual(["puppet/manifests/controller.pp", ...common].sort());
    expect(workerArchive.map((line) => line.replace(/^ARCHIVE ubuntu@203\.0\.113\.20 /, "")).sort())
      .toEqual(["puppet/manifests/worker.pp", ...common].sort());

    expect(log).toContain("FACTER_htcondor_cm=10.0.0.10 FACTER_htcondor_own=10.0.0.10 FACTER_htcondor_peer=10.0.0.20");
    expect(log).toContain("FACTER_htcondor_cm=10.0.0.10 FACTER_htcondor_own=10.0.0.20 FACTER_htcondor_peer=10.0.0.10");
    expect(log).toContain("--detailed-exitcodes --summarize");
    expect(log).toContain("CREDENTIAL_BYTES ubuntu@198.51.100.10 65");
    expect(log).toContain("CREDENTIAL_BYTES ubuntu@203.0.113.20 65");
    expect(log).not.toContain("INSTALL ");
    expect(log).not.toContain("BASELINE.md");
    expect(log).not.toContain("README.md");
  });

  test("installs the pinned OpenVox agent on a fresh host before applying Puppet", () => {
    const { result, log } = run({ FAKE_CONTROLLER_OPENVOX_STATUS: "3", FAKE_WORKER_OPENVOX_STATUS: "3" });
    expect(result.status).toBe(0);
    expect(log).toContain("INSTALL ubuntu@198.51.100.10");
    expect(log).toContain("INSTALL ubuntu@203.0.113.20");
    expect(log.indexOf("INSTALL ubuntu@198.51.100.10")).toBeLessThan(log.indexOf("CREDENTIAL_BYTES ubuntu@198.51.100.10"));
    expect(log.indexOf("INSTALL ubuntu@203.0.113.20")).toBeLessThan(log.indexOf("CREDENTIAL_BYTES ubuntu@203.0.113.20"));
  });

  test("rejects an unexpected OpenVox state instead of installing over it", () => {
    const { result, log } = run({ FAKE_CONTROLLER_OPENVOX_STATUS: "4" });
    expect(result.status).toBe(4);
    expect(result.stderr).toContain("controller: unexpected OpenVox state (4)");
    expect(log).not.toContain("INSTALL ubuntu@198.51.100.10");
    expect(log).toContain("CLEANUP ubuntu@198.51.100.10");
  });

  test("propagates a Puppet failure and still removes both remote staging directories", () => {
    const { result, log } = run({ FAKE_CONTROLLER_STATUS: "0", FAKE_WORKER_STATUS: "6" });
    expect(result.status).toBe(6);
    expect(result.stderr).toContain("worker: puppet apply failed (6)");
    expect(log).toContain("CLEANUP ubuntu@198.51.100.10");
    expect(log).toContain("CLEANUP ubuntu@203.0.113.20");
  });

  test("rejects incomplete OpenTofu topology before connecting to a host", () => {
    const { result, log } = run({ FAKE_PUBLIC_JSON: '{"controller":"198.51.100.10"}' });
    expect(result.status).not.toBe(0);
    expect(log).toBe("");
  });
});
