#!/usr/bin/env python3
"""Exercise production send-file through OpenSSH's joined remote shell command."""
import json
from pathlib import Path
import re
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
source = (repo / 'scripts/iap-ssh.sh').read_text()
quote = re.search(r'^quote_remote_argv\(\) \{\n.*?^\}', source, re.M | re.S)[0]
send = re.search(r'^_do_send_file_inner\(\) \(\n.*?^\)', source, re.M | re.S)[0]
with tempfile.TemporaryDirectory(prefix='mp23-ssh-argv-') as directory:
    root = Path(directory)
    payload = root / 'stream input'
    payload.write_bytes(b'synthetic file bytes\x00\n')
    output = root / 'received.json'
    marker = root / 'injected'
    receiver = root / 'receive arguments.py'
    receiver.write_text('import sys,json\nfrom pathlib import Path\n'
                        'Path(sys.argv[1]).write_text(json.dumps([sys.argv[2:],sys.stdin.buffer.read().hex()]))\n')
    arguments = ['', 'spaces and tabs\t', "single'quote", 'double"quote', 'line1\nline2',
                 '\\path\\end', '$(touch '+str(marker)+')', '; touch '+str(marker), '`touch '+str(marker)+'`']
    runner = root / 'run.sh'
    runner.write_text('set -euo pipefail\n' + quote + '\n' + send + '''
SSH_USER=fixture
start_tunnel() { printf '1 1 %s\\n' "$FIXTURE_LOG"; }
ssh_common_args() { :; }
ssh_proxy_cmd() { printf fixture; }
kill() { :; }
wait() { :; }
ssh() {
  [ "$1" = -o ] && [ "$2" = ProxyCommand=fixture ] && [ "$3" = fixture@localhost ]
  shift 3
  # OpenSSH sends the joined command text for the remote login shell to parse.
  /bin/sh -c "$*"
}
_do_send_file_inner fixture "$@"
''')
    import os
    env = dict(os.environ, FIXTURE_LOG=str(root / 'tunnel.log'))
    subprocess.run(['bash', str(runner), str(payload), 'python3', str(receiver), str(output), *arguments],
                   env=env, check=True)
    assert json.loads(output.read_text()) == [arguments, payload.read_bytes().hex()]
    assert not marker.exists()
    # Real multiline bash -c shape, including the empty previous-key argument.
    script = 'set -eu\nexec python3 "$1" "$2" "$3" "$4"'
    subprocess.run(['bash', str(runner), str(payload), 'bash', '-c', script,
                    'reviewed-key', str(receiver), str(output), '', 'digest'], env=env, check=True)
    assert json.loads(output.read_text()) == [['', 'digest'], payload.read_bytes().hex()]
print('IAP send-file preserves remote argv and stdin across the SSH shell boundary')
