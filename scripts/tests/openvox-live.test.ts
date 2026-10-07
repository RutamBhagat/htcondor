// Opt-in, read-only agent-installation regression. Does not apply a catalog.
import { beforeAll, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { homedir } from "node:os";
import { resolve } from "node:path";

const live = process.env.HTCONDOR_LIVE_TEST === "1" ? describe : describe.skip;
live("live standalone OpenVox", () => {
  let nodes: Record<string, string>;
  beforeAll(() => {
    const outputs = JSON.parse(execFileSync("tofu", ["-chdir=infra", "output", "-json"], { encoding: "utf8", timeout: 15000 }));
    nodes = outputs.node_public_ips.value;
  });
  for (const role of ["controller", "worker"]) {
    test(`${role} has pinned agent CLI without a polling daemon or server`, () => {
      const command = `set -eu
hostname
/opt/puppetlabs/bin/puppet --version
version=$(dpkg-query -W -f='\${Version}' openvox-agent)
test "$version" = '9.0.0-1+ubuntu24.04'
enabled=$(systemctl is-enabled puppet.service || true)
test "$enabled" = masked
if systemctl is-active --quiet puppet.service; then exit 1; fi
for package in openvox-server puppetserver; do
  status=$(dpkg-query -W -f='\${db:Status-Status}' "$package" 2>/dev/null || true)
  test "$status" != installed
done
test -z "$(ss -H -ltn '( sport = :8140 )')"
printf '%s\\n' "$enabled"`;
      const output = execFileSync("ssh", [
        "-i", process.env.HTCONDOR_SSH_KEY ?? resolve(homedir(), ".ssh/oci-eu-frankfurt"),
        "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
        "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=" + (process.env.HTCONDOR_KNOWN_HOSTS ?? resolve(".temp/known_hosts")),
        `ubuntu@${nodes[role]}`, command,
      ], { encoding: "utf8", timeout: 30000 });
      expect(output.trim().split("\n")).toEqual([role, "9.0.0", "masked"]);
    }, 35000);
  }
});
