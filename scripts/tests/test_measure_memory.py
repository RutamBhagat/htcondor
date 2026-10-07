from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("measure_memory", Path(__file__).parents[1] / "lib/measure-memory.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class MemoryTests(unittest.TestCase):
    def test_realistic_meminfo_and_zero_swap(self):
        info = module.parse_meminfo("MemTotal: 1000 kB\nMemAvailable: 400 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\nOther: 3 kB\n")
        self.assertEqual(info, dict(MemTotal=1000, MemAvailable=400, SwapTotal=0, SwapFree=0))

    def test_missing_or_wrong_units_fail_instead_of_fabricating_zero(self):
        for text in ["MemTotal: 1000 kB\n", "MemTotal: 1000 MB\n", "MemTotal: nonsense kB\n"]:
            with self.assertRaises(ValueError):
                module.parse_meminfo(text)

    def test_peak_is_not_final_memory_and_swap_is_measured(self):
        samples = [dict(MemTotal=1000, MemAvailable=available, SwapTotal=100, SwapFree=swap)
                   for available, swap in [(600, 100), (100, 50), (550, 100)]]
        result = module.summarize(samples)
        self.assertEqual(result["minimum_available_kib"], 100)
        self.assertEqual(result["peak_unavailable_kib"], 900)
        self.assertEqual(result["maximum_swap_used_kib"], 50)

    def test_empty_samples_are_an_error(self):
        with self.assertRaises(ValueError):
            module.summarize([])

    def test_command_failure_is_preserved_and_gets_baseline_and_terminal_samples(self):
        info = "MemTotal: 1000 kB\nMemAvailable: 400 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n"
        real_read = Path.read_text
        def read(path, *args, **kwargs):
            return info if str(path) == "/proc/meminfo" else real_read(path, *args, **kwargs)
        with tempfile.TemporaryDirectory() as scratch, patch.object(Path, "read_text", read), redirect_stdout(io.StringIO()):
            directory = Path(scratch) / "measurement"
            self.assertEqual(module.measure(directory, ["/bin/sh", "-c", "exit 7"]), 7)
            self.assertTrue((directory / "samples.csv").exists())
            self.assertIn('"exit_code": 7', (directory / "summary.json").read_text())
            self.assertGreaterEqual(json.loads((directory / "summary.json").read_text())["samples"], 2)

    def test_existing_directory_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as scratch:
            with self.assertRaises(FileExistsError):
                module.measure(scratch, ["/bin/true"])


if __name__ == "__main__":
    unittest.main()
