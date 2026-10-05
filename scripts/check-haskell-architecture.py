#!/usr/bin/env python3
"""Check maintained library/test module boundaries and ratchet existing size debt."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
PACKAGES = ('nagare-dsl', 'nagarectl', 'nagare-access', 'nagare-harness')
PRIVATE = ('Nagare.Inventory.Application.', 'Nagare.Inventory.Plan.',
           'Nagare.Inventory.Execute.', 'Nagare.Dsl.Load.')
OPAQUE = {
    'Nagare.Inventory.Application': ('DatabaseBinding',),
    'Nagare.Inventory.Plan': ('InventoryHistory', 'ObservationRequirements',
        'LifecycleDecisions', 'ChangeProposal', 'ReviewBundle', 'ReviewedPlan'),
    'Nagare.Inventory.Execute': ('ExecutablePlan',),
}
PURE_PLAN = {'Types', 'Changes', 'Lifecycle', 'Observation', 'Validation'}
EFFECT_PLAN = {'History', 'Prepare', 'Publication', 'MigrationObservation'}


def source_modules(root: Path):
    for package in PACKAGES:
        for area in ('src', 'test'):
            for path in sorted((root / 'cli' / package / area).rglob('*.hs')):
                if {'fixtures', 'negative'} & set(path.parts):
                    continue
                yield package, area, path


def section(source: str, start: str) -> str:
    match = re.search(r'^' + re.escape(start) + r'\s*\n', source, re.M)
    if not match:
        return ''
    rest = source[match.end():]
    end = re.search(r'^[a-z][\w-]*(?:\s+[^\n]+)?\n', rest, re.M)
    return rest[:end.start()] if end else rest


def module_field(component: str, name: str) -> set[str]:
    match = re.search(r'^  ' + name + r':\s*\n((?:    [^\n]*\n|\n)*)', component, re.M)
    return set(re.findall(r'^    ([A-Z][\w.]*)\s*$', match[1], re.M)) if match else set()


def check(root: Path, limits: dict[str, int]) -> list[str]:
    errors = []
    sources = {}
    components = {}
    for package in PACKAGES:
        cabal = root / 'cli' / package / (package + '.cabal')
        text = cabal.read_text()
        library = section(text, 'library')
        test = section(text, 'test-suite ' + package + '-test')
        exposed = module_field(library, 'exposed-modules')
        for name in exposed:
            if name.startswith(PRIVATE):
                errors.append(f'{package}: implementation module exposed: {name}')
        components[package] = (exposed | module_field(library, 'other-modules'),
                               module_field(test, 'other-modules'))
    for package, area, path in source_modules(root):
        relative = path.relative_to(root).as_posix()
        source = path.read_text()
        match = re.search(r'(?ms)^module\s+(\S+)\s*\((.*?)\)\s*where', source)
        if not match:
            errors.append(f'{relative}: explicit exports required')
            continue
        name, exports = match[1], match[2]
        count = len(source.splitlines())
        limit = limits.get(relative, 1000)
        if relative == 'cli/nagarectl/test/Spec.hs': limit = 30
        if name == 'Nagare.Test.Suite': limit = 300
        if count > limit:
            errors.append(f'{relative}: {count} lines exceeds {limit}; separate responsibilities')
        if relative in limits and count <= 1000:
            errors.append(f'{relative}: remove obsolete size allowance')
        imports = set(re.findall(r'^import\s+(?:qualified\s+)?([A-Z][\w.]*)', source, re.M))
        sources[package, area, name] = (relative, imports)
        if name != 'Main' and name not in components[package][area == 'test']:
            errors.append(f'{relative}: missing Cabal registration for {name}')
        if name.startswith(PRIVATE) or name in OPAQUE:
            if re.search(r'\bmodule\s+', exports):
                errors.append(f'{name}: module re-export hides public boundary')
        for opaque in OPAQUE.get(name, ()):
            if re.search(r'\b' + opaque + r'\s*\(', exports):
                errors.append(f'{name}: opaque constructor exposed: {opaque}')
        if name.startswith('Nagare.Inventory.Plan.'):
            part = name.rsplit('.', 1)[1]
            if part in PURE_PLAN:
                for dependency in imports:
                    if dependency in {'Nagare.Inventory.Plan.' + x for x in EFFECT_PLAN}:
                        errors.append(f'{name}: pure planning imports effect owner {dependency}')
                body = re.sub(r'--[^\n]*', '', source[match.end():])
                if re.search(r'\bIO\b', body):
                    errors.append(f'{name}: pure planning contains IO')
        if name.startswith('Nagare.Dsl.Load.') and name.rsplit('.', 1)[1] not in {'Process', 'File'}:
            for dependency in imports:
                if dependency in {'Nagare.Dsl.Load.Process', 'Nagare.Dsl.Load.File', 'System.Process'}:
                    errors.append(f'{name}: decoder imports process execution {dependency}')
        if name.startswith('Nagare.Test.Support.'):
            for dependency in imports:
                if dependency.startswith('Nagare.Test.') and not dependency.startswith('Nagare.Test.Support.'):
                    errors.append(f'{name}: shared fixture imports test suite {dependency}')
        if name.startswith('Nagare.Test.') and name != 'Nagare.Test.Suite' and 'Nagare.Test.Suite' in imports:
            errors.append(f'{name}: domain tests import suite assembler')
        if area == 'src' and any(x.startswith('Nagare.Cli.') for x in imports):
            errors.append(f'{name}: library imports CLI workflows')
        if name.startswith('Nagare.Inventory.Execute.') and '-Werror=incomplete-patterns' not in source:
            errors.append(f'{name}: recovery exhaustiveness check missing')
    for relative in limits:
        if not (root / relative).is_file():
            errors.append(f'{relative}: stale size allowance')
    # Libraries may use the public DSL, but only their own package's internals.
    for (package, area, name), (relative, imports) in sources.items():
        for dependency in imports:
            if dependency.startswith(PRIVATE) and not (package, 'src', dependency) in sources:
                errors.append(f'{relative}: imports another package private module {dependency}')
    for package in PACKAGES:
        graph = {name: imports for (pkg, area, name), (_, imports) in sources.items()
                 if pkg == package and area == 'src'}
        graph.update({name: imports for (pkg, area, name), (_, imports) in sources.items()
                      if pkg == package and area == 'test'})
        visited = set()
        def visit(name, stack):
            if name in stack:
                errors.append('import cycle: ' + ' -> '.join(stack + [name]))
                return
            if name in visited: return
            for dependency in sorted(graph[name] & graph.keys()):
                visit(dependency, stack + [name])
            visited.add(name)
        for name in sorted(graph): visit(name, [])
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args()
    limits = json.loads((args.root / 'scripts/haskell-size-allowances.json').read_text())
    errors = check(args.root, limits)
    if errors:
        print('\n'.join(errors))
        return 1
    print('Haskell architecture: private implementation, pure planning/decoding, acyclic imports, bounded growth')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
