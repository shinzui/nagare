#!/usr/bin/env python3
"""Keep the executable's parsing, dispatch, and policy boundaries explicit."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "cli/nagarectl/app"


def check(app: Path, cabal: Path) -> list[str]:
    errors: list[str] = []
    modules: dict[str, tuple[Path, str, set[str]]] = {}
    for path in sorted(app.rglob("*.hs")):
        source = path.read_text()
        declaration = re.search(r"(?ms)^module\s+(\S+)\s*\((.*?)\)\s*where", source)
        if declaration is None:
            errors.append(f"{path.name}: explicit exports required")
            continue
        name = declaration[1]
        if re.search(r"\bmodule\s+", declaration[2]):
            errors.append(f"{name}: module-wide re-exports hide dependencies")
        imports = set(re.findall(r"(?m)^import\s+(?:qualified\s+)?([A-Z][\w.]*)", source))
        modules[name] = path, source, imports
        limit = 30 if name == "Main" else 200 if name.endswith(".Dispatch") else 1000
        if len(source.splitlines()) > limit:
            errors.append(f"{name}: exceeds {limit} lines; separate its responsibilities")
        if name == "Main":
            allowed = {"GHC.IO.Encoding", "System.IO", "Options.Applicative",
                       "Nagare.Dsl.Prelude", "Nagare.Cli.Parser", "Nagare.Cli.Dispatch"}
            for dependency in sorted(imports - allowed):
                errors.append(f"Main: process setup must not import {dependency}")
        if name.startswith(("Nagare.Cli.Parser", "Nagare.Cli.Options")):
            for dependency in sorted(imports):
                if dependency.startswith("Nagare.Cli.") and not dependency.startswith(
                    ("Nagare.Cli.Parser", "Nagare.Cli.Options")
                ):
                    errors.append(f"{name}: parsing must not depend on {dependency}")
            if re.search(r"\bIO\s+(?:\w|\()", source):
                errors.append(f"{name}: parsing must remain pure")
        if name != "Nagare.Cli.Dispatch":
            for dependency in sorted(imports):
                if dependency.startswith("Nagare.Cli.Commands."):
                    errors.append(f"{name}: shared policy must not depend on command handler {dependency}")

    cabal_source = cabal.read_text()
    library = cabal_source.split("\nexecutable nagarectl\n", 1)[0]
    if re.search(r"\bNagare\.Cli\.", library):
        errors.append("CLI modules must remain private to the executable")
    component = cabal_source.split("executable nagarectl\n", 1)[1].split("\nexecutable ", 1)[0]
    registered = set(re.findall(r"(?m)^\s+(Nagare\.Cli\.[\w.]+)\s*$", component))
    actual = set(modules) - {"Main"}
    for name in sorted(actual - registered):
        errors.append(f"{name}: missing executable other-modules registration")
    for name in sorted(registered - actual):
        errors.append(f"{name}: stale executable other-modules registration")

    visited: set[str] = set()

    def visit(name: str, stack: list[str]) -> None:
        if name in stack:
            errors.append("CLI import cycle: " + " -> ".join(stack[stack.index(name):] + [name]))
            return
        if name in visited:
            return
        for dependency in sorted(modules[name][2]):
            if dependency in modules:
                visit(dependency, stack + [name])
            elif dependency.startswith("Nagare.Cli."):
                errors.append(f"{name}: missing CLI dependency {dependency}")
        visited.add(name)

    for name in sorted(modules):
        visit(name, [])

    reachable: set[str] = set()

    def reachable_from(name: str) -> None:
        if name in reachable or name not in modules:
            return
        reachable.add(name)
        for dependency in modules[name][2]:
            reachable_from(dependency)

    reachable_from("Main")
    for name in sorted(set(modules) - reachable):
        errors.append(f"{name}: unreachable from Main; remove unused executable modules")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=APP)
    parser.add_argument("--cabal", type=Path, default=ROOT / "cli/nagarectl/nagarectl.cabal")
    args = parser.parse_args()
    errors = check(args.app, args.cabal)
    if errors:
        print("\n".join(errors))
        return 1
    print("CLI architecture: explicit exports, acyclic dependencies, pure parsing, bounded modules")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
