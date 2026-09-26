#!/usr/bin/env python3
"""Exercise reviewed app planning and apply beside unrelated provider owners.

Live mode requires a disposable kubeconfig whose context is named ``isolated``,
an existing ``personal`` Namespace, and the fixture image preloaded at its tag.
It leaves the two created native objects for inspection and explicit cleanup.
"""

import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def run(cli: Path, root: Path, environment: dict[str, str], args: list[str]) -> str:
    result = subprocess.run(
        [str(cli), *args], cwd=root / "cli/nagarectl", env=environment,
        text=True, capture_output=True, check=False,
    )
    if result.returncode:
        diagnostic_file = environment.get("SCOPE_TEST_KUBECTL_ERRORS")
        diagnostics = (Path(diagnostic_file).read_text()
            if diagnostic_file and Path(diagnostic_file).exists() else "")
        raise AssertionError(
            f"nagarectl {' '.join(args)} failed ({result.returncode}):\n"
            f"{result.stdout}{result.stderr}{diagnostics}"
        )
    return result.stdout


def main() -> None:
    if len(sys.argv) not in (2, 4) or (len(sys.argv) == 4 and sys.argv[2] != "--live-kubeconfig"):
        raise SystemExit("usage: test-inventory-scope-isolation.py BUILT_NAGARECTL [--live-kubeconfig FILE]")
    cli = Path(sys.argv[1]).resolve(strict=True)
    live_kubeconfig = Path(sys.argv[3]).resolve(strict=True) if len(sys.argv) == 4 else None
    live_kubectl = shutil.which("kubectl") if live_kubeconfig else None
    if live_kubeconfig and not live_kubectl:
        raise SystemExit("live provider probe requires kubectl")
    root = Path(__file__).resolve().parent.parent
    fixture = json.loads((root / "cli/nagarectl/test/fixtures/inventory/valid.json").read_text())
    foundation = fixture["snapshot"][0]["declaration"]
    owner = {"kind": "Platform", "name": "cloud"}
    cloud_resource = {
        "identity": "platform:cloud/bucket/resource",
        "owner": owner,
        "executor": "PulumiExecutor",
        "address": {"tag": "GlobalBucket", "contents": "unrelated-bucket"},
        "aliases": [{"tag": "PulumiUrn", "contents":
            "urn:pulumi:local::nagare::gcp:storage/bucket:Bucket::unrelated"}],
        "spec": {"tag": "NativeObject", "contents": "a" * 64},
        "lifecycle": "Retain",
        "dataPolicy": {"tag": "Stateless"},
        "sensitivity": "Public",
        "dependencies": [],
        "delegations": [],
        "source": {"file": "fixture", "path": "unrelated"},
    }
    def bundle(declarations: list[dict]) -> dict:
        return {
            "declarations": declarations, "exports": [], "conditions": [],
            "contributions": [], "operations": [], "grants": [],
        }
    cloud = {"version": 1, "scope": owner,
        "bundles": [bundle([{"tag": "Managed", "contents": cloud_resource}])]}
    host_owner = {"kind": "Platform", "name": "unrelated-host"}
    host_resource_id = "platform:unrelated-host/system/resource"
    host_resource = {
        "identity": host_resource_id, "owner": host_owner,
        "executor": "HostExecutor",
        "address": {"tag": "Host", "contents": [
            "platform:foundation/cluster/resource", "unrelated"]},
        "aliases": [],
        "spec": {"tag": "NativeObject", "contents": "b" * 64},
        "lifecycle": "Retain", "dataPolicy": {"tag": "Stateless"},
        "sensitivity": "Public", "dependencies": [], "delegations": [],
        "source": {"file": "fixture", "path": "unrelated-host"},
    }
    host_bundle = bundle([{"tag": "Managed", "contents": host_resource}])
    host_bundle["operations"] = [{
        "identity": "platform:unrelated-host/activation/apply",
        "affects": [host_resource_id],
        "inputs": [{"tag": "ContentInput", "contents": "c" * 64},
            {"tag": "ContentInput", "contents": "d" * 64}],
        "recovery": "OperatorRecovery", "operationKind": "ActivateHost",
    }]
    host = {"version": 1, "scope": host_owner, "bundles": [host_bundle]}
    app = {"version": 1, "scope": {"kind": "Application", "name": "empty"},
        "bundles": [bundle([])]}
    candidate = {
        "version": 1,
        "context": {"identity": "isolated", "project": "project"},
        "base": [
            {"scope": foundation["scope"], "generation": 7},
            {"scope": owner, "generation": 1},
            {"scope": host_owner, "generation": 1},
        ],
        "snapshot": [
            {"generation": 7, "declaration": foundation},
            {"generation": 1, "declaration": cloud},
            {"generation": 1, "declaration": host},
        ],
        "reservations": [],
        "changes": [{"replace": app}],
    }

    with tempfile.TemporaryDirectory(prefix="nagare-scope-isolation-") as temporary:
        scratch = Path(temporary)
        candidate_file = scratch / "candidate.json"
        candidate_file.write_text(json.dumps(candidate))
        context_dir = scratch / "config/nagare/contexts"
        context_dir.mkdir(parents=True)
        (context_dir / "isolated.env").write_text(
            "CLOUDSDK_CORE_PROJECT=project\nNAGARE_MODE=local\n"
            "NAGARE_REGISTRY_HOST=k3d-registry.localhost:5000\n"
            "NAGARE_BASE_DOMAIN=127-0-0-1.sslip.io\n"
            "NAGARE_LOCAL_OBJECT_STORE=http://minio:9000/nagare-backups\n"
        )
        marker = scratch / "provider-called"
        kubectl_calls = scratch / "kubectl-calls.jsonl"
        kubectl_state = scratch / "kubectl-state.json"
        kubectl_errors = scratch / "kubectl-errors.jsonl"
        fake_bin = scratch / "bin"
        fake_bin.mkdir()
        for executable in ("npm", "pulumi", "gcloud"):
            fake = fake_bin / executable
            fake.write_text(
                "#!/bin/sh\nprintf '%s\\n' \"$0\" >> "
                + shlex.quote(str(marker)) + "\nexit 95\n"
            )
            fake.chmod(0o755)
        kubectl = fake_bin / "kubectl"
        kubectl.write_text("""#!/usr/bin/env python3
import json
import subprocess
import sys
from pathlib import Path

marker = Path(%r)
calls = Path(%r)
state_file = Path(%r)
live_binary = %r
errors = Path(%r)
with marker.open("a") as output:
    output.write(sys.argv[0] + "\\n")
with calls.open("a") as output:
    output.write(json.dumps(sys.argv[1:]) + "\\n")
args = sys.argv[1:]
if live_binary is not None:
    result = subprocess.run([live_binary, *args], stdin=sys.stdin.buffer,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    sys.stdout.buffer.write(result.stdout)
    sys.stderr.buffer.write(result.stderr)
    if result.returncode:
        with errors.open("a") as output:
            output.write(json.dumps({"args": args, "exit": result.returncode,
                "stderr": result.stderr.decode(errors="replace")}) + "\\n")
    sys.exit(result.returncode)
objects = json.loads(state_file.read_text()) if state_file.exists() else {}
namespace = args[args.index("--namespace") + 1] if "--namespace" in args else ""
if "get" in args:
    position = args.index("get")
    kind = args[position + 1].split(".", 1)[0].lower()
    name = args[position + 2]
    existing = objects.get(f"{namespace}:{kind}:{name}")
    if existing is not None:
        print(json.dumps(existing, separators=(",", ":")))
    sys.exit(0)
if "create" in args:
    native = json.load(sys.stdin)
    metadata = native.setdefault("metadata", {})
    kind = native["kind"].lower()
    name = metadata["name"]
    key = f"{metadata.get('namespace', '')}:{kind}:{name}"
    if key in objects:
        sys.exit(1)
    metadata["uid"] = "recorded-" + kind + "-" + name
    metadata["resourceVersion"] = "1"
    if native.get("apiVersion") == "serving.knative.dev/v1" and kind == "service":
        native["status"] = {"conditions": [{"type": "Ready", "status": "True"}]}
    objects[key] = native
    state_file.write_text(json.dumps(objects, sort_keys=True))
    print(json.dumps(native, separators=(",", ":")))
    sys.exit(0)
if "wait" in args and any(value.startswith("ksvc/") for value in args):
    sys.exit(0)
sys.exit(95)
""" % (str(marker), str(kubectl_calls), str(kubectl_state), live_kubectl,
            str(kubectl_errors)))
        kubectl.chmod(0o755)
        environment = {key: value for key, value in os.environ.items()
            if not key.startswith("NAGARE_") and not key.startswith("CLOUDSDK_")}
        environment.update({
            "XDG_CONFIG_HOME": str(scratch / "config"),
            "XDG_STATE_HOME": str(scratch / "state"),
            "CLOUDSDK_CORE_PROJECT": "project",
            "NAGARE_MODE": "local",
            "PATH": str(fake_bin) + os.pathsep + os.environ.get("PATH", ""),
        })
        if live_kubeconfig:
            environment["KUBECONFIG"] = str(live_kubeconfig)
            environment["SCOPE_TEST_KUBECTL_ERRORS"] = str(kubectl_errors)
        compiled = scratch / "compiled"
        review = scratch / "review"
        run(cli, root, environment, ["inventory", "compile", "--input",
            str(candidate_file), "--out", str(compiled)])
        empty_store = scratch / "empty-state/nagare/isolated/inventory"
        empty_store.mkdir(parents=True)
        empty_head = empty_store / "head.json"
        empty_head.write_text(json.dumps({
            "version": 1, "generation": 0, "sequence": 0,
            "binding": {"identity": "isolated", "project": "project"},
            "clientIdentity": "scope-isolation-test", "accepted": [], "converged": [],
            "activeTransaction": None, "executorClaim": None,
        }, sort_keys=True, separators=(",", ":")))
        empty_head.chmod(0o600)
        empty_environment = environment | {"XDG_STATE_HOME": str(scratch / "empty-state")}
        run(cli, root, empty_environment, ["--context", "isolated", "inventory", "plan",
            "--inventory", str(compiled), "--out", str(scratch / "empty-review")])
        if marker.exists():
            raise AssertionError("initialized empty store invoked a provider: " + marker.read_text())
        run(cli, root, environment, ["--context", "isolated", "inventory", "plan",
            "--inventory", str(compiled), "--out", str(review)])
        document = json.loads((review / "review.json").read_text())
        if document["operations"]:
            raise AssertionError("selected empty scope planned unrelated provider operations")
        head_file = scratch / "state/nagare/isolated/inventory/head.json"
        before = json.loads(head_file.read_text())
        run(cli, root, environment, ["--context", "isolated", "inventory", "apply",
            str(review), "--yes"])
        after = json.loads(head_file.read_text())
        old_revisions = {entry["scope"]["name"]: entry["revision"]
            for entry in before["accepted"]}
        new_revisions = {entry["scope"]["name"]: entry["revision"]
            for entry in after["accepted"]}
        if any(old_revisions[name] != new_revisions.get(name)
               for name in ("cloud", "foundation", "unrelated-host")):
            raise AssertionError("unrelated accepted scope revisions changed")
        if "empty" not in new_revisions:
            raise AssertionError("selected empty application scope was not accepted")
        if marker.exists():
            raise AssertionError("unrelated provider executable was called: "
                + marker.read_text())
        if not live_kubeconfig:
            selected_candidate = json.loads(json.dumps(candidate))
            selected_app = selected_candidate["changes"][0]["replace"]
            selected_foundation = selected_candidate["snapshot"][0]["declaration"]
            selected_foundation["bundles"][0]["grants"] = [
                [selected_app["scope"], "platform:foundation/cluster/resource"]
            ]
            selected_app["bundles"][0]["contributions"] = [{
                "owner": selected_foundation["scope"],
                "cluster": "platform:foundation/cluster/resource",
                "namespace": "selected", "key": "selected",
            }]
            selected_file = scratch / "selected-candidate.json"
            selected_file.write_text(json.dumps(selected_candidate))
            selected_compiled = scratch / "selected-compiled"
            selected_review = scratch / "selected-review"
            selected_environment = environment | {
                "XDG_STATE_HOME": str(scratch / "selected-state")
            }
            run(cli, root, selected_environment, ["inventory", "compile", "--input",
                str(selected_file), "--out", str(selected_compiled)])
            run(cli, root, selected_environment, ["--context", "isolated", "inventory", "plan",
                "--inventory", str(selected_compiled), "--out", str(selected_review)])
            selected_operations = json.loads((selected_review / "review.json").read_text())["operations"]
            if len(selected_operations) != 1 or "KubernetesExecutor" not in json.dumps(selected_operations):
                raise AssertionError("selected Namespace did not plan one Kubernetes operation")
            calls = marker.read_text().splitlines() if marker.exists() else []
            if not calls or any(Path(call).name != "kubectl" for call in calls):
                raise AssertionError("selected Namespace invoked an unrelated provider: " + repr(calls))
            marker.unlink()

        app_candidate = json.loads(json.dumps(candidate))
        app_foundation = app_candidate["snapshot"][0]["declaration"]
        app_foundation["bundles"][0]["declarations"].append({
            "tag": "Managed", "contents": {
                "identity": "platform:foundation/foundation/namespace-personal",
                "owner": app_foundation["scope"],
                "executor": "KubernetesExecutor",
                "address": {"tag": "Kubernetes", "contents": [
                    "platform:foundation/cluster/cluster", "", "namespace", None,
                    "personal"]},
                "aliases": [],
                "spec": {"tag": "NativeObject", "contents": "e" * 64},
                "lifecycle": "Retain", "dataPolicy": {"tag": "Stateless"},
                "sensitivity": "Public", "dependencies": [], "delegations": [],
                "source": {"file": "fixture", "path": "personal"},
            },
        })
        image_owner = {"kind": "Publication", "name": "app-image-isolated"}
        image_id = "publication:app-image-isolated/isolated/oci-image"
        image_scope = {"version": 1, "scope": image_owner, "bundles": [bundle([{
            "tag": "Managed", "contents": {
                "identity": image_id, "owner": image_owner,
                "executor": "ArtifactExecutor",
                "address": {"tag": "Artifact", "contents": ["isolated", "f" * 64]},
                "aliases": [],
                "spec": {"tag": "ArtifactPublication", "contents": [
                    "oci-image", "k3d-registry.localhost:5000/isolated:v1",
                    "a" * 64, False]},
                "lifecycle": "Retain", "dataPolicy": {"tag": "Stateless"},
                "sensitivity": "Private", "dependencies": [], "delegations": [],
                "source": {"file": "fixture", "path": "image"},
            },
        }])]}
        app_candidate["base"].append({"scope": image_owner, "generation": 1})
        app_candidate["snapshot"].append({"generation": 1, "declaration": image_scope})
        app_candidate["changes"] = [{"replace": {
            "version": 1, "scope": {"kind": "Application", "name": "bootstrap"},
            "bundles": [bundle([])],
        }}]
        app_file = scratch / "app-candidate.json"
        app_file.write_text(json.dumps(app_candidate))
        app_compiled = scratch / "app-compiled"
        app_environment = environment | {"XDG_STATE_HOME": str(scratch / "app-state")}
        seed_review = scratch / "app-seed-review"
        run(cli, root, app_environment, ["inventory", "compile", "--input",
            str(app_file), "--out", str(app_compiled)])
        run(cli, root, app_environment, ["--context", "isolated", "inventory", "plan",
            "--inventory", str(app_compiled), "--out", str(seed_review)])
        run(cli, root, app_environment, ["--context", "isolated", "inventory", "apply",
            str(seed_review), "--yes"])
        if marker.exists():
            raise AssertionError("app fixture seeding invoked a provider: " + marker.read_text())
        app_review = scratch / "app-review"
        config_name = "WorkerConfig.hs" if live_kubeconfig else "Config.hs"
        app_config = root / "cli/nagarectl/test/fixtures/app-scope-isolation/nagare" / config_name
        run(cli, root, app_environment, ["--context", "isolated", "app", "deploy",
            "--file", str(app_config), "--tag", "v1", "--image-resource", image_id,
            "--save-plan", str(app_review)])
        app_operations = json.loads((app_review / "review.json").read_text())["operations"]
        if not app_operations or any("KubernetesExecutor" not in json.dumps(operation)
                                     for operation in app_operations):
            raise AssertionError("reviewed application planned unexpected provider operations")
        calls = marker.read_text().splitlines() if marker.exists() else []
        if not calls or any(Path(call).name != "kubectl" for call in calls):
            raise AssertionError("reviewed application invoked an unrelated provider: " + repr(calls))
        review_calls = [json.loads(line) for line in kubectl_calls.read_text().splitlines()]
        if any("get" in call and "cache" in call for call in review_calls):
            raise AssertionError("reviewed application observed an unrelated native member")
        marker.unlink()
        kubectl_calls.unlink()
        app_head = scratch / "app-state/nagare/isolated/inventory/head.json"
        before_app_apply = json.loads(app_head.read_text())
        run(cli, root, app_environment, ["--context", "isolated", "inventory", "apply",
            str(app_review), "--yes"])
        after_app_apply = json.loads(app_head.read_text())
        old_revisions = {entry["scope"]["name"]: entry["revision"]
            for entry in before_app_apply["accepted"]}
        new_revisions = {entry["scope"]["name"]: entry["revision"]
            for entry in after_app_apply["accepted"]}
        if any(old_revisions[name] != new_revisions.get(name)
               for name in ("cloud", "foundation", "unrelated-host", "app-image-isolated")):
            raise AssertionError("reviewed app apply changed an unrelated accepted revision")
        if "isolated-app" not in new_revisions:
            raise AssertionError("reviewed app apply did not accept the application scope")
        expected_workload = ("personal:deployment:isolated-app" if live_kubeconfig
            else "personal:service:isolated-app")
        expected_objects = {expected_workload,
            "personal:configmap:nagare-app-deployments-isolated-app"}
        if live_kubeconfig:
            provider_objects = {}
            for key in expected_objects:
                namespace, kind, name = key.split(":", 2)
                result = subprocess.run(
                    [live_kubectl, "--context", "isolated", "get", kind, name,
                     "--namespace", namespace, "-o", "json"],
                    env=app_environment, text=True, capture_output=True, check=False,
                )
                if result.returncode:
                    raise AssertionError("reviewed app native object is absent: " + key
                        + "\n" + result.stderr)
                provider_objects[key] = json.loads(result.stdout)
        else:
            provider_objects = json.loads(kubectl_state.read_text()) if kubectl_state.exists() else {}
        if set(provider_objects) != expected_objects:
            raise AssertionError("reviewed app apply wrote unexpected native objects: "
                + repr(sorted(provider_objects)))
        if live_kubeconfig:
            if any(not native.get("metadata", {}).get("uid") or
                   not native.get("metadata", {}).get("resourceVersion")
                   for native in provider_objects.values()):
                raise AssertionError("live provider objects lack physical identities")
            deployment = provider_objects[expected_workload]
            if deployment.get("status", {}).get("availableReplicas") != 1:
                raise AssertionError("reviewed worker Deployment is not available")
            images = [container["image"] for container in
                deployment["spec"]["template"]["spec"]["containers"]]
            if images != ["k3d-registry.localhost:5000/isolated:v1"]:
                raise AssertionError("reviewed worker uses an unexpected image: " + repr(images))
        apply_calls = [json.loads(line) for line in kubectl_calls.read_text().splitlines()]
        if sum("create" in call for call in apply_calls) != 2:
            raise AssertionError("reviewed app apply did not create each native member once")
        if any("get" in call and "cache" in call for call in apply_calls):
            raise AssertionError("reviewed app apply observed an unrelated native member")
        calls = marker.read_text().splitlines() if marker.exists() else []
        if not calls or any(Path(call).name != "kubectl" for call in calls):
            raise AssertionError("reviewed app apply invoked an unrelated provider: " + repr(calls))
        print("inventory scope isolation: reviewed app planned and applied without unrelated providers")


if __name__ == "__main__":
    main()
