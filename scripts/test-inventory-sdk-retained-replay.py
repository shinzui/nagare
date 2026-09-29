#!/usr/bin/env python3
"""Bounded no-op resume of the already converged disposable GCS transaction.

Requires the retained inactive head. Creates isolated local roots, copies no
journal/cache, and refuses native commands. No apply, takeover or global switch.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import tempfile
import time

repo = Path(__file__).resolve().parents[1]
binary = subprocess.check_output(['cabal', 'list-bin', 'exe:nagarectl', '--enable-tests'],
                                 cwd=repo/'cli/nagarectl', text=True).strip()
fixture = json.loads((repo/'fixtures/inventory-release/gcp/ep150-target.json').read_text())
transaction = 'tx-e4c52b1595dda6ab02d96037aea30ef50bcad72ab3c085ad1e662edc99677ddd'
url = 'gs://'+fixture['stateBucket']+'/inventory'
root = Path(tempfile.mkdtemp(prefix='mp23-sdk-retained-'))
bins = root/'bin'
bins.mkdir()
for name in ['kubectl', 'helm', 'pulumi', 'nix', 'ssh', 'docker', 'curl']:
    path = bins/name
    version_probe = ''
    if name == 'ssh':
        # gcloud checks the local SSH version even for storage-only commands.
        # Permit exactly that check, while refusing every SSH connection.
        version_probe = ('if [ "$#" -eq 1 ] && [ "$1" = "-V" ]; then exec '
                         + shlex.quote(shutil.which('ssh')) + ' -V; fi\n')
    path.write_text('#!/bin/sh\n'+version_probe+'printf "%s\\n" "$0" >> "$MP23_NATIVE_CALLS"\nexit 95\n')
    path.chmod(0o700)
gcloud = shutil.which('gcloud')
assert gcloud
base = {k: v for k, v in os.environ.items()
        if not k.startswith(('NAGARE_', 'CLOUDSDK_', 'GOOGLE_', 'PULUMI_', 'DIRENV_'))
        and k not in ['KUBECONFIG', 'XDG_CONFIG_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME']}
env = dict(base, PATH=str(bins)+os.pathsep+base['PATH'],
           CLOUDSDK_CONFIG=os.environ.get('CLOUDSDK_CONFIG', str(Path.home()/'.config/gcloud')),
           CLOUDSDK_CORE_PROJECT=fixture['project'],
           CLOUDSDK_ACTIVE_CONFIG_NAME=fixture['gcloudConfiguration'],
           CLOUDSDK_CORE_LOG_HTTP='false', CLOUDSDK_CORE_DISABLE_FILE_LOGGING='true',
           CLOUDSDK_CORE_DISABLE_PROMPTS='true', MP23_NATIVE_CALLS=str(root/'native-calls'),
           NAGARE_PLATFORM_ROOT=str(root/'no-workspace'))


def cloud_json(args):
    p = subprocess.run([gcloud, *args, '--quiet'], env=env, capture_output=True,
                       text=True, timeout=15)
    if p.returncode:
        raise RuntimeError('retained-history preflight failed; private output withheld')
    return json.loads(p.stdout)


def metadata():
    return cloud_json(['storage', 'objects', 'describe', url+'/head.json',
                       '--raw', '--format=json(generation,size)'])


before = metadata()
assert str(before['generation']) == '1790656456769847', 'retained provider generation changed; diagnose first'
head = cloud_json(['storage', 'cat', url+'/head.json#'+str(before['generation'])])
assert head['activeTransaction'] is None and head.get('executorClaim') is None
assert head['binding'] == {'identity': fixture['context'], 'project': fixture['project']}
assert head['sequence'] == 61, 'retained fixture changed; diagnose before replay'
rows = []
for round_number in range(1, 4):
    selected = root/str(round_number)
    profile = selected/'config/nagare/contexts'/f"{fixture['context']}.env"
    profile.parent.mkdir(parents=True)
    profile.write_text(f"CLOUDSDK_CORE_PROJECT={fixture['project']}\nNAGARE_MODE=cloud\nNAGARE_INVENTORY_STORE=gcs\nNAGARE_INVENTORY_STORE_URL={url}\n")
    profile.chmod(0o600)
    local = dict(env, XDG_CONFIG_HOME=str(selected/'config'),
                 XDG_STATE_HOME=str(selected/'state'), XDG_CACHE_HOME=str(selected/'cache'))
    for temperature, budget in [('cold', 30), ('warm', 5)]:
        assert metadata() == before, 'head changed; stop before resuming'
        start = time.monotonic()
        p = subprocess.run([binary, '--context', fixture['context'], 'inventory',
                            'resume', transaction, '--yes'], env=local, cwd=selected,
                           capture_output=True, text=True, timeout=30 if temperature == 'cold' else 10)
        elapsed = time.monotonic()-start
        row = dict(round=round_number, temperature=temperature, seconds=round(elapsed, 3),
                   budgetSeconds=budget, withinBudget=elapsed < budget, exit=p.returncode,
                   converged=p.returncode == 0 and p.stdout.strip() == 'converged '+transaction)
        rows.append(row)
        print(json.dumps(row), flush=True)
        assert row['converged'], 'no-op replay refused; private output withheld'
        assert not (root/'native-calls').exists(), 'no-op unexpectedly initialized native work'
        assert metadata() == before, 'no-op changed the shared head'
        # A failed measured budget gets one diagnosis, not five more unchanged runs.
        if not row['withinBudget']:
            break
    if not rows[-1]['withinBudget']:
        break
report = dict(binarySha256=hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
              transaction=transaction, journalSequence=head['sequence'],
              headBefore=before, headAfter=metadata(), nativeCommands=0,
              copiedLocalHistory=False, globalContextChanges=0, results=rows)
(root/'result.json').write_text(json.dumps(report, indent=2)+'\n')
print('Artifacts: '+str(root))
assert len(rows) == 6 and all(row['withinBudget'] for row in rows), 'retained replay budget failed'
print('PASS: three cold/warm retained no-op pairs, independent local roots, unchanged GCS head')
