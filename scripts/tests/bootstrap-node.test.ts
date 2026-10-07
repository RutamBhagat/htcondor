import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(new URL("../bootstrap-node.sh", import.meta.url));
const guards = fileURLToPath(new URL("../lib/bootstrap-checks.sh", import.meta.url));

function rejected(args: string[], password = "") {
  const result = spawnSync("bash", [script, ...args], {
    input: password, encoding: "utf8", timeout: 5_000,
  });
  expect(result.error).toBeUndefined();
  expect(result.status).not.toBe(0);
  if (password.trim()) expect(result.stdout + result.stderr).not.toContain(password.trim());
  return result.stderr;
}

function guard(name: string, ...args: string[]) {
  const result = spawnSync("bash", ["-c", 'set -euo pipefail; source "$1"; "$2" "${@:3}"',
    "check", guards, name, ...args], { encoding: "utf8", timeout: 5_000 });
  expect(result.error).toBeUndefined();
  expect(result.stdout + result.stderr).toBe("");
  return result.status === 0;
}

describe("bootstrap input guards", () => {
  test("all shell scripts parse", () => {
    for (const path of [script, guards, fileURLToPath(new URL("./probe-bootstrap.sh", import.meta.url))]) {
      const result = spawnSync("bash", ["-n", path], { encoding: "utf8", timeout: 5_000 });
      expect(result.error).toBeUndefined();
      expect(result.status).toBe(0);
      expect(result.stderr).toBe("");
    }
  });

  test("missing arguments and unknown role", () => {
    expect(rejected([])).toContain("Usage:");
    expect(rejected(["minicondor", "10.0.0.1", "10.0.0.1", "10.0.0.2"])).toContain("Usage:");
  });

  test("invalid addresses", () => {
    for (const address of ["127.0.0.1", "0.0.0.0", "8.8.8.8", "::1", "10.0.0.1;touch /tmp/unsafe"]) {
      expect(rejected(["controller", address, address, "10.0.0.2"])).toContain("private");
    }
  });

  test("wrong topology", () => {
    for (const args of [
      ["controller", "10.0.0.1", "10.0.0.2", "10.0.0.1"],
      ["worker", "10.0.0.1", "10.0.0.2", "10.0.0.3"],
      ["controller", "10.0.0.1", "10.0.0.1", "10.0.0.1"],
    ]) expect(rejected(args)).toContain("topology");
  });

  test("missing, malformed and unterminated passwords", () => {
    for (const password of ["", "secret\n", "a".repeat(64), "a".repeat(63) + "\n"]) {
      expect(rejected(["controller", "10.0.0.1", "10.0.0.1", "10.0.0.2"], password)).toContain("password on stdin");
    }
  });

  test("private address classification preserves the measured Python baseline", () => {
    const accepted = ["0.0.0.1", "0.255.255.255", "10.0.0.1", "10.255.255.255", "169.254.0.1",
      "172.16.0.0", "172.31.255.255", "192.0.0.8", "192.0.0.11", "192.0.0.255", "192.0.2.1",
      "192.168.0.1", "198.18.0.0", "198.19.255.255", "198.51.100.1", "203.0.113.1",
      "240.0.0.0", "255.255.255.255"];
    const rejected = ["0.0.0.0", "1.0.0.0", "11.0.0.0", "127.0.0.1", "169.253.255.255", "169.255.0.0",
      "172.15.255.255", "172.32.0.0", "192.0.0.9", "192.0.0.10", "192.0.1.0", "192.0.3.0",
      "192.169.0.0", "198.17.255.255", "198.20.0.0", "198.51.101.0", "203.0.114.0",
      "239.255.255.255", "100.64.0.1", "8.8.8.8", "10.00.0.1", "10.0.0.256", "::1",
      "10.0.0.1\n", "10.0.0.1;touch /tmp/unsafe", ""];
    for (const address of accepted) expect(guard("valid_pool_ipv4", address)).toBe(true);
    for (const address of rejected) expect(guard("valid_pool_ipv4", address)).toBe(false);
  });

  test("daemon sets tolerate ordering, separators, duplicates and optional SharedPort", () => {
    for (const list of ["MASTER COLLECTOR NEGOTIATOR SCHEDD", "SCHEDD,SHARED_PORT,MASTER,NEGOTIATOR,COLLECTOR",
      "MASTER\tCOLLECTOR\nNEGOTIATOR\rSCHEDD MASTER"]) {
      expect(guard("valid_daemon_roles", "controller", list)).toBe(true);
    }
    for (const list of ["MASTER STARTD", "STARTD,MASTER,SHARED_PORT", "MASTER STARTD STARTD"]) {
      expect(guard("valid_daemon_roles", "worker", list)).toBe(true);
    }
    for (const [role, list] of [["controller", "MASTER COLLECTOR NEGOTIATOR"],
      ["controller", "MASTER COLLECTOR NEGOTIATOR SCHEDD STARTD"], ["worker", "MASTER"],
      ["worker", "MASTER STARTD SCHEDD"], ["worker", "master startd"], ["worker", ""],
      ["unknown", "MASTER STARTD"]]) {
      expect(guard("valid_daemon_roles", role!, list!)).toBe(false);
    }
  });
});
