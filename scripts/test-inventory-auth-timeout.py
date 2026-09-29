#!/usr/bin/env python3
"""Exercise the real credential subprocess timeout; no real credentials or network."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

repo = Path(__file__).resolve().parents[1]
binary = subprocess.check_output(
    ['cabal', 'list-bin', 'exe:nagarectl', '--enable-tests'],
    cwd=repo/'cli/nagarectl', text=True).strip()
root = Path(tempfile.mkdtemp(prefix='mp23-auth-timeout-'))
bins = root/'bin'
bins.mkdir()
helper = bins/'gcloud'
helper.write_text(f'''#!{sys.executable}
import os,time
from pathlib import Path
Path(os.environ['MP23_PID']).write_text(str(os.getpid()))
print('private-helper-token', flush=True)
time.sleep(60)
''')
helper.chmod(0o700)
profile = root/'config/nagare/contexts/audit.env'
profile.parent.mkdir(parents=True)
profile.write_text('CLOUDSDK_CORE_PROJECT=project\nNAGARE_MODE=cloud\nNAGARE_INVENTORY_STORE=gcs\nNAGARE_INVENTORY_STORE_URL=gs://audit.invalid/private\n')
profile.chmod(0o600)
base = {k: v for k, v in os.environ.items()
        if not k.startswith(('NAGARE_', 'CLOUDSDK_', 'GOOGLE_', 'PULUMI_', 'DIRENV_'))
        and k not in ['KUBECONFIG', 'XDG_CONFIG_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME']}
env = dict(base, HOME=str(root/'home'), PATH=str(bins)+os.pathsep+base['PATH'],
           XDG_CONFIG_HOME=str(root/'config'), XDG_STATE_HOME=str(root/'state'),
           XDG_CACHE_HOME=str(root/'cache'), MP23_PID=str(root/'pid'))
start = time.monotonic()
p = subprocess.run([binary, '--context', 'audit', 'inventory', 'store', 'status', '--json'],
                   env=env, cwd=root, capture_output=True, text=True, timeout=22)
elapsed = time.monotonic()-start
assert p.returncode != 0 and 'timed out' in p.stderr, (p.returncode, p.stderr)
assert 14 <= elapsed < 20, elapsed
assert 'private-helper-token' not in p.stdout+p.stderr
pid = int((root/'pid').read_text())
try:
    os.kill(pid, 0)
except ProcessLookupError:
    pass
else:
    raise AssertionError('credential helper survived the command timeout')
report = dict(binarySha256=hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
              seconds=round(elapsed, 3), exit=p.returncode, childReaped=True,
              credentialRedacted=True, realCredentialUse=False)
(root/'result.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report))
print('Artifacts: '+str(root))
