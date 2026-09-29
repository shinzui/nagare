#!/usr/bin/env python3
"""Retry actual transport/helper logic after key persistence and service failure.

Runs without root: uid/ownership and systemd/IAP/SSH are fixture boundaries.
Key bytes, digest checks, file mode, inode/mtime, shell error propagation and
the production helper/transport functions are real. No credentials are used.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import textwrap

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='mp23-key-recovery-'))
print('Artifacts: '+str(root), flush=True)
quote = shlex.quote
module = (repo/'nixos/modules/nagare-host.nix').read_text()
helper_source = textwrap.dedent(module.split("    text = ''\n", 1)[1].split("    '';", 1)[0]).replace("''${", '${')
transport_source = (repo/'scripts/inventory-host-transport.sh').read_text()
activate = '\n'.join(re.search(r'^'+name+r'\(\) \{\n.*?^\}', transport_source, re.M | re.S)[0]
                     for name in ['activate', 'emit_state'])
rows = []
for failed in ['sops', 'tailscale']:
    case = root/failed
    case.mkdir()
    key, installed, secret = case/'input', case/'host/key', case/'decrypted'
    key.write_text('synthetic fixture key; never an age identity\n')
    digest = hashlib.sha256(key.read_bytes()).hexdigest()
    calls = case/'calls'
    calls.write_text('')
    failure = case/'fail'
    failure.write_text(failed)
    helper = case/'helper.sh'
    # Privileged metadata is explicitly emulated; mode comes from the real file.
    # The helper body itself is extracted unchanged except Nix interpolation.
    boundaries = f'''set -euo pipefail
id() {{ [ "$*" = -u ]; echo 0; }}
chown() {{ [ "$*" = "root:root {installed}" ]; }}
stat() {{
  [ "$1" = -c ] && [ "$2" = '%u:%g:%a' ] && [ "$3" = {quote(str(installed))} ]
  python3 -c 'import os,sys; print("0:0:%o" % (os.stat(sys.argv[1]).st_mode & 0o777))' "$3"
}}
install() {{
  if [ "$1" = -d ]; then
    [ "$*" = "-d -o root -g root -m 0700 {installed.parent}" ]
    mkdir -p {quote(str(installed.parent))}; chmod 0700 {quote(str(installed.parent))}
  else
    [ "$*" = "-o root -g root -m 0400 /dev/stdin {installed}" ]
    printf 'key-write\\n' >> {quote(str(calls))}
    cat > {quote(str(installed))}; chmod 0400 {quote(str(installed))}
  fi
}}
systemctl() {{
  printf '%s\\n' "$*" >> {quote(str(calls))}
  [ "$1" = restart ]
  case "$2" in
    sops-install-secrets.service)
      [ "$(cat {quote(str(failure))})" != sops ] || return 42
      echo synthetic-decrypted-secret > {quote(str(secret))};;
    tailscaled-autoconnect.service)
      [ "$(cat {quote(str(failure))})" != tailscale ] || return 43
      touch {quote(str(case/'ready'))};;
    *) return 95;;
  esac
}}
'''
    helper.write_text(boundaries+helper_source.replace('${ageKeyFile}', quote(str(installed)))
                      .replace('${tailscaleAuthKeyFile}', quote(str(secret))))
    request = json.dumps({'plan': {'newClosure': '/fixture/system', 'expectedOldClosure': '/fixture/system',
                                  'instance': 'gce://fixture', 'ageKeyDigest': digest}})
    runner = case/'activate.sh'
    runner.write_text(f'''set -euo pipefail
{activate}
script_dir={quote(str(repo/'scripts'))}
request={quote(request)}
age_key_digest={digest}
instance=fixture
SSH_KEY={quote(str(case/'ssh-key'))}
NAGARE_HOST_AGE_KEY_FILE={quote(str(key))}
check_host_inputs() {{ :; }}
check_age_key_input() {{ [ "$(shasum -a 256 "$NAGARE_HOST_AGE_KEY_FILE" | awk '{{print $1}}')" = "$age_key_digest" ]; }}
physical_identity() {{ echo gce://fixture; }}
host_ssh() {{
  case "$*" in
    *'nagare-host-age-key status') command bash {quote(str(helper))} status | sed 's|{installed}|/var/lib/sops-nix/age-key.txt|g';;
    'tailscale ip -4'|'tailscale ip -4 >/dev/null') [ -f {quote(str(case/'ready'))} ] || return 1; echo 100.64.0.1;;
    'cat /etc/ssh/ssh_host_ed25519_key.pub') echo 'ssh-ed25519 fixture-host-key';;
    *) return 95;;
  esac
}}
bash() {{
  [ "$1" = "$script_dir/iap-ssh.sh" ] && [ "$2" = send-file ] && [ "$3" = fixture ]
  printf 'delivery\\n' >> {quote(str(calls))}
  command bash {quote(str(helper))} install --sha256 "$age_key_digest" < "$NAGARE_HOST_AGE_KEY_FILE"
}}
ssh() {{
  printf 'fresh-ssh %s\\n' "$*" >> {quote(str(calls))}
  [ -f {quote(str(case/'ready'))} ]
  echo /fixture/system
}}
activate
''')
    def run(label):
        p = subprocess.run(['bash', str(runner)], text=True, capture_output=True, timeout=5)
        (case/(label+'.txt')).write_text(p.stdout+p.stderr)
        return p
    first = run('failed')
    assert first.returncode == (42 if failed == 'sops' else 43), first
    assert installed.read_bytes() == key.read_bytes() and installed.stat().st_mode & 0o777 == 0o400
    assert 'HostTransportCommitted' not in first.stdout and 'fresh-ssh' not in calls.read_text()
    identity = (installed.stat().st_ino, installed.stat().st_mtime_ns)
    failure.write_text('none')
    retried = run('retried')
    assert retried.returncode == 0 and json.loads(retried.stdout)['tag'] == 'HostTransportCommitted', retried
    assert 'age key ready at ' in retried.stderr, 'helper diagnostic lost'
    assert (installed.stat().st_ino, installed.stat().st_mtime_ns) == identity, 'retry rewrote the installed key'
    assert calls.read_text().splitlines().count('key-write') == 1
    assert calls.read_text().splitlines().count('delivery') == 2
    assert calls.read_text().count('restart sops-install-secrets.service') == 2
    before = calls.read_text()
    assert run('already-ready').returncode == 0
    assert calls.read_text()[len(before):].startswith('fresh-ssh '), 'ready retry reran activation'
    # Wrong installed key must refuse before delivery, activation or fresh login.
    installed.chmod(0o600)
    installed.write_text('different fixture key\n')
    installed.chmod(0o400)
    before = calls.read_text()
    wrong = run('wrong-key')
    assert wrong.returncode == 2 and calls.read_text() == before, wrong
    rows.append(dict(failure=failed, firstExit=first.returncode, retryExit=retried.returncode,
                     persistedKeyUnchanged=True, keyWrites=1, wrongKeyExit=wrong.returncode))
    print(json.dumps(rows[-1]), flush=True)
(root/'result.json').write_text(json.dumps(rows, indent=2)+'\n')
print('PASS: original activation retries after either service failure without replacing the persisted key')
