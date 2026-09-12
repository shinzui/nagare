import json
import os
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from guard_host_mutation import decide  # noqa: E402

HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "guard_host_mutation.py")

CASES = [
    ("deny", "nixos-rebuild switch --flake ./nixos#nagare-01 --target-host deploy@nagare-01 --sudo"),
    ("deny", 'NIX_SSHOPTS="-p 2222" nixos-rebuild switch --flake x#y --target-host deploy@127.0.0.1'),
    ("deny", "cd nixos && nixos-rebuild test --flake .#nagare-01"),
    ("deny", "ssh nagare-01 'sudo nixos-rebuild boot --flake /etc/nixos#x'"),
    ("deny", 'ssh h "sudo /nix/var/nix/profiles/system-41-link/bin/switch-to-configuration switch"'),
    ("deny", "sudo nix-env -p /nix/var/nix/profiles/system --set /nix/store/abc-nixos-system"),
    ("deny", "ln -sfn /nix/var/nix/profiles/system-3-link /nix/var/nix/profiles/system"),
    ("deny", "gcloud compute instances add-metadata nagare-01 --metadata-from-file=startup-script=/tmp/x.sh"),
    ("deny", "NIXOS_NO_CHECK=1 true"),
    ("deny", "cd nixos\nnixos-rebuild switch --flake .#nagare-01"),
    ("ask", "gcloud compute instances stop nagare-01"),
    ("ask", "gcloud --project=tan-nb-exp compute instances detach-disk nagare-01 --disk=nagare-01"),
    ("ask", "gcloud compute disks snapshot nagare-01 --snapshot-names=s"),
    ("ask", "pulumi -C infra/pulumi up --stack tan-nb-exp --yes"),
    ("ask", "pulumi state unprotect 'urn:x'"),
    ("ask", "just host-switch"),
    ("ask", "scripts/host-switch.sh"),
    ("allow", "nixos-rebuild build --flake ./nixos#nagare-01"),
    ("allow", "grep -rn switch-to-configuration nixos/"),
    ("allow", "scripts/host-switch.sh --dry-run"),
    ("allow", "pulumi -C infra/pulumi preview --refresh --stack tan-nb-exp --diff"),
    ("allow", "gcloud compute instances describe nagare-01 --format='value(status)'"),
    ("allow", "nix build .#checks.x86_64-linux.host-switch-auto-rollback"),
    ("allow", "git log --oneline -5"),
]


class DecideTable(unittest.TestCase):
    def test_table(self):
        for expected, command in CASES:
            with self.subTest(command=command):
                result = decide(command)
                actual = "allow" if result is None else result[0]
                self.assertEqual(expected, actual)


def run_hook(stdin: str) -> str:
    return subprocess.run([sys.executable, HOOK], input=stdin, capture_output=True, text=True, check=True).stdout


class HookProcess(unittest.TestCase):
    def test_malformed_json_fails_closed(self):
        out = json.loads(run_hook("not json"))
        self.assertEqual("deny", out["hookSpecificOutput"]["permissionDecision"])

    def test_missing_command_fails_closed(self):
        out = json.loads(run_hook(json.dumps({"tool_name": "Bash", "tool_input": {}})))
        self.assertEqual("deny", out["hookSpecificOutput"]["permissionDecision"])

    def test_deny_emits_hook_json(self):
        stdin = json.dumps({"tool_name": "Bash", "tool_input": {"command": "nixos-rebuild switch --flake ./nixos#nagare-01"}})
        out = json.loads(run_hook(stdin))["hookSpecificOutput"]
        self.assertEqual(("PreToolUse", "deny"), (out["hookEventName"], out["permissionDecision"]))
        self.assertIn("just host-switch", out["permissionDecisionReason"])

    def test_allowed_and_non_bash_print_nothing(self):
        self.assertEqual("", run_hook(json.dumps({"tool_name": "Bash", "tool_input": {"command": "git status"}})))
        self.assertEqual("", run_hook(json.dumps({"tool_name": "Read", "tool_input": {"file_path": "/x"}})))


if __name__ == "__main__":
    unittest.main()
