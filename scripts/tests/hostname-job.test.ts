import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, copyFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const executable = new URL("../../jobs/hostname.sh", import.meta.url);
const submit = new URL("../../jobs/hostname.submit", import.meta.url);

test("hostname payload runs from an isolated scratch directory without repository files", () => {
  const scratch = mkdtempSync(join(tmpdir(), "htcondor-hostname-"));
  try {
    const payload = join(scratch, "hostname.sh");
    expect(statSync(executable).mode & 0o111).toBe(0o111);
    copyFileSync(executable, payload);
    const result = spawnSync(payload, [], {
      cwd: scratch, encoding: "utf8", timeout: 5_000,
      env: { PATH: "/usr/bin:/bin", LC_ALL: "C" },
    });
    expect(result.error).toBeUndefined();
    expect(result.status).toBe(0);
    expect(result.stderr).toBe("");
    const lines = result.stdout.trim().split("\n");
    expect(lines).toHaveLength(3);
    for (const [index, args] of [["hostname"], ["uname", "-m"]].entries()) {
      expect(lines[index]).toBe(spawnSync(args[0]!, args.slice(1), { encoding: "utf8" }).stdout.trim());
    }
    expect(lines[2]).toMatch(/ UTC \d{4}$/);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});

test("submit transfers one small Linux script and returns uniquely named output", () => {
  const text = readFileSync(submit, "utf8");
  const entries = Object.fromEntries(text.split("\n")
    .filter((line) => line.includes("=") && !line.trimStart().startsWith("#"))
    .map((line) => { const i = line.indexOf("="); return [line.slice(0, i).trim(), line.slice(i + 1).trim()]; }));
  expect(entries.universe).toBe("vanilla");
  expect(entries.executable).toBe("jobs/hostname.sh");
  expect(entries.should_transfer_files).toBe("YES");
  expect(entries.transfer_executable).toBe("True");
  expect(entries.when_to_transfer_output).toBe("ON_EXIT");
  expect(entries.requirements).toBe('(TARGET.OpSys == "LINUX") && (TARGET.Arch =!= UNDEFINED)');
  expect(entries.request_cpus).toBe("1");
  expect(entries.request_memory).toBe("32MB");
  expect(entries.request_disk).toBe("1MB");
  for (const [key, extension] of [["output", "out"], ["error", "err"], ["log", "log"]]) {
    expect(entries[key!]).toBe(`jobs/results/hostname.$(ClusterId).$(ProcId).${extension}`);
  }
  expect(text.match(/^queue\s+1$/gm)).toHaveLength(1);
});
