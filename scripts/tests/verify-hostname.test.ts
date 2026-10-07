import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(new URL("../verify-hostname.sh", import.meta.url));
const terminated = "005 (042.000.000) Job terminated.\n    (1) Normal termination (return value 0)\n";
function probe(options: { host?: string; log?: string; missingOutput?: boolean; args?: string[] } = {}) {
  const scratch = mkdtempSync(join(tmpdir(), "condor-verify-test-"));
  try {
    const prefix = join(scratch, "jobs/results/hostname.42.0");
    mkdirSync(join(scratch, "jobs/results"), { recursive: true });
    if (!options.missingOutput) writeFileSync(prefix + ".out", `${options.host ?? "worker"}\nx86_64\nWed Oct  7 12:19:12 UTC 2026\n`);
    writeFileSync(prefix + ".log", options.log ?? terminated);
    const result = spawnSync("bash", [script, ...(options.args ?? ["42.0", "worker", "controller"])], {
      cwd: scratch, encoding: "utf8", timeout: 5_000,
    });
    expect(result.error).toBeUndefined();
    return result;
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

test("accepts completed worker output without querying or submitting jobs", () => {
  const result = probe();
  expect(result.status).toBe(0);
  expect(result.stdout).toContain("Verified 42.0 executed on worker, not controller");
});

test("rejects controller execution even when controller was supplied as expected worker", () => {
  expect(probe({ host: "controller" }).status).not.toBe(0);
  expect(probe({ host: "controller", args: ["42.0", "controller", "controller"] }).status).not.toBe(0);
});

test("rejects other hosts and substring matches", () => {
  for (const host of ["other", "worker-2", "", " worker"]) expect(probe({ host }).status).not.toBe(0);
});

test("rejects missing returned output", () => {
  expect(probe({ missingOutput: true }).status).not.toBe(0);
});

test("rejects incomplete, aborted, and failed jobs even with worker stdout", () => {
  for (const log of ["", "009 Job aborted.\n", terminated.replace("return value 0", "return value 7")]) {
    expect(probe({ log }).status).not.toBe(0);
  }
});

test("rejects malformed IDs and missing host identities", () => {
  for (const args of [["../42.0", "worker", "controller"], ["42", "worker", "controller"], ["42.0"], ["42.0", "", "controller"]]) {
    expect(probe({ args }).status).not.toBe(0);
  }
});
