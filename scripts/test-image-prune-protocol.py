#!/usr/bin/env python3
"""Exercise the shipped remote protocol with CRI/metadata boundaries substituted."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'cli/nagarectl/src/Nagare/Inventory/ImagePruneScript.hs'
# The production source is a fixed T.unlines list of JSON-compatible literals.
SCRIPT = '\n'.join(json.loads(line.lstrip()[2:]) for line in SOURCE.read_text().splitlines()
                   if line.lstrip().startswith(('[ "', ', "'))) + '\n'
IMAGE = 'sha256:' + 'a' * 64
OTHER = 'sha256:' + 'b' * 64
with tempfile.TemporaryDirectory(prefix='mp23-image-protocol-') as tmp:
    root = Path(tmp)
    (root / 'curl').write_text('#!/bin/sh\nprintf "%s" "$INSTANCE"\n')
    (root / 'k3s').write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ['FIXTURE'])
args = sys.argv[1:]
fixture = json.loads((root / 'input.json').read_text())
if args == ['crictl', 'images', '-o', 'json']:
    print(json.dumps({'images': fixture['images']}))
elif args == ['crictl', 'ps', '-a', '-o', 'json']:
    print(json.dumps({'containers': fixture['containers']}))
elif args[:2] == ['crictl', 'inspecti']:
    identity = fixture['resolved'].get(args[2])
    if identity is None: sys.exit(7)
    print(json.dumps({'status': {'id': identity}}))
elif args[:2] == ['crictl', 'rmi']:
    with (root / 'writes').open('a') as out: out.write(json.dumps(args) + '\\n')
else: sys.exit(9)
''')
    for name in ('curl', 'k3s'):
        (root / name).chmod(0o755)
    env = dict(os.environ, PATH=tmp + ':' + os.environ['PATH'], FIXTURE=tmp, INSTANCE='123')
    def run(images, containers=None, resolved=None, instance='123', success=False, absent=False):
        (root / 'input.json').write_text(json.dumps({'images': images, 'containers': containers or [], 'resolved': resolved or {}}))
        (root / 'writes').write_text('')
        result = subprocess.run(['bash', '-c', SCRIPT, 'protocol', 'remove', instance, IMAGE, '["fixture:a","fixture:b"]'],
                                env=env, text=True, capture_output=True)
        assert (result.returncode == 0) == success, (result.returncode, result.stderr)
        writes = (root / 'writes').read_text()
        assert writes == (json.dumps(['crictl', 'rmi', IMAGE]) + '\n' if success and not absent else ''), writes
    image = {'id': IMAGE, 'repoTags': ['fixture:b', 'fixture:a'], 'repoDigests': [], 'pinned': False}
    run([image], success=True)
    run([image], instance='999')
    run([dict(image, pinned=True)])
    run([dict(image, repoTags=['changed'])])
    run([image, dict(image, id=OTHER)])
    container = {'image': {'image': 'mutable:tag'}, 'imageRef': 'digest-reference'}
    run([image], [container], {'mutable:tag': IMAGE, 'digest-reference': IMAGE})
    run([image], [container], {'mutable:tag': OTHER, 'digest-reference': IMAGE})
    run([image], [container], {'mutable:tag': OTHER})
    run([], success=True, absent=True)
    run([image], [{'image': {}}])
    print('10 production image-cache protocol cases passed')
