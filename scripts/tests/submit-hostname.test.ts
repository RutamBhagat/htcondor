import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(new URL("../submit-hostname.sh", import.meta.url));
function probe(mode: string, wait = "90") {
  const scratch = mkdtempSync(join(tmpdir(), "condor-submit-test-"));
  try {
    mkdirSync(join(scratch, "bin"));
    const commands: Record<string, string> = {
      condor_submit: 'printf "%s\\n" "$*" >> calls; echo "42.0 - 42.0"',
      condor_q: 'printf "%s\\n" "$*" >> calls',
      condor_wait: `printf '%s\n' "$*" >> calls
mkdir -p jobs/results
case "$MODE" in
  timeout) exit 1 ;;
  abort) echo '009 (042.000.000) Job was aborted.' > jobs/results/hostname.42.0.log ;;
  failed) echo '    (1) Normal termination (return value 7)' > jobs/results/hostname.42.0.log ;;
  success) printf '005 (042.000.000) Job terminated.\n    (1) Normal termination (return value 0)\n' > jobs/results/hostname.42.0.log ;;
esac`,
    };
    for (const [name, body] of Object.entries(commands)) {
      const path = join(scratch, "bin", name);
      writeFileSync(path, "#!/bin/sh\nset -eu\n" + body + "\n");
      chmodSync(path, 0o755);
    }
    const result = spawnSync("bash", [script, wait], {
      cwd: scratch, encoding: "utf8", timeout: 5_000,
      env: { ...process.env, MODE: mode, PATH: join(scratch, "bin") + ":/usr/bin:/bin" },
    });
    const calls = join(scratch, "calls");
    const trace = existsSync(calls) ? readFileSync(calls, "utf8") : "";
    expect(result.error).toBeUndefined();
    return { ...result, trace };
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

test("submits one job, inspects its queue entry, and waits for its event log with a bound", () => {
  const result = probe("success");
  expect(result.status).toBe(0);
  expect(result.trace.trim().split("\n")).toEqual([
    "-terse jobs/hostname.submit", "42.0", "-wait 90 jobs/results/hostname.42.0.log 42.0",
  ]);
  expect(result.stdout).toContain("Completed 42.0 successfully");
});

for (const mode of ["timeout", "abort", "failed"]) {
  test(`does not confuse ${mode} with successful completion`, () => {
    expect(probe(mode).status).not.toBe(0);
  });
}

test("rejects invalid bounds before submitting", () => {
  for (const bound of ["0", "-1", "forever", "1.5"]) {
    const result = probe("success", bound);
    expect(result.status).not.toBe(0);
    expect(result.trace).toBe("");
  }
});
