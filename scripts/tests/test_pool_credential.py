import importlib.util
import io
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('pool_credential', Path(__file__).parents[1] / 'with-pool-credential.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
SECRET = b'b' * 64 + b'\n'


class CredentialInputTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.input = self.root / 'htcondor-pool-password'

    def tearDown(self):
        self.temp.cleanup()

    def run_command(self, code, secret=SECRET):
        with patch.object(module.os, 'geteuid', return_value=0):
            return module.run([sys.executable, '-c', code, str(self.input)], io.BytesIO(secret), self.root)

    def test_protected_file_complete_before_child_and_stdin_is_not_forwarded(self):
        code = '''import os,stat,sys
from pathlib import Path
path=Path(sys.argv[1]); info=path.stat()
assert stat.S_IMODE(info.st_mode)==0o600
assert info.st_uid==os.geteuid()
assert path.read_bytes()==b'b'*64+b'\\n'
assert sys.stdin.buffer.read()==b''
assert not any(b'b'*64 in arg.encode() for arg in sys.argv)
assert not any(b'b'*64 in value.encode() for value in os.environ.values())
'''
        self.assertEqual(self.run_command(code), 0)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_command_exit_codes_preserved_and_input_removed(self):
        for status in [2, 7]:
            self.assertEqual(self.run_command(f'import sys; sys.exit({status})'), status)
            self.assertEqual(list(self.root.iterdir()), [])

    def test_failed_command_launch_also_cleans_up(self):
        with patch.object(module.os, 'geteuid', return_value=0):
            with self.assertRaises(FileNotFoundError):
                module.run(['/no/such/command'], io.BytesIO(SECRET), self.root)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_existing_input_and_dangling_symlink_not_overwritten_or_deleted(self):
        self.input.write_text('owned by another run')
        with self.assertRaises(FileExistsError):
            self.run_command('raise AssertionError("must not run")')
        self.assertEqual(self.input.read_text(), 'owned by another run')
        self.input.unlink()
        self.input.symlink_to(self.root / 'missing')
        with self.assertRaises(FileExistsError):
            self.run_command('raise AssertionError("must not run")')
        self.assertTrue(self.input.is_symlink())
        self.assertEqual(len(list(self.root.iterdir())), 1)

    def test_bad_inputs_rejected_before_creating_files_or_launching_child(self):
        for secret in [b'', b'b'*64, b'B'*64+b'\n', b'bad\n', SECRET+b'extra', b'\x00'*64+b'\n']:
            with self.assertRaises(ValueError):
                self.run_command('raise AssertionError("must not run")', secret)
            self.assertEqual(list(self.root.iterdir()), [])

    def test_nonroot_refused_before_reading_input(self):
        with patch.object(module.os, 'geteuid', return_value=1000):
            with self.assertRaises(PermissionError):
                module.run(['/bin/true'], None, self.root)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_term_stops_child_and_cleans_protected_input(self):
        # Signal only the wrapper process, not the foreground test runner.
        driver = '''import importlib.util,io,sys
from pathlib import Path
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('wrapper',sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
code='import os,signal,time; os.kill(os.getppid(),signal.SIGTERM); time.sleep(30)'
try:
 with patch.object(m.os,'geteuid',return_value=0): m.run([sys.executable,'-c',code],io.BytesIO(b'b'*64+b'\\n'),Path(sys.argv[2]))
except m.Interrupted:
 sys.exit(143)
'''
        result = subprocess.run([sys.executable, '-c', driver, str(Path(module.__file__)), str(self.root)],
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 143, result.stderr)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_descendant_is_stopped_even_if_command_leader_exits_first(self):
        code = '''import subprocess,sys
from pathlib import Path
marker=Path(sys.argv[1]).with_name('escaped-child')
subprocess.Popen([sys.executable,'-c',"import time; from pathlib import Path; time.sleep(1); Path("+repr(str(marker))+").write_text('escaped')"])
'''
        self.assertEqual(self.run_command(code), 0)
        time.sleep(1.2)
        self.assertFalse((self.root / 'escaped-child').exists())
        self.assertEqual(list(self.root.iterdir()), [])

    def test_cleanup_error_is_reported_and_signal_handlers_are_restored(self):
        previous = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
        try:
            with patch.object(module.os, 'geteuid', return_value=0), patch.object(module.shutil, 'rmtree', side_effect=OSError('fixture cleanup failure')):
                with self.assertRaises(OSError):
                    module.run(['/bin/true'], io.BytesIO(SECRET), self.root)
            self.assertFalse(self.input.exists())
            for sig, handler in previous.items():
                self.assertEqual(signal.getsignal(sig), handler)
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)

    def test_empty_command_rejected_before_reading_input(self):
        with patch.object(module.os, 'geteuid', return_value=0):
            with self.assertRaises(ValueError):
                module.run([], None, self.root)


if __name__ == '__main__':
    unittest.main()
