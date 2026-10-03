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
elif args == ['crictl', 'pods', '-o', 'json']:
    if fixture['pods'] is None: sys.exit(6)
    print(json.dumps({'items': fixture['pods']}))
elif args[:4] == ['crictl', 'inspectp', '-o', 'json']:
    info = fixture['sandboxes'].get(args[4])
    if info is None: sys.exit(5)
    print(json.dumps({'status': {'id': args[4]}, 'info': info}))
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
    config = root / 'config.toml'
    env = dict(os.environ, PATH=tmp + ':' + os.environ['PATH'], FIXTURE=tmp, INSTANCE='123',
               NAGARE_CONTAINERD_CONFIG=str(config))
    PAUSE = 'sha256:' + 'c' * 64
    SANDBOX = 'd' * 64
    PINNED = "[plugins.'io.containerd.cri.v1.images'.pinned_images]\n  sandbox = \"rancher/mirrored-pause:3.6\"\n"
    BASE = {'rancher/mirrored-pause:3.6': PAUSE}
    def write(images, containers, resolved, pods, sandboxes, configured):
        (root / 'input.json').write_text(json.dumps({'images': images, 'containers': containers or [],
                                                     'resolved': dict(BASE, **(resolved or {})),
                                                     'pods': pods, 'sandboxes': sandboxes}))
        config.write_text(configured)
    def run(images, containers=None, resolved=None, instance='123', success=False, absent=False,
            pods=(), sandboxes=None, configured=PINNED):
        write(images, containers, resolved, list(pods) if pods is not None else None, sandboxes or {}, configured)
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
    # F32: an image used only by a pod sandbox (Ready or retained) is protected,
    # even when CRI reports it unpinned.
    pod = {'id': SANDBOX, 'state': 'SANDBOX_NOTREADY'}
    run([image], pods=[pod], sandboxes={SANDBOX: {'image': 'docker.io/rancher/mirrored-pause:3.10.2'}},
        resolved={'docker.io/rancher/mirrored-pause:3.10.2': IMAGE})
    run([image], pods=[dict(pod, state='SANDBOX_READY')], sandboxes={SANDBOX: {'image': 'pause-ref'}},
        resolved={'pause-ref': IMAGE})
    # The configured sandbox image is protected without any running sandbox.
    run([image], resolved={'rancher/mirrored-pause:3.6': IMAGE})
    run([image], configured='[plugins."io.containerd.grpc.v1.cri"]\n  sandbox_image = "legacy-pause"\n',
        resolved={'legacy-pause': IMAGE})
    # Missing or ambiguous sandbox observations refuse the whole capture.
    run([image], pods=None)
    run([image], pods=[pod], sandboxes={})
    run([image], pods=[pod], sandboxes={SANDBOX: {}})
    run([image], pods=[{'state': 'SANDBOX_READY'}])
    run([image], configured='')
    run([image], configured=PINNED + '  sandbox_image = "other-pause"\n')
    run([image], pods=[pod], sandboxes={SANDBOX: {'image': 'unresolvable'}})
    # An ordinary unused image is still removed beside protected sandboxes.
    run([image], pods=[pod], sandboxes={SANDBOX: {'image': 'docker.io/rancher/mirrored-pause:3.10.2'}},
        resolved={'docker.io/rancher/mirrored-pause:3.10.2': OTHER}, success=True)
    # Inspection reports sandbox and configured images as used, so review never selects them.
    write([image, dict(image, id=PAUSE, repoTags=['pause:a'])], [], {'sandbox-ref': IMAGE}, [pod],
          {SANDBOX: {'image': 'sandbox-ref'}}, PINNED)
    inspected = subprocess.run(['bash', '-c', SCRIPT, 'protocol', 'inspect', '123'], env=env, text=True,
                               capture_output=True, check=True)
    assert sorted(json.loads(inspected.stdout)['cacheUsedIds']) == sorted([IMAGE, PAUSE]), inspected.stdout
    print('23 production image-cache protocol cases passed')
