#!/usr/bin/env python3
"""Public bootstrap authority refusal matrix; SDK loopback, no provider writes."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
from inventory_sdk_fixture import StorageFixture, GCLOUD_HELPER

repo = Path(__file__).resolve().parents[1]
binary = subprocess.check_output(['cabal', 'list-bin', 'exe:nagarectl'], cwd=repo/'cli/nagarectl', text=True).strip()
root = Path(tempfile.mkdtemp(prefix='mp23-bootstrap-discovery-'))
bins = root/'bin'; bins.mkdir()
(bins/'gcloud').write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
args=sys.argv[1:]
with open(os.environ['MP23_CALLS'],'a') as f: f.write(json.dumps(args)+'\\n')
''' + GCLOUD_HELPER + '''
if args[:2]==['projects','describe']: print('12345')
else: sys.exit(95)
''')
(bins/'gcloud').chmod(0o700)
canonical = lambda value: json.dumps(value, sort_keys=True, separators=(',', ':'))
binding = {'identity': 'audit', 'project': 'project'}
head = {'version': 1, 'generation': 0, 'sequence': 0, 'binding': binding,
        'clientIdentity': 'fixture', 'accepted': [], 'converged': [],
        'activeTransaction': None, 'executorClaim': None}
format_value = {'version': 1, 'binding': binding}
member = lambda value: {'generation': 1, 'bytes': canonical(value)}
format_key = 'gs://audit.invalid/private/format.json'
head_key = 'gs://audit.invalid/private/head.json'
base = {k: os.environ[k] for k in ['PATH', 'USER'] if k in os.environ}
emulator = StorageFixture()
results = []

cases = [
 ('owned-history', {format_key: member(format_value), head_key: member(head)}, {}, True),
 ('missing-bucket', {}, {'bucket_status': 404}, True),
 ('empty-owned-prefix', {}, {}, True),
 ('foreign-bucket', {}, {'bucket_owner': '99999'}, False),
 ('denied-bucket', {}, {'bucket_status': 403}, False),
 ('unavailable-bucket', {}, {'bucket_status': 503}, False),
 ('missing-format-remaining-head', {head_key: member(head)}, {}, False),
 ('format-no-head', {format_key: member(format_value)}, {}, False),
 ('foreign-format', {format_key: member(dict(format_value, binding=dict(binding, identity='other')))}, {}, False),
 ('foreign-head', {format_key: member(format_value), head_key: member(dict(head, binding=dict(binding, identity='other')))}, {}, False),
 ('active-writer', {format_key: member(format_value), head_key: member(dict(head,
    activeTransaction='tx-active', executorClaim={'transaction': 'tx-active', 'clientIdentity': 'other', 'epoch': 1, 'timestamp': '2026-09-29T00:00:00Z'}))}, {}, True),
 ('migrated-remote', {format_key: member(format_value), head_key: member(dict(head,
    migration={'destination': 'gs://different/private', 'headDigest': hashlib.sha256(b'old').hexdigest()}))}, {}, False),
 ('future-head', {format_key: member(format_value), head_key: member({'version': 2})}, {}, False),
 ('partial-list', {}, {'partial_listing': True}, False),
 ('denied-format', {}, {'denied_objects': True}, False),
 ('local-conflict', {format_key: member(format_value), head_key: member(head)}, {}, False),
 ('wrong-migration', {format_key: member(format_value), head_key: member(head)}, {}, False),
 ('missing-migrated-destination', {}, {'bucket_status': 404}, False),
]
try:
 for transport in ['gogol', 'gcloud']:
  for label, objects, settings, selects in cases:
   case = root/(transport+'-'+label)
   profile = case/'config/nagare/contexts/audit.env'; profile.parent.mkdir(parents=True)
   profile.write_text('CLOUDSDK_CORE_PROJECT=project\nNAGARE_MODE=cloud\nNAGARE_INVENTORY_STORE=gcs\nNAGARE_INVENTORY_STORE_URL=gs://audit.invalid/private\n')
   calls = case/'calls.jsonl'; calls.write_text('')
   env = dict(base, HOME=str(case/'home'), PATH=str(bins)+os.pathsep+base['PATH'],
     XDG_CONFIG_HOME=str(case/'config'), XDG_STATE_HOME=str(case/'state'), XDG_CACHE_HOME=str(case/'cache'),
     CLOUDSDK_API_ENDPOINT_OVERRIDES_STORAGE=emulator.endpoint, NAGARE_INVENTORY_GCS_TRANSPORT=transport,
     NAGARE_PLATFORM_ROOT=str(case/'missing-workspace'), MP23_CALLS=str(calls))
   local = case/'state/nagare/audit/inventory/head.json'
   if label in ['local-conflict', 'wrong-migration', 'missing-migrated-destination']:
    local.parent.mkdir(parents=True)
    value = dict(head, generation=1)
    if label != 'local-conflict':
     value['migration'] = {'destination': 'gs://wrong/private' if label == 'wrong-migration' else 'gs://audit.invalid/private',
                           'headDigest': hashlib.sha256(b'old').hexdigest()}
    local.write_text(canonical(value)); local.chmod(0o600); local.parent.chmod(0o700)
   original = local.read_bytes() if local.exists() else None
   emulator.reset(objects)
   emulator.bucket_status, emulator.bucket_owner, emulator.partial_listing, emulator.denied_objects = 200, '12345', False, False
   for key, value in settings.items(): setattr(emulator, key, value)
   p = subprocess.run([binary, '--context', 'audit', 'platform', 'bootstrap', 'plan', '--out', str(case/'review')],
       env=env, cwd=case, capture_output=True, text=True, timeout=25)
   # The deliberate missing payload distinguishes successful authority selection
   # from a refusal before unrelated provider/workspace setup.
   selected = 'missing-workspace' in p.stderr
   assert p.returncode != 0 and selected == selects, (transport, label, p.stderr)
   assert all(c['method']=='GET' for c in emulator.calls), emulator.calls
   assert (local.read_bytes() if local.exists() else None) == original
   assert not (case/'cache').exists() and not (case/'review').exists()
   commands = [json.loads(line) for line in calls.read_text().splitlines()]
   assert all(a[:2] in [['config','config-helper'], ['projects','describe']] for a in commands), commands
   if not selects or label == 'active-writer':
    recovery = subprocess.run([binary, '--context', 'audit', 'kubeconfig', 'recover'],
       env=env, cwd=case, capture_output=True, text=True, timeout=25)
    assert recovery.returncode != 0 and 'missing-workspace' not in recovery.stderr
    assert (local.read_bytes() if local.exists() else None) == original
   results.append({'transport': transport, 'case': label, 'selected': selected,
                   'exit': p.returncode, 'http': list(emulator.calls), 'stderr': p.stderr})
 (root/'results.json').write_text(json.dumps(results, indent=2)+'\n')
 print(f'PASS: {len(results)} public authority cases, no head/cache/provider writes; artifacts {root}')
finally:
 emulator.close()
