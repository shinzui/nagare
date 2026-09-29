#!/usr/bin/env python3
"""Bounded, read-only comparison; never retain credentials or object content."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

PROJECT = 'tan-ng-labs'
URL = 'gs://tan-ng-labs-ep150-pmkjjpp-state/inventory/head.json'
ENV = {k: v for k, v in os.environ.items()
       if not k.startswith(('NAGARE_', 'CLOUDSDK_', 'PULUMI_', 'GOOGLE_', 'DIRENV_', 'XDG_'))
       and k != 'KUBECONFIG'}
ENV.update(CLOUDSDK_CORE_PROJECT=PROJECT, CLOUDSDK_CORE_DISABLE_PROMPTS='1')


def run(args, *, stdin=None, timeout=20):
    started = time.monotonic()
    result = subprocess.run(args, input=stdin, capture_output=True, env=ENV, timeout=timeout)
    if result.returncode:
        # In particular do not print SDK errors, which may contain auth headers.
        raise RuntimeError(f'{args[0]} exited {result.returncode}; output suppressed')
    return result.stdout, time.monotonic() - started


def baseline():
    started = time.monotonic()
    describe = ['gcloud', 'storage', 'objects', 'describe', URL,
                '--project=' + PROJECT, '--format=value(generation)', '--quiet']
    first, _ = run(describe)
    with tempfile.TemporaryDirectory(prefix='mp23-gogol-baseline-') as tmp:
        path = Path(tmp) / 'head'
        run(['gcloud', 'storage', 'cp', URL, str(path), '--project=' + PROJECT, '--quiet'])
        body = path.read_bytes()
    last, _ = run(describe)
    assert first.strip() == last.strip(), 'head changed during baseline'
    return dict(seconds=time.monotonic() - started, generation=int(first),
                bytes=len(body), sha256=hashlib.sha256(body).hexdigest(), subprocesses=3)


def main():
    binary = str(Path(sys.argv[1]).resolve())
    wire, _ = run([binary, 'wire'])
    results = {'target': URL, 'project': PROJECT, 'wire': json.loads(wire), 'rounds': []}
    for index in range(3):
        before = baseline()
        token, auth_seconds = run(['gcloud', 'auth', 'print-access-token', '--project=' + PROJECT])
        output, elapsed = run([binary, 'read'], stdin=token, timeout=30)
        del token
        probe = json.loads(output)
        for read in probe['reads']:
            assert all(read[k] == before[k] for k in ('generation', 'bytes', 'sha256'))
        results['rounds'].append(dict(baseline=before, gogol=probe,
                                     auth_seconds=auth_seconds, gogol_process_seconds=elapsed))
        print(f'round {index + 1}/3 passed', file=sys.stderr, flush=True)
    results['binary_sha256'] = hashlib.sha256(Path(binary).read_bytes()).hexdigest()
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    main()
