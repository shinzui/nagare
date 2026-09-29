#!/usr/bin/env python3
"""Time complete production recovery with synthetic provider observations.

Default: loopback SDK. --cloud: unique disposable prefixes in the EP-150 state
bucket, exact-generation cleanup, and a retained-head immutability check.
Requires a PruneFixture generated with MP23_PRUNE_PROJECT=tan-ng-labs for cloud.
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
from inventory_sdk_fixture import StorageFixture, GCLOUD_HELPER

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('fixture', type=Path)
parser.add_argument('probe', type=Path)
parser.add_argument('--cloud', action='store_true')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='mp23-gcs-active-'))
print('Artifacts: '+str(root), flush=True)
fixture_store = args.fixture.resolve()/'state/nagare/prune-spike/inventory'
seed = {str(p.relative_to(fixture_store)): p.read_text() for p in fixture_store.rglob('*.json')}
head = json.loads(seed['head.json'])
project = head['binding']['project']
target = json.loads((repo/'fixtures/inventory-release/gcp/ep150-target.json').read_text())
assert project == ('tan-ng-labs' if args.cloud else 'project')
bucket = target['stateBucket']
assert bucket == 'tan-ng-labs-ep150-pmkjjpp-state'
canonical = lambda value: json.dumps(value, sort_keys=True, separators=(',', ':'))
emulator = None if args.cloud else StorageFixture()
real_gcloud = shutil.which('gcloud')
base = {k: v for k, v in os.environ.items()
        if not k.startswith(('NAGARE_', 'CLOUDSDK_', 'GOOGLE_', 'PULUMI_', 'DIRENV_'))
        and k not in ['KUBECONFIG', 'XDG_CONFIG_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME']}
env = dict(base, CLOUDSDK_CORE_PROJECT=project, CLOUDSDK_ACTIVE_CONFIG_NAME=target['gcloudConfiguration'] if args.cloud else 'fixture',
           CLOUDSDK_CONFIG=os.environ.get('CLOUDSDK_CONFIG', str(Path.home()/'.config/gcloud')),
           CLOUDSDK_CORE_LOG_HTTP='false', CLOUDSDK_CORE_DISABLE_FILE_LOGGING='true', CLOUDSDK_CORE_DISABLE_PROMPTS='true')
bins = root/'bin'
bins.mkdir()
for name in ['kubectl', 'helm', 'pulumi', 'nix', 'ssh', 'docker', 'curl']:
    version = ('if [ "$#" -eq 1 ] && [ "$1" = -V ]; then exec '+shlex.quote(shutil.which('ssh'))+' -V; fi\n') if name == 'ssh' else ''
    path = bins/name
    path.write_text('#!/bin/sh\n'+version+'echo "$0" >> "$MP23_NATIVE_CALLS"\nexit 95\n')
    path.chmod(0o700)
wrapper = bins/'gcloud'
wrapper.write_text('''#!/usr/bin/env python3
import json,os,sys
args=sys.argv[1:]
with open(os.environ['MP23_CALLS'],'a') as f: f.write(json.dumps(args)+'\\n')
allowed=args[:2]==['config','config-helper'] or args[:3]==['storage','buckets','describe'] or args[:2]==['projects','describe']
if not allowed: sys.exit(95)
'''+("os.execv("+repr(real_gcloud)+", ['gcloud',*args])\n" if args.cloud else GCLOUD_HELPER+"print('12345')\n"))
wrapper.chmod(0o700)
env.update(PATH=str(bins)+os.pathsep+base['PATH'], MP23_CALLS=str(root/'commands.jsonl'), MP23_NATIVE_CALLS=str(root/'native-calls'))
if emulator:
    env['CLOUDSDK_API_ENDPOINT_OVERRIDES_STORAGE'] = emulator.endpoint
report = dict(cloud=args.cloud, probeSha256=hashlib.sha256(args.probe.read_bytes()).hexdigest(),
              runnerSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), results=[], createdGenerations=[], cleanupComplete=False)
created = set()
expected = set()
def save():
    report['createdGenerations'] = sorted(created)
    (root/'result.json').write_text(json.dumps(report, indent=2)+'\n')
def cloud(arguments, limit=30, data=None):
    return subprocess.run([real_gcloud, *arguments, '--quiet'], env=env, input=data,
                          capture_output=True, text=True, timeout=limit)
def cloud_json(arguments):
    result = cloud(arguments)
    assert result.returncode == 0, 'cloud observation failed; private output withheld'
    return json.loads(result.stdout)
def retained():
    return cloud_json(['storage', 'objects', 'describe', f'gs://{bucket}/inventory/head.json', '--raw', '--format=json(generation,size)'])
def inventory(url):
    return {row['storage_url'] for row in cloud_json(['storage', 'objects', 'list', url+'/**', '--format=json'])}
def capture_writes(url, trace):
    if not args.cloud or not trace.exists():
        return
    for line in trace.read_text().splitlines():
        call = json.loads(line)
        if call['method'] == 'put':
            generation = re.fullmatch(r'PutWritten \(Generation ([0-9]+)\)', call['outcome'])
            if generation:
                expected.add(url+'/'+call['key'])
                created.add(url+'/'+call['key']+'#'+generation[1])
before = retained() if args.cloud else None
report['retainedHeadBefore'] = before
save()
try:
    for events in [50, 500]:
        case = root/f'events-{events}'
        case.mkdir()
        url = f'gs://{bucket}/mp23-active-bench/{uuid.uuid4().hex}' if args.cloud else 'gs://audit.invalid/private'
        objects = dict(seed)
        objects['format.json'] = canonical({'version': 1, 'binding': head['binding']})
        previous = None
        for seq in range(events):
            event = json.loads(seed[f'journal/{seq:020d}.json']) if seq < 3 else dict(
                version=1, transaction='tx-'+'b'*64, operation=None, state={'tag': 'Pending'},
                timestamp='2026-09-29T00:00:00Z', detail='unrelated fixture history')
            event.update(sequence=seq, previousDigest=previous)
            value = canonical(event)
            previous = hashlib.sha256(value.encode()).hexdigest()
            objects[f'journal/{seq:020d}.json'] = value
        objects['head.json'] = canonical(dict(head, sequence=events))
        case_report = dict(events=events, url=url, fixtureSha256=hashlib.sha256(canonical(objects).encode()).hexdigest())
        report['results'].append(case_report)
        if emulator:
            emulator.reset({url+'/'+k: dict(generation=1, bytes=v) for k, v in objects.items()}, head_only=False)
        else:
            expected.update(url+'/'+k for k in objects)
            # Limit writes to this run's names. CLI read-back checks the complete
            # hash chain; setup never overwrites an existing object.
            grouped = {}
            for key, value in objects.items():
                path = case/'upload'/key
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(value)
                grouped.setdefault(str(Path(key).parent), []).append(path)
            for parent, paths in grouped.items():
                destination = url+'/'+('' if parent == '.' else parent+'/')
                try:
                    result = cloud(['storage', 'cp', *map(str, paths), destination, '--if-generation-match=0', '--print-created-message'], limit=180)
                    output, succeeded = result.stdout+result.stderr, result.returncode == 0
                except subprocess.TimeoutExpired as error:
                    output = (error.stdout or b'').decode()+(error.stderr or b'').decode()
                    succeeded = False
                (case/(parent.replace('/', '-')+'-upload.txt')).write_text(output)
                found = set(re.findall(r'gs://[^\s]+#[0-9]+', output))
                assert all(item.rsplit('#', 1)[0] in expected for item in found)
                created.update(found)
                save()
                assert succeeded, 'create-only upload failed'
            assert len(inventory(url)) == len(objects)
        print(f'{events} events seeded; bounded production driver starting', flush=True)
        started = time.monotonic()
        p = subprocess.run([str(args.probe.resolve()), str(fixture_store), url, str(case/'cache'), str(case/'trace.jsonl')],
                           env=env, text=True, capture_output=True, timeout=90)
        (case/'driver.txt').write_text(p.stdout+p.stderr)
        case_report.update(exit=p.returncode, wallSeconds=round(time.monotonic()-started, 3))
        save()
        assert p.returncode == 0, 'driver failed; inspect retained diagnostic before retry'
        result = json.loads(p.stdout)
        case_report.update(result)
        # Every write includes its exact returned generation. Retain it before
        # validation, so cleanup also works if the acceptance assertion fails.
        for call in result['calls']:
            if call['method'] == 'put':
                generation = re.fullmatch(r'PutWritten \(Generation ([0-9]+)\)', call['outcome'])
                assert generation, call
                if args.cloud:
                    expected.add(url+'/'+call['key'])
                    created.add(url+'/'+call['key']+'#'+generation[1])
        save()
        publications = [call for call in result['calls'] if call['method'] == 'put' and call['key'].startswith('journal/')]
        for seq, call in enumerate(publications, events):
            event = call['publication']
            assert event['sequence'] == seq and event['previousDigest'] == previous
            assert event['transaction'] == head['activeTransaction']
            previous = hashlib.sha256(canonical(event).encode()).hexdigest()
        assert publications[-1]['publication']['detail'] == 'transaction converged'
        assert result['finalHead']['sequence'] == events+len(publications)
        assert not (root/'native-calls').exists()
        assert sum(c['method'] == 'batch' and c['key'] == 'journal' for c in result['calls']) == 1
        if args.cloud:
            assert inventory(url) <= created, 'untracked generation in disposable prefix'
            assert retained() == before
        print(json.dumps({k: v for k, v in case_report.items() if k not in ['calls', 'finalHead']}), flush=True)
finally:
    for row in report['results']:
        capture_writes(row['url'], root/f"events-{row['events']}"/'trace.jsonl')
    save()
    if args.cloud and created:
        removed = cloud(['storage', 'rm', '--read-paths-from-stdin'], data='\n'.join(sorted(created))+'\n', limit=90)
        (root/'cleanup.txt').write_text(removed.stdout+removed.stderr)
        report['cleanupComplete'] = removed.returncode == 0 and all(not inventory(row['url']) for row in report['results'])
        report['retainedHeadAfter'] = retained()
    if emulator:
        emulator.close()
    save()
assert not args.cloud or report['cleanupComplete'] and report['retainedHeadAfter'] == before
print('PASS: complete claim/append/finalization measured; no native effects; exact-generation cleanup complete')
