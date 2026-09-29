#!/usr/bin/env python3
"""Prove fresh-login refusal with a real SSH master surviving key revocation.

Uses an unprivileged loopback sshd and temporary keys/config; no system config,
cloud connection, sudo, or Nix store access. The remote activation is simulated.
"""
import getpass
import json
import os
import re
from pathlib import Path
import shlex
import shutil
import socket
import subprocess
import tempfile
import time

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='mp23-fresh-login-'))
print('Artifacts: '+str(root), flush=True)
ssh, sshd = shutil.which('ssh'), shutil.which('sshd')
assert ssh and sshd, 'OpenSSH client and server required'
quote = shlex.quote
for name in ['host', 'operator']:
    subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(root/name)], check=True)
authorized = root/'authorized_keys'
authorized.write_bytes((root/'operator.pub').read_bytes())
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
remote = root/'remote'
remote.write_text('''#!/bin/sh
case "$SSH_ORIGINAL_COMMAND" in
  *'nagare-safe-activate arm '*) echo 'ARMED previous=/fixture/old new=/fixture/new';;
  *'nagare-safe-activate activate '*) : > '''+quote(str(authorized))+''';;
  *'nagare-safe-activate commit '*) touch '''+quote(str(root/'committed'))+'''; echo 'COMMITTED new=/fixture/new';;
  *) echo /fixture/new;;
esac
''')
remote.chmod(0o700)
server_config = root/'sshd_config'
server_config.write_text(f'''ListenAddress 127.0.0.1
Port {port}
HostKey {root}/host
PidFile {root}/pid
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthorizedKeysFile {authorized}
StrictModes no
ForceCommand {remote}
LogLevel VERBOSE
PerSourcePenalties no
''')
client_config = root/'ssh_config'
# A short socket path also fits the UNIX socket limit on macOS.
control_dir = Path(tempfile.mkdtemp(prefix='mp23-ssh-', dir='/tmp'))
control = control_dir/'m'
client_config.write_text(f'''Host *
  HostName 127.0.0.1
  Port {port}
  User {getpass.getuser()}
  IdentityFile {root}/operator
  IdentitiesOnly yes
  BatchMode yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  ControlMaster auto
  ControlPath {control}
  ConnectTimeout 2
''')
log = (root/'sshd.log').open('w')
server = subprocess.Popen([sshd, '-D', '-e', '-f', str(server_config)], stderr=log)
master = None
try:
    deadline = time.monotonic()+5
    while True:
        assert server.poll() is None, (root/'sshd.log').read_text()
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=.1):
                break
        except OSError:
            assert time.monotonic() < deadline, 'sshd startup timed out'
            time.sleep(.02)
    master = subprocess.Popen([ssh, '-F', str(client_config), '-M', '-N', 'fixture'],
                              stdout=subprocess.DEVNULL, stderr=(root/'master.log').open('w'))
    while not control.exists():
        assert master.poll() is None, (root/'master.log').read_text()
        assert time.monotonic() < deadline, 'master startup timed out'
        time.sleep(.02)
    # Control: revocation leaves the multiplexed session usable, but a genuinely
    # new connection fails. This is the failure our production proof must catch.
    authorized.write_text('')
    def run(args):
        return subprocess.run([ssh, '-F', str(client_config), *args, 'fixture', 'probe'],
                              text=True, capture_output=True, timeout=5)
    assert run([]).returncode == 0
    assert run(['-o', 'ControlMaster=no', '-o', 'ControlPath=none']).returncode == 255
    authorized.write_bytes((root/'operator.pub').read_bytes())
    activate_script = root/'activation.sh'
    activate_script.write_text('# remote effects are simulated by ForceCommand\n')
    command = 'set -euo pipefail\nsource '+quote(str(repo/'nixos/lib/nagare-safe-switch-client.sh'))+'''
sleep() { :; }
nagare_safe_switch fixture /fixture/new 600 '''+quote(str(activate_script))+'\n'
    env = dict(os.environ, NIX_SSHOPTS=f'-F {client_config} -o ControlMaster=auto -o ControlPath={control}')
    result = subprocess.run(['bash', '-c', command], env=env, text=True, capture_output=True, timeout=15)
    (root/'switch.txt').write_text(result.stdout+result.stderr)
    print(json.dumps(dict(safeSwitchExit=result.returncode, committed=(root/'committed').exists())), flush=True)
    assert result.returncode == 4 and not (root/'committed').exists(), 'revoked key was accepted through the old connection'
    # Exercise both additional inventory proof paths with the same real master.
    # Only the IAP observations and machine identity are substituted. Every
    # fresh-login SSH argv is forwarded unchanged, with fixture addressing added.
    source = (repo/'scripts/inventory-host-transport.sh').read_text()
    functions = '\n'.join(re.search(r'^'+name+r'\(\) \{\n.*?^\}', source, re.M | re.S)[0]
                          for name in ['tailnet_fresh_closure', 'activate'])
    host_key = ' '.join((root/'host.pub').read_text().split()[:2])
    digest = 'a'*64
    setup = f'''set -euo pipefail
{functions}
script_dir={quote(str(repo/'scripts'))}
SSH_KEY={quote(str(root/'operator'))}
age_key_digest={digest}
request='{{"plan":{{"newClosure":"/fixture/new","expectedOldClosure":"/fixture/new","instance":"gce://fixture","ageKeyDigest":"{digest}"}}}}'
check_host_inputs() {{ :; }}
check_age_key_input() {{ :; }}
physical_identity() {{ echo gce://fixture; }}
emit_state() {{ printf '%s\\n' "$1"; }}
host_ssh() {{
  case "$*" in
    *'nagare-host-age-key status') printf 'age-key\\tready\\t/var/lib/sops-nix/age-key.txt\\t%s\\n' "$age_key_digest";;
    'tailscale ip -4'|'tailscale ip -4 >/dev/null') echo 100.64.0.1;;
    'cat /etc/ssh/ssh_host_ed25519_key.pub') echo {quote(host_key)};;
    *) return 95;;
  esac
}}
ssh() {{
  local -a args=()
  local arg
  for arg in "$@"; do
    if [ "$arg" = deploy@100.64.0.1 ]; then args+=("{getpass.getuser()}@100.64.0.1"); else args+=("$arg"); fi
  done
  {quote(ssh)} -F {quote(str(client_config))} -o HostKeyAlias=100.64.0.1 "${{args[@]}}"
}}
'''
    for function in ['tailnet_fresh_closure', 'activate']:
        for allowed in [False, True]:
            authorized.write_bytes((root/'operator.pub').read_bytes() if allowed else b'')
            checked = subprocess.run(['bash', '-c', setup+'\n'+function], text=True, capture_output=True, timeout=5)
            (root/f'{function}-{allowed}.txt').write_text(checked.stdout+checked.stderr)
            assert (checked.returncode == 0) == allowed, (function, allowed, checked.stderr)
            print(json.dumps(dict(path=function, authorized=allowed, exit=checked.returncode)))
    print('PASS: all three production fresh-login paths reject a revoked key while the master survives')
finally:
    for process in [master, server]:
        if process is not None:
            process.terminate()
            process.wait(timeout=5)
    control.unlink(missing_ok=True)
    control_dir.rmdir()
    log.close()
