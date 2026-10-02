#!/usr/bin/env python3
"""Negative fixtures for library/test architectural constraints."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('haskell_architecture', ROOT / 'scripts/check-haskell-architecture.py')
architecture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(architecture)


class ArchitectureTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='nagare-library-architecture-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.limits = json.loads((ROOT / 'scripts/haskell-size-allowances.json').read_text())
        paths = [path for _, _, path in architecture.source_modules(ROOT)]
        paths += [ROOT / 'cli' / package / (package + '.cabal') for package in architecture.PACKAGES]
        for path in paths:
            target = self.root / path.relative_to(ROOT)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(path.read_text())

    def errors(self):
        return architecture.check(self.root, self.limits)

    def replace(self, path, old, new):
        target = self.root / path
        source = target.read_text()
        self.assertIn(old, source)
        target.write_text(source.replace(old, new, 1))

    def imports(self, path, dependency):
        self.replace(path, '\nimport ', '\nimport ' + dependency + '\nimport ')

    def assert_error(self, fragment):
        self.assertTrue(any(fragment in error for error in self.errors()), self.errors())

    def test_current_tree(self):
        self.assertEqual([], self.errors())

    def test_pure_planner_cannot_import_history(self):
        self.imports('cli/nagarectl/src/Nagare/Inventory/Plan/Changes.hs', 'Nagare.Inventory.Plan.History')
        self.assert_error('pure planning imports effect owner')

    def test_pure_planner_cannot_add_io(self):
        target = self.root / 'cli/nagarectl/src/Nagare/Inventory/Plan/Changes.hs'
        target.write_text(target.read_text() + '\nunwanted :: IO ()\nunwanted = pure ()\n')
        self.assert_error('pure planning contains IO')

    def test_decoder_cannot_import_process(self):
        self.imports('cli/nagare-dsl/src/Nagare/Dsl/Load/Deployment.hs', 'Nagare.Dsl.Load.Process')
        self.assert_error('decoder imports process execution')

    def test_private_library_cannot_be_exposed(self):
        self.replace('cli/nagarectl/nagarectl.cabal', '  exposed-modules:\n',
                     '  exposed-modules:\n    Nagare.Inventory.Plan.Types\n')
        self.assert_error('implementation module exposed')

    def test_authority_constructor_cannot_be_exposed(self):
        self.replace('cli/nagarectl/src/Nagare/Inventory/Plan.hs', '  , ReviewedPlan\n', '  , ReviewedPlan (..)\n')
        self.assert_error('opaque constructor exposed')

    def test_facade_cannot_reexport_implementation(self):
        self.replace('cli/nagarectl/src/Nagare/Inventory/Plan.hs', '  ( InventoryHistory',
                     '  ( module Nagare.Inventory.Plan.Types\n  , InventoryHistory')
        self.assert_error('module re-export hides public boundary')

    def test_test_fixture_cannot_import_suite(self):
        self.imports('cli/nagarectl/test/Nagare/Test/Support/Profiles.hs', 'Nagare.Test.Suite')
        self.assert_error('shared fixture imports test suite')

    def test_unregistered_module(self):
        target = self.root / 'cli/nagarectl/src/Nagare/Unexpected.hs'
        target.write_text('module Nagare.Unexpected (unexpected) where\nunexpected = ()\n')
        self.assert_error('missing Cabal registration')

    def test_cycle(self):
        self.imports('cli/nagarectl/src/Nagare/Inventory/Application/Types.hs', 'Nagare.Inventory.Application.Compile')
        self.assert_error('import cycle')

    def test_old_large_module_cannot_grow(self):
        relative = 'cli/nagarectl/src/Nagare/Inventory/Store.hs'
        target = self.root / relative
        target.write_text(target.read_text() + '\n')
        self.assert_error('exceeds ' + str(self.limits[relative]))

    def test_new_module_size_is_bounded(self):
        target = self.root / 'cli/nagarectl/src/Nagare/Inventory/Application/Types.hs'
        target.write_text(target.read_text() + '\n' * 1001)
        self.assert_error('exceeds 1000')

    def test_recovery_exhaustiveness_cannot_be_disabled(self):
        self.replace('cli/nagarectl/src/Nagare/Inventory/Execute/Driver.hs',
                     '{-# OPTIONS_GHC -Werror=incomplete-patterns #-}', '')
        self.assert_error('recovery exhaustiveness check missing')

    def test_test_entrypoint_cannot_accumulate(self):
        target = self.root / 'cli/nagarectl/test/Spec.hs'
        target.write_text(target.read_text() + '\n' * 31)
        self.assert_error('exceeds 30')


if __name__ == '__main__':
    unittest.main()
