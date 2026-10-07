#!/usr/bin/env python3
"""Measure a Linux command without a daemon; global headroom samples + child RSS."""
import csv
import json
from pathlib import Path
import resource
import subprocess
import sys
import time


def parse_meminfo(text):
    values = {}
    for line in text.splitlines():
        key, value = line.split(":", 1)
        if key in ("MemTotal", "MemAvailable", "SwapTotal", "SwapFree"):
            fields = value.split()
            if len(fields) != 2 or fields[1] != "kB":
                raise ValueError("Expected /proc/meminfo KiB units")
            values[key] = int(fields[0])
    if set(values) != {"MemTotal", "MemAvailable", "SwapTotal", "SwapFree"}:
        raise ValueError("Missing memory metrics")
    return values


def summarize(samples):
    if not samples:
        raise ValueError("No samples")
    return {
        "samples": len(samples),
        "mem_total_kib": samples[0]["MemTotal"],
        "baseline_available_kib": samples[0]["MemAvailable"],
        "minimum_available_kib": min(s["MemAvailable"] for s in samples),
        "peak_unavailable_kib": max(s["MemTotal"] - s["MemAvailable"] for s in samples),
        "maximum_swap_used_kib": max(s["SwapTotal"] - s["SwapFree"] for s in samples),
    }


def measure(directory, command, interval=0.25):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=False)
    samples = []
    started = time.monotonic()
    with (directory / "samples.csv").open("w") as output:
        writer = csv.writer(output)
        writer.writerow(["elapsed_seconds", "MemTotalKiB", "MemAvailableKiB", "SwapTotalKiB", "SwapFreeKiB"])

        def sample():
            info = parse_meminfo(Path("/proc/meminfo").read_text())
            samples.append(info)
            writer.writerow([round(time.monotonic() - started, 6), info["MemTotal"], info["MemAvailable"], info["SwapTotal"], info["SwapFree"]])
            output.flush()

        sample()  # Baseline before launching the command.
        process = subprocess.Popen(command)
        while True:
            try:
                status = process.wait(timeout=interval)
                break
            except subprocess.TimeoutExpired:
                sample()
        sample()  # Include terminal state, even for very short or failed commands.
    summary = summarize(samples)
    summary.update({
        "command": command, "exit_code": status, "elapsed_seconds": round(time.monotonic() - started, 6),
        "sampling_interval_seconds": interval,
        "kernel_child_maxrss_kib": resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss,
    })
    (directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2), flush=True)
    return status


if __name__ == "__main__":
    if len(sys.argv) < 4 or sys.argv[2] != "--":
        sys.exit("Usage: measure-memory.py <new-output-directory> -- <command> [args...]")
    sys.exit(measure(sys.argv[1], sys.argv[3:]))
