#!/usr/bin/env python3
"""Exercise the built public CLI on an empty private store with no cloud access."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

repo = Path(__file__).resolve().parents[3]
binary = subprocess.check_output(['cabal', 'list-bin', 'exe:nagarectl'], cwd=repo / 'cli/nagarectl', text=True).strip()
root = Path(tempfile.mkdtemp(prefix='mp23-explain-boundary-'))
config = root / 'config/nagare/contexts'
store = root / 'state/nagare/audit/inventory'
config.mkdir(parents=True)
store.mkdir(parents=True)
(config / 'audit.env').write_text('CLOUDSDK_CORE_PROJECT=project\nNAGARE_MODE=local\n')
head = {'version': 1, 'generation': 1, 'sequence': 0,
        'binding': {'identity': 'audit', 'project': 'project'}, 'clientIdentity': 'audit',
        'accepted': [], 'converged': [], 'activeTransaction': None, 'executorClaim': None}
(store / 'head.json').write_text(json.dumps(head, sort_keys=True, separators=(',', ':')))
(store / 'head.json').chmod(0o600)
bin_dir = root / 'bin'
bin_dir.mkdir()
calls = root / 'calls'
calls.write_text('')
for name in ['gcloud', 'kubectl', 'helm', 'pulumi', 'nix', 'ssh', 'docker', 'k3d', 'curl']:
    script = bin_dir / name
    script.write_text('#!/bin/sh\nprintf "%s\\n" "$0 $*" >> "$MP23_CALLS"\nexit 95\n')
    script.chmod(0o700)
env = {key: value for key, value in os.environ.items()
       if not key.startswith(('NAGARE_', 'CLOUDSDK_', 'PULUMI_', 'DIRENV_', 'GOOGLE_'))
       and key not in ['KUBECONFIG', 'XDG_CONFIG_HOME', 'XDG_STATE_HOME']}
env.update(HOME=str(root / 'home'), XDG_CONFIG_HOME=str(root / 'config'),
           XDG_STATE_HOME=str(root / 'state'), NAGARE_PLATFORM_ROOT=str(repo),
           PATH=str(bin_dir) + os.pathsep + env['PATH'], MP23_CALLS=str(calls))
results = []
for corrupt in [False, True]:
    if corrupt:
        (store / 'reviews').mkdir(exist_ok=True)
        review = store / 'reviews' / (hashlib.sha256(b'{}').hexdigest() + '.json')
        review.write_text('{}')
        review.chmod(0o600)
    started = time.monotonic()
    p = subprocess.run([binary, '--context', 'audit', 'inventory', 'explain',
                        'standalone:missing/object/resource', '--json'], env=env, cwd=root,
                       capture_output=True, text=True, timeout=15)
    results.append({'unrelatedMalformedReview': corrupt, 'exit': p.returncode,
                    'seconds': round(time.monotonic() - started, 3),
                    'stdout': p.stdout, 'stderr': p.stderr, 'providerCalls': calls.read_text().splitlines()})
report = {'binarySha256': hashlib.sha256(Path(binary).read_bytes()).hexdigest(), 'results': results}
(root / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
print(root)
print(json.dumps(report, indent=2))
