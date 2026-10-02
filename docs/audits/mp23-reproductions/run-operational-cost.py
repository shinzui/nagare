#!/usr/bin/env python3
"""Run source-bound offline probes; keep artifacts and exact source hashes."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

repo = Path(__file__).resolve().parents[3]
root = Path(tempfile.mkdtemp(prefix='mp23-operational-cost-'))
source = repo / 'cli/nagarectl/src/Nagare/Inventory/Execute.hs'
overlay = root / 'overlay/Nagare/Inventory/Execute.hs'
overlay.parent.mkdir(parents=True)
body = source.read_text()
assert body.startswith('{-#') and 'module Nagare.Inventory.Execute\n  ( AdmissionError (..)' in body
# Execute is now a facade; appendEvent lives in the extracted journal module.
body = body.replace('import Nagare.Dsl.Prelude', 'import Nagare.Inventory.Execute.Journal (appendEvent)\nimport Nagare.Dsl.Prelude', 1)
overlay.write_text(body.replace('  ( AdmissionError (..)', '  ( appendEvent\n  , AdmissionError (..)', 1))
status_source = repo / 'cli/nagarectl/src/Nagare/Inventory/Status.hs'
status_body = status_source.read_text()
assert status_body.count('  , loadRetainedNative') == 1
(root / 'overlay/Nagare/Inventory/Status.hs').write_text(
    status_body.replace('  , loadRetainedNative', '  , sameNativeBinding\n  , loadRetainedNative', 1))
(root / 'overlay/OperationalHelpers.hs').write_text(
    Path(__file__).with_name('OperationalCost.hs').read_text().replace(
        'module Main where', 'module OperationalHelpers where', 1))
(root / 'overlay/NativeHelpers.hs').write_text(
    Path(__file__).with_name('NativeEvidence.hs').read_text().replace(
        'module Main where', 'module NativeHelpers where', 1))
(root / 'overlay/PruneHelpers.hs').write_text(
    Path(__file__).with_name('PruneFixture.hs').read_text().replace(
        'module Main where', 'module PruneHelpers where', 1))
plan_source = repo / 'cli/nagarectl/src/Nagare/Inventory/Plan.hs'
plan_body = plan_source.read_text()
assert plan_body.count('  , ReviewBundle\n') == 1
(root / 'overlay/Nagare/Inventory/Plan.hs').write_text(
    plan_body.replace('  , ReviewBundle\n', '  , ReviewBundle (..)\n', 1))
# Match Cabal's explicit memory dependency when the interactive environment also
# exposes ram. Only import qualification changes in these temporary copies.
for relative in ['Nagare/Env/Store.hs', 'Nagare/Static/Webhook.hs',
                 'Nagare/Inventory/Backup.hs', 'Nagare/Inventory/BackupReceipt.hs', 'Nagare/Database/Secret.hs']:
    original = repo / 'cli/nagarectl/src' / relative
    target = root / 'overlay' / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(original.read_text().replace('import Data.ByteArray', 'import "memory" Data.ByteArray'))
(root / 'bin').mkdir()
(root / 'objects').mkdir()
fake = root / 'bin/gcloud'
shutil.copyfile(Path(__file__).with_name('fake-gcloud.py'), fake)
fake.chmod(0o700)
env = dict(os.environ, PATH=str(root / 'bin') + os.pathsep + os.environ['PATH'],
           MP23_CALLS=str(root / 'calls.jsonl'), MP23_OBJECTS=str(root / 'objects'),
           MP23_CACHE=str(root / 'cache'), MP23_PROTOCOL_ROOT=str(root), MP23_PRUNE_ROOT=str(root),
           XDG_CONFIG_HOME=str(root / 'config'), XDG_STATE_HOME=str(root / 'state'))
command = ['cabal', 'exec', '--', 'runghc', '-package=nagare-dsl-0.4.0', '-XPackageImports', '-XGHC2024',
           '-XDeriveAnyClass', '-XDuplicateRecordFields', '-XOverloadedLabels',
           '-XOverloadedStrings', '-i' + str(root / 'overlay'), '-isrc', '-itest',
           str(Path(__file__).with_name('OperationalCost.hs'))]
hashes = {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest()
          for p in [source, *(repo / 'cli/nagarectl/src/Nagare/Inventory').glob('*.hs'),
                    repo / 'cli/nagarectl/src/Nagare/Inventory/Store/ObjectOps.hs']}
(root / 'source-hashes.json').write_text(json.dumps(hashes, indent=2) + '\n')
probe_hashes = {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest()
               for p in Path(__file__).parent.iterdir() if p.suffix in {'.py', '.hs'}}
(root / 'probe-hashes.json').write_text(json.dumps(probe_hashes, indent=2) + '\n')
print(f'Artifacts: {root}', flush=True)
probes = [('history', []), ('transport', ['transport']), ('snapshot', ['snapshot']), ('recovery', []),
          ('replay', ['-p', '/journal replay/ || /active status/ || /active resume/ || /converged replay/ || /lost journal/']),
          ('native', []), ('protocol', []), ('prune-fixture', []), ('prune-executor', []), ('prune-executor-cf', []), ('prune-executor-fixed', [])]
if len(sys.argv) > 1:
    assert set(sys.argv[1:]) <= {label for label, _ in probes}, 'unknown probe'
    probes = [(label, args) for label, args in probes if label in sys.argv[1:]]
for label, extra in probes:
    env['MP23_PROBE'] = label
    execute_body = body.replace('  ( AdmissionError (..)', '  ( appendEvent\n  , AdmissionError (..)', 1)
    if label in {'prune-executor-cf', 'prune-executor-fixed'}:
        before = 'preflightErrors <- preflightOperations registry reviewed (operationStates transaction events)'
        assert execute_body.count(before) == 1
        execute_body = execute_body.replace(before, 'preflightErrors <- pure []')
    if label == 'prune-executor-fixed':
        before = '                      RecoveryUnresolved _ ->\n'
        assert execute_body.count(before) == 1
        execute_body = execute_body.replace(before,
            '                      RecoveryTerminalFailure _ -> pure (Just (StoppedAmbiguous transaction (plannedOperationId operation)))\n' + before)
    overlay.write_text(execute_body)
    started = time.monotonic()
    objects = root / ('objects-' + label)
    objects.mkdir()
    env['MP23_OBJECTS'] = str(objects)
    fixture_root = root / ('fixture-' + label)
    fixture_root.mkdir()
    env['MP23_PRUNE_ROOT'] = str(fixture_root)
    script = {'recovery': 'RecoveryBoundary.hs', 'replay': 'ReplayChecks.hs',
              'native': 'NativeEvidence.hs', 'protocol': 'EvidenceProtocol.hs', 'prune-fixture': 'PruneFixture.hs',
              'prune-executor': 'PruneExecutor.hs', 'prune-executor-cf': 'PruneExecutor.hs', 'prune-executor-fixed': 'PruneExecutor.hs'}.get(label)
    selected = command if script is None else command[:-1] + [str(Path(__file__).with_name(script))]
    result = subprocess.run(selected + extra, cwd=repo / 'cli/nagarectl', env=env,
                            text=True, capture_output=True, timeout=90)
    (root / (label + '.txt')).write_text(result.stdout + result.stderr)
    print(f'{label}: exit={result.returncode}, elapsed={time.monotonic()-started:.2f}s', flush=True)
    print(result.stdout + result.stderr, flush=True)
    if result.returncode:
        raise SystemExit(result.returncode)
assert all(hashlib.sha256((repo / path).read_bytes()).hexdigest() == digest
           for path, digest in hashes.items()), 'production source changed during experiment'
