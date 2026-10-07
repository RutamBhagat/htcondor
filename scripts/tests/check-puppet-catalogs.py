#!/usr/bin/env python3
"""Compile both actual role entrypoints and inspect catalogs; never apply them."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).parents[2]


def compile_catalog(puppet, role, cm='10.0.0.1', own=None, peer=None):
    own = own if own is not None else ('10.0.0.1' if role == 'controller' else '10.0.0.2')
    peer = peer if peer is not None else ('10.0.0.2' if role == 'controller' else '10.0.0.1')
    env = dict(os.environ, FACTER_htcondor_own=own, FACTER_htcondor_peer=peer)
    if cm is None:
        env.pop('FACTER_htcondor_cm', None)
    else:
        env['FACTER_htcondor_cm'] = cm
    return subprocess.run([puppet, 'catalog', 'compile', '--render-as', 'json', '--log_level', 'err', '--logdest', '/dev/stderr',
                           '--manifest', str(ROOT / f'puppet/manifests/{role}.pp'),
                           '--modulepath', str(ROOT / 'puppet/modules')],
                          env=env, capture_output=True, text=True, timeout=45)


def check(catalog, role):
    resources = {(r['type'], r['title']): r.get('parameters', {}) for r in catalog['resources']}
    def get(kind, title):
        return resources[kind, title]
    assert get('Package', 'condor')['ensure'] == '25.0.14-1+ubu24'
    for package in ['iptables-persistent', 'netfilter-persistent']:
        assert get('Package', package)['ensure'] == 'installed'
    assert get('Service', 'condor')['ensure'] == 'running'
    assert get('Service', 'condor')['enable'] is True
    expected = ['01-central-manager.config', '01-submit.config'] if role == 'controller' else ['01-execute.config']
    knobs = {'01-central-manager.config': 'get_htcondor_central_manager',
             '01-submit.config': 'get_htcondor_submit', '01-execute.config': 'get_htcondor_execute'}
    for name, knob in knobs.items():
        file = get('File', '/etc/condor/config.d/' + name)
        assert file['ensure'] == ('file' if name in expected else 'absent')
        if name in expected:
            assert file['content'] == f'CONDOR_HOST = 10.0.0.1\nuse role:{knob}\n'
            assert int(file['mode'], 8) == 0o644
            assert file['notify'] == 'Service[condor]'
    own = '10.0.0.1' if role == 'controller' else '10.0.0.2'
    peer = '10.0.0.2' if role == 'controller' else '10.0.0.1'
    assert get('File', '/etc/condor/config.d/02-private-network.config')['content'] == f'NETWORK_INTERFACE = {own}\nBIND_ALL_INTERFACES = FALSE\n'
    assert get('File', '/etc/condor/config.d/00-security')['content'] == 'use security:recommended\n'
    assert get('File', '/etc/condor/condor_config.local')['ensure'] == 'absent'
    for path in ['/etc/condor/passwords.d/POOL', '/etc/condor/tokens.d/condor@10.0.0.1']:
        file = get('File', path)
        assert file['owner'] == file['group'] == 'root'
        assert int(file['mode'], 8) == 0o600 and file['show_diff'] is False
        assert 'content' not in file and 'source' not in file
    for path in ['/etc/condor/passwords.d', '/etc/condor/tokens.d']:
        assert int(get('File', path)['mode'], 8) == 0o700
    for path, group, mode in [('/var/run/condor', 'condor', 0o775), ('/var/lock/condor', 'condor', 0o775),
                              ('/var/log/condor', 'root', 0o755), ('/var/spool/condor', 'condor', 0o755),
                              ('/var/lib/condor/execute', 'condor', 0o755)]:
        directory = get('File', path)
        assert directory['ensure'] == 'directory' and directory['owner'] == 'condor'
        assert directory['group'] == group and int(directory['mode'], 8) == mode
    assert get('Exec', 'refresh-htcondor-apt')['refreshonly'] is True
    assert 'unless' in get('Exec', 'mask-fresh-condor')
    assert 'onlyif' in get('Exec', 'unmask-configured-condor')
    for name in ['provision-pool-key', 'provision-daemon-token']:
        assert 'unless' in get('Exec', name)
        assert get('Exec', name)['logoutput'] is False
    firewall = get('Exec', 'private-condor-firewall')
    assert firewall['command'] == f'/usr/local/sbin/htcondor-firewall {peer} {own}'
    assert '/etc/iptables/rules.v4' in firewall['unless'] and '{print;exit}' in firewall['unless']
    # Package-owned defaults/plugin files and unrelated firewall tables are not purged.
    assert ('File', '/etc/condor/condor_config') not in resources
    assert ('File', '/etc/condor/config.d/10-stash-plugin.conf') not in resources
    assert all(not p.get('purge') for (kind, _), p in resources.items() if kind == 'File')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--puppet', default='/opt/puppetlabs/bin/puppet')
    args = parser.parse_args()
    key = ROOT / 'puppet/modules/htcondor/files/htcondor.asc'
    assert hashlib.sha256(key.read_bytes()).hexdigest() == '5c20981408b66912dff7aa60116ee1e3915c7e0ed800a17a4099a4b0c830aafc'
    for role in ['controller', 'worker']:
        result = compile_catalog(args.puppet, role)
        assert result.returncode == 0, result.stderr
        check(json.loads(result.stdout), role)
        print(role + ': actual entrypoint catalog contract passed')
    # Inputs accepted by the measured bootstrap, including reserved private ranges.
    result = compile_catalog(args.puppet, 'controller', cm='192.0.2.1', own='192.0.2.1', peer='203.0.113.2')
    assert result.returncode == 0, result.stderr
    assert compile_catalog(args.puppet, 'controller', cm=None).returncode != 0, 'Missing fact accepted'
    for bad in ['', '0', '8.8.8.8', '127.0.0.1', '0.0.0.0', '10.0.0.256', '010.0.0.1', '192.0.0.9', '10.0.0.1;id']:
        # Keep controller topology valid so rejection cannot be attributed to
        # the unrelated cm != own check instead of address validation.
        assert compile_catalog(args.puppet, 'controller', cm=bad, own=bad).returncode != 0, 'Invalid address accepted'
    for role, own, peer in [('controller', '10.0.0.2', '10.0.0.3'), ('worker', '10.0.0.2', '10.0.0.3'), ('worker', '10.0.0.1', '10.0.0.1')]:
        assert compile_catalog(args.puppet, role, own=own, peer=peer).returncode != 0, 'Invalid topology accepted'
    print('Private-address accepted/rejected inputs and both topology boundaries passed')


if __name__ == '__main__':
    main()
