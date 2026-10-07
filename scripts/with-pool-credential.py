#!/usr/bin/env python3
"""Run a trusted command with a protected, temporary pool input; no secret argv."""
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile


class Interrupted(Exception):
    def __init__(self, signum):
        self.signum = signum


def run(command, source, runtime_dir=Path('/run')):
    if not command:
        raise ValueError('Expected a command to run')
    if os.geteuid() != 0:
        raise PermissionError('Run as root')
    # Bound input size; require exactly one line, unlike bootstrap's readline.
    # SSH callers must send a file/closed pipe, not leave an interactive stdin.
    credential = source.read(66)
    if re.fullmatch(rb'[0-9a-f]{64}\n', credential) is None:
        raise ValueError('Expected exactly one newline-terminated 256-bit hex credential')
    target = Path(runtime_dir) / 'htcondor-pool-password'
    scratch = None
    process = None

    def interrupt(signum, _frame):
        raise Interrupted(signum)

    signals = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    previous = {sig: signal.signal(sig, interrupt) for sig in signals}
    try:
        scratch = Path(tempfile.mkdtemp(prefix='.htcondor-pool-', dir=runtime_dir))
        private = scratch / 'credential'
        fd = os.open(private, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as output:
            os.fchmod(output.fileno(), 0o600)
            output.write(credential)
        del credential
        # Atomic publication refuses existing files AND dangling symlinks.
        os.link(private, target)
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, start_new_session=True)
        status = process.wait()
        return status if status >= 0 else 128 - status
    finally:
        # A second signal must not interrupt credential removal. Terminate the
        # command's private group, including descendants if its leader exited.
        for sig in signals:
            signal.signal(sig, signal.SIG_IGN)
        try:
            if process is not None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
            if scratch is not None:
                private = scratch / 'credential'
                try:
                    published = target.lstat()
                    original = private.stat()
                    if stat.S_ISREG(published.st_mode) and (published.st_dev, published.st_ino) == (original.st_dev, original.st_ino):
                        target.unlink()
                except FileNotFoundError:
                    pass
                shutil.rmtree(scratch)
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)


def main():
    if len(sys.argv) < 3 or sys.argv[1] != '--':
        print('Usage: with-pool-credential.py -- COMMAND [ARGS...] < protected-input', file=sys.stderr)
        return 2
    try:
        return run(sys.argv[2:], sys.stdin.buffer)
    except Interrupted as error:
        return 128 + error.signum
    except (OSError, ValueError) as error:
        # Do not print input, command environment, or credential tool output.
        print(f'Protected credential command failed: {type(error).__name__}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
