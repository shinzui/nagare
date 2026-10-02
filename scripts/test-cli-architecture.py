#!/usr/bin/env python3
"""Prove that the architecture check rejects the boundaries it protects."""

import importlib.util
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("cli_architecture", ROOT / "scripts/check-cli-architecture.py")
architecture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(architecture)


class ArchitectureTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="nagare-cli-architecture-")
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / "app"
        shutil.copytree(architecture.APP, self.app)
        self.cabal = ROOT / "cli/nagarectl/nagarectl.cabal"

    def inject_import(self, module, dependency):
        path = self.app / (module.replace(".", "/") + ".hs")
        source = path.read_text()
        path.write_text(source.replace("\nimport ", f"\nimport {dependency}\nimport ", 1))

    def errors(self):
        return architecture.check(self.app, self.cabal)

    def test_current_tree(self):
        self.assertEqual([], self.errors())

    def test_entrypoint_policy(self):
        self.inject_import("Main", "Nagare.Inventory.Execute")
        self.assertTrue(any("process setup must not import" in e for e in self.errors()))

    def test_parser_effects(self):
        self.inject_import("Nagare.Cli.Parser", "Nagare.Cli.Runtime.Target")
        self.assertTrue(any("parsing must not depend" in e for e in self.errors()))

    def test_command_coupling(self):
        self.inject_import("Nagare.Cli.Commands.Access", "Nagare.Cli.Commands.Database")
        self.assertTrue(any("must not depend on command handler" in e for e in self.errors()))

    def test_cycle(self):
        self.inject_import("Nagare.Cli.Runtime.Error", "Nagare.Cli.Runtime.Target")
        self.assertTrue(any("CLI import cycle" in e for e in self.errors()))

    def test_module_growth(self):
        path = self.app / "Main.hs"
        path.write_text(path.read_text() + "\n" * 31)
        self.assertTrue(any("exceeds 30 lines" in e for e in self.errors()))

    def test_exports(self):
        path = self.app / "Main.hs"
        path.write_text(path.read_text().replace("module Main (main) where", "module Main where"))
        self.assertTrue(any("explicit exports required" in e for e in self.errors()))

    def test_unregistered_module(self):
        (self.app / "Nagare/Cli/Unexpected.hs").write_text(
            "module Nagare.Cli.Unexpected (unexpected) where\nunexpected = ()\n")
        errors = self.errors()
        self.assertTrue(any("missing executable other-modules" in e for e in errors))
        self.assertTrue(any("unreachable from Main" in e for e in errors))

    def test_public_api_leak(self):
        path = Path(self.temporary.name) / "nagarectl.cabal"
        path.write_text(self.cabal.read_text().replace(
            "  exposed-modules:\n", "  exposed-modules:\n    Nagare.Cli.Options\n", 1))
        self.assertTrue(any("private to the executable" in e
                            for e in architecture.check(self.app, path)))


if __name__ == "__main__":
    unittest.main()
