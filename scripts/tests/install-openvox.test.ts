import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(new URL("../install-openvox.sh", import.meta.url));
test("installer parses as Bash", () => {
  expect(spawnSync("bash", ["-n", script]).status).toBe(0);
});

test("invalid options fail before any host operations", () => {
  for (const args of [["--force"], ["--check", "extra"]]) {
    const result = spawnSync("bash", [script, ...args], { encoding: "utf8", timeout: 5000 });
    expect(result.status).toBe(2);
    expect(result.stderr).toContain("Usage:");
    expect(result.stdout).toBe("");
  }
});

test("non-root invocation fails before reading OS or changing packages", () => {
  const scratch = mkdtempSync(join(tmpdir(), "openvox-guard-"));
  try {
    const id = join(scratch, "id");
    writeFileSync(id, "#!/bin/sh\nprintf '1000\\n'\n");
    chmodSync(id, 0o755);
    const result = spawnSync("bash", [script, "--check"], {
      encoding: "utf8", timeout: 5000, env: { ...process.env, PATH: scratch + ":/usr/bin:/bin" },
    });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("Run as root.");
    expect(result.stdout).toBe("");
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});

test("real installation waits for cloud-init before touching dpkg", () => {
  const text = require("node:fs").readFileSync(script, "utf8");
  const checkExit = text.indexOf("[[ ${1:-} != --check ]] || exit 0");
  const wait = text.indexOf("timeout 180s cloud-init status --wait");
  const dpkgInstall = text.indexOf('dpkg -i "$scratch/release.deb"');
  expect(checkExit).toBeGreaterThanOrEqual(0);
  expect(wait).toBeGreaterThan(checkExit);
  expect(dpkgInstall).toBeGreaterThan(wait);
});
