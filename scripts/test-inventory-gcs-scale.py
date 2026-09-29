#!/usr/bin/env python3
"""Validate a synthetic committed history locally, then measure real GCS replay.

Default is local-only. --cloud creates 502 create-only objects in a unique
disposable prefix, measures the public CLI, and removes only recorded generations.
The retained inventory and native executors are never mutation targets.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cloud', action='store_true')
    parser.add_argument('--journal-probe', type=Path, help='Compiled GcsJournalTiming.hs executable')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    binary = subprocess.check_output(['cabal', 'list-bin', 'exe:nagarectl', '--enable-tests'],
                                     cwd=repo/'cli/nagarectl', text=True).strip()
    target = json.loads((repo/'fixtures/inventory-release/gcp/ep150-target.json').read_text())
    root = Path(tempfile.mkdtemp(prefix='mp23-gcs-scale-'))
    print('Artifacts: '+str(root), flush=True)
    nonce = uuid.uuid4().hex
    context = 'mp23-scale-'+nonce[:8]
    project, bucket = target['project'], target['stateBucket']
    assert project == 'tan-ng-labs' and bucket == 'tan-ng-labs-ep150-pmkjjpp-state'
    prefix = 'mp23-replay-bench/'+nonce+'/events-500'
    url = f'gs://{bucket}/{prefix}'
    tx = 'tx-'+hashlib.sha256(('gcs-scale-'+nonce).encode()).hexdigest()
    canonical = lambda value: json.dumps(value, sort_keys=True, separators=(',', ':'))
    binding = {'identity': context, 'project': project}
    objects = {'format.json': canonical({'version': 1, 'binding': binding}),
               'head.json': canonical({'version': 1, 'generation': 1, 'sequence': 500,
                                      'binding': binding, 'clientIdentity': 'fixture',
                                      'accepted': [], 'converged': [],
                                      'activeTransaction': None, 'executorClaim': None})}
    previous = None
    for sequence in range(500):
        event = canonical({'version': 1, 'sequence': sequence, 'previousDigest': previous,
                           'transaction': tx, 'operation': None, 'state': {'tag': 'Pending'},
                           'timestamp': '2026-09-29T00:00:00Z',
                           'detail': 'transaction converged' if sequence == 499 else 'fixture history'})
        objects[f'journal/{sequence:020d}.json'] = event
        previous = hashlib.sha256(event.encode()).hexdigest()
    base = {k: v for k, v in os.environ.items()
            if not k.startswith(('NAGARE_', 'CLOUDSDK_', 'GOOGLE_', 'PULUMI_', 'DIRENV_'))
            and k not in ['KUBECONFIG', 'XDG_CONFIG_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME']}
    bins = root/'bin'
    bins.mkdir()
    for name in ['kubectl', 'helm', 'pulumi', 'nix', 'ssh', 'docker', 'curl']:
        version = ''
        if name == 'ssh':
            version = ('if [ "$#" -eq 1 ] && [ "$1" = "-V" ]; then exec '
                       + shlex.quote(shutil.which('ssh'))+' -V; fi\n')
        path = bins/name
        path.write_text('#!/bin/sh\n'+version+'printf "%s\\n" "$0" >> "$MP23_NATIVE_CALLS"\nexit 95\n')
        path.chmod(0o700)
    calls = root/'gcloud-calls.jsonl'
    gcloud = shutil.which('gcloud')
    assert gcloud
    # CLI commands may only acquire credentials and check ownership via gcloud.
    # Bulk fixture setup/cleanup calls the original executable separately.
    wrapper = bins/'gcloud'
    wrapper.write_text('''#!/usr/bin/env python3
import json,os,sys
args=sys.argv[1:]
with open(os.environ['MP23_CALLS'],'a') as f: f.write(json.dumps(args)+'\\n')
allowed=args[:2]==['config','config-helper'] or args[:3]==['storage','buckets','describe'] or args[:2]==['projects','describe']
if not allowed: sys.exit(95)
os.execv('''+repr(gcloud)+''', ['gcloud',*args])
''')
    wrapper.chmod(0o700)
    env = dict(base, PATH=str(bins)+os.pathsep+base['PATH'],
               CLOUDSDK_CONFIG=os.environ.get('CLOUDSDK_CONFIG', str(Path.home()/'.config/gcloud')),
               CLOUDSDK_CORE_PROJECT=project, CLOUDSDK_ACTIVE_CONFIG_NAME=target['gcloudConfiguration'],
               CLOUDSDK_CORE_LOG_HTTP='false', CLOUDSDK_CORE_DISABLE_FILE_LOGGING='true',
               CLOUDSDK_CORE_DISABLE_PROMPTS='true', MP23_CALLS=str(calls),
               MP23_NATIVE_CALLS=str(root/'native-calls'), NAGARE_PLATFORM_ROOT=str(root/'no-workspace'))

    def profile(selected, kind):
        path = selected/'config/nagare/contexts'/f'{context}.env'
        path.parent.mkdir(parents=True)
        path.write_text(f'CLOUDSDK_CORE_PROJECT={project}\nNAGARE_MODE=cloud\nNAGARE_INVENTORY_STORE={kind}\nNAGARE_INVENTORY_STORE_URL={url}\n')
        path.chmod(0o600)
        return dict(env, XDG_CONFIG_HOME=str(selected/'config'), XDG_STATE_HOME=str(selected/'state'),
                    XDG_CACHE_HOME=str(selected/'cache'))

    local = root/'local'
    local_env = profile(local, 'local')
    store = local/'state/nagare'/context/'inventory'
    for key, value in objects.items():
        path = store/key
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value)
        path.chmod(0o600)
    calls.write_text('')
    command = [binary, '--context', context, 'inventory', 'resume', tx, '--yes']
    checked = subprocess.run(command, env=local_env, cwd=local, capture_output=True, text=True, timeout=10)
    assert checked.returncode == 0 and checked.stdout.strip() == 'converged '+tx, checked.stderr
    assert not calls.read_text() and not (root/'native-calls').exists()
    assert all((store/key).read_text() == value for key, value in objects.items())
    report = dict(binarySha256=hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
                  runnerSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), cloud=args.cloud,
                  sourceRevision=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip(),
                  context=context, project=project, url=url, transaction=tx, events=500,
                  objectCount=len(objects), fixtureBytes=sum(len(v.encode()) for v in objects.values()),
                  fixtureSha256=hashlib.sha256(canonical(objects).encode()).hexdigest(),
                  localValidation=True, results=[], createdGenerations=[], cleanupComplete=False)
    def save():
        (root/'result.json').write_text(json.dumps(report, indent=2)+'\n')
    save()
    print('PASS: local 500-event hash chain converges without provider commands', flush=True)
    if not args.cloud:
        return

    def cloud(arguments, *, limit=20, data=None):
        return subprocess.run([gcloud, *arguments, '--quiet'], env=env, cwd=root,
                              input=data, capture_output=True, text=True, timeout=limit)

    def cloud_json(arguments):
        p = cloud(arguments)
        if p.returncode:
            raise RuntimeError('GCS observation failed; private diagnostic withheld')
        return json.loads(p.stdout)

    def retained_head():
        return cloud_json(['storage', 'objects', 'describe', f'gs://{bucket}/inventory/head.json',
                           '--raw', '--format=json(generation,size)'])

    def inventory():
        rows = cloud_json(['storage', 'objects', 'list', url+'/**', '--format=json'])
        return {row['storage_url']: row['size'] for row in rows}

    before = retained_head()
    owner = cloud_json(['storage', 'buckets', 'describe', f'gs://{bucket}', '--raw', '--format=json(projectNumber)'])
    selected = cloud_json(['projects', 'describe', project, '--format=json(projectNumber)'])
    assert str(owner['projectNumber']) == str(selected['projectNumber'])
    report['retainedHeadBefore'] = before
    created = set()
    expected = {url+'/'+key for key in objects}

    def upload(paths, destination):
        try:
            p = cloud(['storage', 'cp', *map(str, paths), destination, '--if-generation-match=0',
                       '--print-created-message'], limit=180)
            output = p.stdout+p.stderr
            succeeded = p.returncode == 0
        except subprocess.TimeoutExpired as error:
            output = (error.stdout or b'').decode()+(error.stderr or b'').decode()
            succeeded = False
        with (root/'uploads.txt').open('a') as log:
            log.write(output)
        found = set(re.findall(r'gs://[^\s]+#[0-9]+', output))
        assert all(item.rsplit('#', 1)[0] in expected for item in found), 'unexpected upload target'
        created.update(found)
        report['createdGenerations'] = sorted(created)
        save()
        assert succeeded, 'fixture upload failed; preserve recorded generations for cleanup'

    try:
        # Two small objects validate upload output/target shape before the batch.
        upload([store/'format.json', store/'head.json'], url+'/')
        assert len(created) == 2 and set(inventory()) == created
        print('PASS: create-only upload and exact-generation manifest preflight', flush=True)
        upload(sorted((store/'journal').glob('*.json')), url+'/journal/')
        expected_sizes = {item: len(objects[item.rsplit('#', 1)[0].removeprefix(url+'/')].encode()) for item in created}
        assert len(created) == 502 and inventory() == expected_sizes
        print('PASS: 502 exact object generations uploaded; starting bounded replay', flush=True)
        for round_number in range(1, 4):
            selected = root/f'round-{round_number}'
            local_env = profile(selected, 'gcs')
            for temperature, budget in [('cold', 60), ('warm', 10)]:
                calls.write_text('')
                start = time.monotonic()
                p = subprocess.run(command, env=local_env, cwd=selected, capture_output=True,
                                   text=True, timeout=budget+5)
                elapsed = time.monotonic()-start
                commands = [json.loads(line) for line in calls.read_text().splitlines()]
                row = dict(round=round_number, temperature=temperature, seconds=round(elapsed, 3),
                           budgetSeconds=budget, withinBudget=elapsed < budget, exit=p.returncode,
                           converged=p.returncode == 0 and p.stdout.strip() == 'converged '+tx,
                           gcloudProcesses=len(commands))
                report['results'].append(row)
                save()
                print(json.dumps(row), flush=True)
                assert row['converged'], 'replay failed; diagnose before another run'
                assert len(commands) == 3 and not (root/'native-calls').exists()
                assert inventory() == expected_sizes, 'replay changed an object generation'
                assert retained_head() == before, 'retained history changed'
                row['generationsUnchanged'] = True
                save()
                assert row['withinBudget'], 'replay exceeded budget; diagnose before another run'
            if args.journal_probe:
                calls.write_text('')
                p = subprocess.run([str(args.journal_probe.resolve()), project, url], env=local_env,
                                   cwd=selected, capture_output=True, text=True, timeout=60)
                assert p.returncode == 0, 'isolated journal probe failed'
                timing = json.loads(p.stdout)
                assert timing['objects'] == 500
                assert timing['bytes'] == sum(len(v.encode()) for k, v in objects.items() if k.startswith('journal/'))
                assert len(calls.read_text().splitlines()) == 3
                timing['round'] = round_number
                report.setdefault('journalTimings', []).append(timing)
                save()
                print(json.dumps(timing), flush=True)
        report['allGenerationsUnchanged'] = True
    finally:
        # No recursive/bucket deletion: only generations named by create output.
        if created:
            p = cloud(['storage', 'rm', '--read-paths-from-stdin'], limit=180,
                      data='\n'.join(sorted(created))+'\n')
            (root/'cleanup.txt').write_text(p.stdout+p.stderr)
            report['cleanupExit'] = p.returncode
            report['cleanupComplete'] = p.returncode == 0 and inventory() == {}
        report['retainedHeadAfter'] = retained_head()
        save()
    assert report['cleanupComplete'] and report['retainedHeadAfter'] == before
    print('PASS: real GCS 500-event cold/warm replay, immutable generations, exact cleanup', flush=True)


if __name__ == '__main__':
    main()
