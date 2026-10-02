#!/usr/bin/env python3
"""Compare all command help and parser refusals with a baseline executable.

Only --help and invalid options are passed, so no command handler is executed.
Usage: test-cli-refactor-parity.py BASELINE CANDIDATE
"""

from pathlib import Path
import re
import subprocess
import sys
import tempfile


def main():
    baseline, candidate = [str(Path(arg).resolve()) for arg in sys.argv[1:3]]
    with tempfile.TemporaryDirectory(prefix="nagare-cli-parity-") as temporary:
        root = Path(temporary)
        environment = {"PATH": "/nonexistent", "HOME": str(root), "LANG": "en_US.UTF-8",
                       "XDG_CONFIG_HOME": str(root / "config"),
                       "XDG_STATE_HOME": str(root / "state"), "COLUMNS": "80"}
        # Identical argv[0] prevents wrapping differences in usage text.
        binaries = []
        for label, source in [("before", baseline), ("after", candidate)]:
            directory = root / label
            directory.mkdir()
            link = directory / "nagarectl"
            link.symlink_to(source)
            binaries.append(str(link))

        def run(binary, args):
            result = subprocess.run([binary, *args], env=environment, cwd=root,
                                    text=True, capture_output=True, timeout=10)
            return result.returncode, result.stdout, result.stderr

        # The legacy release group has no group-level helper. Its two leaves
        # still have help; include them without changing that existing syntax.
        pending = [(), ("release", "publish"), ("release", "cleanup-starter")]
        seen = set()
        checks = 0
        while pending:
            command = pending.pop()
            if command in seen:
                continue
            seen.add(command)
            for suffix in [("--help",), ("--mp23-invalid-option",)]:
                args = [*command, *suffix]
                before, after = [run(binary, args) for binary in binaries]
                assert before == after, (args, before, after)
                checks += 1
                if suffix == ("--help",):
                    text = before[1] + before[2]
                    if "Available commands:\n" in text:
                        commands = text.split("Available commands:\n", 1)[1]
                        pending.extend((*command, match[1]) for match in
                                       re.finditer(r"(?m)^  ([a-z][a-z0-9-]*)\s{2,}", commands))
        assert not (root / "config").exists()
        assert not (root / "state").exists()
        print(f"CLI parity: {len(seen)} command paths, {checks} identical help/refusal results; no state writes")


if __name__ == "__main__":
    main()
