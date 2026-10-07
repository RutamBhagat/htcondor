from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

FILES = Path(__file__).parents[2] / 'puppet/modules/htcondor/files'
PEER, OWN = '10.0.0.2', '10.0.0.1'
RULE = f'-A INPUT -s {PEER}/32 -d {OWN}/32 -p tcp -m tcp --dport 9618 -j ACCEPT'
OCI = '-A INPUT -p tcp --dport 22 -j ACCEPT\n-A INPUT -j REJECT\n'


class HelperTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'], STATE=str(self.root), RULE=RULE)

    def tearDown(self):
        self.temp.cleanup()

    def tool(self, name, body):
        script = self.bin / name
        script.write_text('#!/usr/bin/env python3\n' + body)
        script.chmod(0o755)

    def run_helper(self, name, *args):
        return subprocess.run(['bash', str(FILES / name), *map(str, args)], env=self.env,
                              capture_output=True, text=True, timeout=5)

    def firewall_model(self, live, saved):
        (self.root / 'live').write_text(live)
        (self.root / 'saved').write_text(saved)
        self.tool('iptables', '''import os,sys
from pathlib import Path
root=Path(os.environ['STATE']); rule=os.environ['RULE']; args=sys.argv[1:]
if os.environ.get('FAIL_QUERY') and '-S' in args: sys.exit(3)
rows=(root/'live').read_text().splitlines()
with (root/'calls').open('a') as log: log.write('iptables '+ ' '.join(args)+'\\n')
if '-S' in args: print('-P INPUT ACCEPT\\n'+'\\n'.join(rows))
elif '-C' in args: sys.exit(0 if rule in rows else 1)
elif '-D' in args: rows.remove(rule); (root/'live').write_text('\\n'.join(rows)+'\\n')
elif '-I' in args: rows.insert(0,rule); (root/'live').write_text('\\n'.join(rows)+'\\n')
else: sys.exit(99)
''')
        self.tool('netfilter-persistent', '''import os,sys,shutil
from pathlib import Path
assert sys.argv[1:]==['save']
root=Path(os.environ['STATE']); shutil.copyfile(root/'live',root/'saved')
with (root/'calls').open('a') as log: log.write('save\\n')
''')
        for name in ['grep', 'awk']:
            real = shutil.which(name)
            self.tool(name, f'''import os,sys
args=[str(__import__('pathlib').Path(os.environ['STATE'])/'saved') if a=='/etc/iptables/rules.v4' else a for a in sys.argv[1:]]
os.execv({real!r}, [{name!r}]+args)
''')

    def test_firewall_preserves_oci_rules_and_second_run_is_clean(self):
        self.firewall_model(OCI, OCI)
        self.assertEqual(self.run_helper('firewall.sh', PEER, OWN).returncode, 0)
        self.assertEqual((self.root / 'live').read_text(), RULE + '\n' + OCI)
        self.assertEqual((self.root / 'saved').read_text(), RULE + '\n' + OCI)
        before = (self.root / 'calls').read_text()
        self.assertEqual(self.run_helper('firewall.sh', PEER, OWN).returncode, 0)
        after = (self.root / 'calls').read_text()[len(before):]
        self.assertNotIn('-I', after)
        self.assertNotIn('-D', after)
        self.assertNotIn('save', after)

    def test_firewall_moves_rule_before_reject_and_persists_order(self):
        self.firewall_model(OCI + RULE + '\n', OCI + RULE + '\n')
        self.assertEqual(self.run_helper('firewall.sh', PEER, OWN).returncode, 0)
        self.assertEqual((self.root / 'live').read_text(), RULE + '\n' + OCI)
        self.assertEqual((self.root / 'saved').read_text(), RULE + '\n' + OCI)

    def test_firewall_repairs_persistence_without_duplicate_live_rule(self):
        self.firewall_model(RULE + '\n' + OCI, OCI)
        self.assertEqual(self.run_helper('firewall.sh', PEER, OWN).returncode, 0)
        self.assertEqual((self.root / 'live').read_text(), RULE + '\n' + OCI)
        self.assertEqual((self.root / 'saved').read_text(), RULE + '\n' + OCI)

    def test_firewall_query_failure_does_not_mutate_rules(self):
        self.firewall_model(OCI, OCI)
        self.env['FAIL_QUERY'] = '1'
        self.assertNotEqual(self.run_helper('firewall.sh', PEER, OWN).returncode, 0)
        self.assertEqual((self.root / 'live').read_text(), OCI)
        self.assertEqual((self.root / 'saved').read_text(), OCI)

    def credential_model(self):
        self.tool('stat', '''import os,sys
from pathlib import Path
mode=oct(Path(sys.argv[-1]).stat().st_mode & 0o777)[2:]
print(mode+':'+ ('1000:1000' if os.environ.get('BAD_OWNER') else '0:0'))
''')
        self.tool('condor_store_cred', '''import os,sys
from pathlib import Path
password=sys.stdin.buffer.read()
assert sys.argv[1:]==['add','-c','-i','-']
assert len(password)==64 and b'\\n' not in password
if os.environ.get('FAIL_TOOL'): print(password.decode(),file=sys.stderr); sys.exit(1)
Path(os.environ['_CONDOR_SEC_PASSWORD_FILE']).write_bytes(b'encoded-fixture')
''')
        self.tool('condor_token_create', '''import os,sys
assert sys.argv[1:]==['-identity','condor@10.0.0.1']
if os.environ.get('FAIL_TOOL'): print('secret-token-fixture',file=sys.stderr); sys.exit(1)
print('dummy.signed.token')
''')
        secret = self.root / 'input'
        secret.write_text('a' * 64 + '\n')
        secret.chmod(0o600)
        return secret, self.root / 'output'

    def test_key_uses_stdin_atomic_mode_and_adopts_without_reading_input(self):
        secret, output = self.credential_model()
        result = self.run_helper('credentials.sh', 'key', secret, output)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_bytes(), b'encoded-fixture')
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        secret.unlink()
        self.assertEqual(self.run_helper('credentials.sh', 'key', secret, output).returncode, 0)
        self.assertEqual(output.read_bytes(), b'encoded-fixture')

    def test_key_rejects_bad_format_missing_newline_modes_and_owner(self):
        secret, output = self.credential_model()
        for password in ['a' * 64, 'bad\n', 'A' * 64 + '\n']:
            secret.write_text(password)
            self.assertNotEqual(self.run_helper('credentials.sh', 'key', secret, output).returncode, 0)
            self.assertFalse(output.exists())
        secret.write_text('a' * 64 + '\n')
        secret.chmod(0o644)
        self.assertNotEqual(self.run_helper('credentials.sh', 'key', secret, output).returncode, 0)
        secret.chmod(0o600)
        self.env['BAD_OWNER'] = '1'
        self.assertNotEqual(self.run_helper('credentials.sh', 'key', secret, output).returncode, 0)

    def test_key_failure_suppresses_secret_stderr_and_leaves_no_partial_file(self):
        secret, output = self.credential_model()
        self.env['FAIL_TOOL'] = '1'
        result = self.run_helper('credentials.sh', 'key', secret, output)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('a' * 64, result.stdout + result.stderr)
        self.assertFalse(output.exists())
        self.assertEqual(list(self.root.glob('output.*')), [])

    def test_token_is_atomic_private_and_tool_failure_is_not_logged(self):
        _, output = self.credential_model()
        self.assertEqual(self.run_helper('credentials.sh', 'token', 'condor@10.0.0.1', output).returncode, 0)
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        output.unlink()
        self.env['FAIL_TOOL'] = '1'
        result = self.run_helper('credentials.sh', 'token', 'condor@10.0.0.1', output)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('secret-token-fixture', result.stdout + result.stderr)
        self.assertFalse(output.exists())

    def test_symlink_destination_is_rejected_not_adopted(self):
        secret, output = self.credential_model()
        output.symlink_to(secret)
        self.assertNotEqual(self.run_helper('credentials.sh', 'key', secret, output).returncode, 0)
        self.assertEqual(secret.read_text(), 'a' * 64 + '\n')


if __name__ == '__main__':
    unittest.main()
