// Opt-in read-only SSH regressions; never read or transmit the pool password.
import { beforeAll, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { createConnection } from "node:net";
import { homedir } from "node:os";
import { basename, resolve } from "node:path";
import { fileURLToPath } from "node:url";

type Role = "controller" | "worker";
type Nodes = Record<Role, string>;
const root = fileURLToPath(new URL("../../", import.meta.url));
const probe = readFileSync(new URL("../lib/bootstrap-checks.sh", import.meta.url), "utf8") + "\n" +
  readFileSync(new URL("./probe-bootstrap.sh", import.meta.url), "utf8");

function run(command: string, args: string[], input?: string, timeout = 30_000) {
  const result = spawnSync(command, args, { cwd: root, input, encoding: "utf8", timeout });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} failed (${result.status}): ${result.stderr}`);
  return result.stdout;
}

function portReachable(host: string): Promise<boolean> {
  return new Promise((resolve, reject) => {
    const socket = createConnection({ host, port: 9618 });
    socket.setTimeout(5_000);
    socket.once("connect", () => { socket.destroy(); resolve(true); });
    socket.once("timeout", () => { socket.destroy(); resolve(false); });
    socket.once("error", (error: NodeJS.ErrnoException) => {
      socket.destroy();
      if (["ECONNREFUSED", "EHOSTUNREACH", "ENETUNREACH", "ETIMEDOUT"].includes(error.code ?? "")) resolve(false);
      else reject(error);
    });
  });
}

describe.skipIf(process.env.HTCONDOR_LIVE_TEST !== "1")("live bootstrap", () => {
  let publicIPs: Nodes;
  let privateIPs: Nodes;
  let ssh: string[];

  beforeAll(() => {
    const outputs = JSON.parse(run("tofu", ["-chdir=infra", "output", "-json"]));
    publicIPs = outputs.node_public_ips.value;
    privateIPs = outputs.node_private_ips.value;
    ssh = ["-i", process.env.HTCONDOR_SSH_KEY ?? resolve(homedir(), ".ssh/oci-eu-frankfurt"),
      "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
      "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=" +
      (process.env.HTCONDOR_KNOWN_HOSTS ?? resolve(root, ".temp/known_hosts"))];
  }, 15_000);

  for (const role of ["controller", "worker"] as const) {
    test(`${role} has the expected roles, private listener and protected credentials`, async () => {
      const rows = run("ssh", [...ssh, `ubuntu@${publicIPs[role]}`, `sudo -n bash -s -- ${role}`], probe)
        .trim().split("\n").map((line) => line.split("\t"));
      const config = Object.fromEntries(rows.filter(([kind]) => kind === "CONFIG").map(([, key, value]) => [key!, value!]));
      const services = Object.fromEntries(rows.filter(([kind]) => kind === "SERVICE").map(([, key, value]) => [key!, value!]));
      const expected = role === "controller" ? ["MASTER", "COLLECTOR", "NEGOTIATOR", "SCHEDD"] : ["MASTER", "STARTD"];
      expect(new Set(config.DAEMON_LIST!.split(/[,\s]+/).filter((name) => name && name !== "SHARED_PORT")))
        .toEqual(new Set(expected));
      expect(new Set(rows.filter(([kind]) => kind === "PROCESS").map(([, name]) => basename(name!))))
        .toEqual(new Set([...expected.map((name) => "condor_" + name.toLowerCase()), "condor_shared_port"]));
      expect(config.CONDOR_HOST).toBe(privateIPs.controller);
      expect(config.NETWORK_INTERFACE).toBe(privateIPs[role]);
      expect(config.BIND_ALL_INTERFACES!.toLowerCase()).toBe("false");
      expect(services).toEqual({ active: "active", enabled: "enabled" });
      expect(new Set(rows.filter(([kind]) => kind === "LISTENER").map(([, address]) => address)))
        .toEqual(new Set([privateIPs[role] + ":9618"]));
      const credentials = rows.filter(([kind]) => kind === "CREDENTIAL");
      expect(credentials.filter(([, type]) => type === "directory")).toHaveLength(2);
      expect(credentials.filter(([, type]) => type === "file").length).toBeGreaterThanOrEqual(2);
      for (const [, type, metadata] of credentials) expect(metadata).toBe(type === "directory" ? "700:0" : "600:0");
      expect(await portReachable(publicIPs[role])).toBe(false);
    }, 45_000);
  }

  test("only the worker registers Execute ads", () => {
    const ads: { Machine: string }[] = JSON.parse(run("ssh", [...ssh,
      `ubuntu@${publicIPs.controller}`, "timeout 30s condor_status -json"], undefined, 40_000));
    expect(new Set(ads.map((ad) => ad.Machine))).toEqual(new Set(["worker"]));
  }, 45_000);
});
