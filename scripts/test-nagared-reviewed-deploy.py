#!/usr/bin/env python3
"""Submit a signed push through nagared, inventory review, and a recording provider."""

import hashlib
import hmac
import http.client
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent


def command(arguments, environment, cwd=ROOT, timeout=None):
    result = subprocess.run(arguments, cwd=cwd, env=environment, text=True,
                            capture_output=True, check=False, timeout=timeout)
    if result.returncode:
        raise AssertionError(f"{arguments!r} failed:\n{result.stdout}{result.stderr}")
    return result.stdout.strip()


def bundle(declarations):
    return {"declarations": declarations, "exports": [], "conditions": [],
            "contributions": [], "operations": [], "grants": []}


def seed_history(cli, scratch, environment, destination):
    fixture = json.loads((ROOT / "cli/nagarectl/test/fixtures/inventory/valid.json").read_text())
    foundation = fixture["snapshot"][0]["declaration"]
    namespace = {
        "identity": "platform:foundation/foundation/namespace-personal",
        "owner": foundation["scope"], "executor": "KubernetesExecutor",
        "address": {"tag": "Kubernetes", "contents": [
            "platform:foundation/cluster/cluster", "", "namespace", None, "personal"]},
        "aliases": [], "spec": {"tag": "NativeObject", "contents": "e" * 64},
        "lifecycle": "Retain", "dataPolicy": {"tag": "Stateless"},
        "sensitivity": "Public", "dependencies": [], "delegations": [],
        "source": {"file": "fixture", "path": "personal"},
    }
    foundation["bundles"][0]["declarations"].append({"tag": "Managed", "contents": namespace})
    image_owner = {"kind": "Publication", "name": "webhook-image"}
    image_id = "publication:webhook-image/webhook/oci-image"
    image_scope = {"version": 1, "scope": image_owner, "bundles": [bundle([{
        "tag": "Managed", "contents": {
            "identity": image_id, "owner": image_owner,
            "executor": "ArtifactExecutor",
            "address": {"tag": "Artifact", "contents": ["webhook", "f" * 64]},
            "aliases": [], "spec": {"tag": "ArtifactPublication", "contents": [
                "oci-image", destination, "a" * 64, False]},
            "lifecycle": "Retain", "dataPolicy": {"tag": "Stateless"},
            "sensitivity": "Private", "dependencies": [], "delegations": [],
            "source": {"file": "fixture", "path": "webhook-image"},
        },
    }])]}
    overlay_owner = {"kind": "Application", "name": "webhook-env"}
    overlay_members = []
    for scope in ("runtime", "preview"):
        for kind, prefix in (("configmap", "nagare-env-"),
                             ("secret", "nagare-secret-")):
            overlay_members.append({"tag": "Managed", "contents": {
                "identity": f"application:webhook-env/{scope}/{kind}",
                "owner": overlay_owner, "executor": "KubernetesExecutor",
                "address": {"tag": "Kubernetes", "contents": [
                    "platform:foundation/cluster/cluster", "", kind, "personal",
                    f"{prefix}webhook-test-{scope}"]},
                "aliases": [], "spec": {"tag": "NativeObject", "contents": "b" * 64},
                "lifecycle": "Retain", "dataPolicy": {"tag": "Stateless"},
                "sensitivity": "Private", "dependencies": [], "delegations": [],
                "source": {"file": "fixture", "path": f"{scope}/{kind}"},
            }})
    overlay_scope = {"version": 1, "scope": overlay_owner,
                     "bundles": [bundle(overlay_members)]}
    candidate = {
        "version": 1, "context": {"identity": "guarded", "project": "project"},
        "base": [{"scope": foundation["scope"], "generation": 7},
                 {"scope": image_owner, "generation": 1},
                 {"scope": overlay_owner, "generation": 1}],
        "snapshot": [{"generation": 7, "declaration": foundation},
                     {"generation": 1, "declaration": image_scope},
                     {"generation": 1, "declaration": overlay_scope}],
        "reservations": [],
        "changes": [{"replace": {"version": 1,
            "scope": {"kind": "Application", "name": "seed"},
            "bundles": [bundle([])]}}],
    }
    input_file = scratch / "candidate.json"
    input_file.write_text(json.dumps(candidate))
    compiled = scratch / "compiled"
    review = scratch / "seed-review"
    command([cli, "inventory", "compile", "--input", str(input_file),
             "--out", str(compiled)], environment)
    command([cli, "--context", "guarded", "inventory", "plan", "--inventory",
             str(compiled), "--out", str(review)], environment)
    command([cli, "--context", "guarded", "inventory", "apply", str(review), "--yes"],
            environment)
    return image_id, [member["contents"]["identity"] for member in overlay_members]


def make_provider(scratch, live_kubectl=None):
    binary = scratch / "bin"
    binary.mkdir()
    state = scratch / "objects.json"
    calls = scratch / "kubectl-calls.jsonl"
    errors = scratch / "kubectl-errors.jsonl"
    kubectl = binary / "kubectl"
    kubectl.write_text("""#!/usr/bin/env python3
import json
from pathlib import Path
import subprocess
import sys

state = Path(%r)
calls = Path(%r)
errors = Path(%r)
args = sys.argv[1:]
with calls.open("a") as output:
    output.write(json.dumps(args) + "\\n")
live_binary = %r
if live_binary is not None:
    result = subprocess.run([live_binary, *args], stdin=sys.stdin.buffer,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    sys.stdout.buffer.write(result.stdout)
    sys.stderr.buffer.write(result.stderr)
    if result.returncode:
        with errors.open("a") as output:
            output.write(json.dumps({"args": args, "code": result.returncode,
                "stderr": result.stderr.decode(errors="replace")}) + "\\n")
    sys.exit(result.returncode)
objects = json.loads(state.read_text()) if state.exists() else {}
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
    state.write_text(json.dumps(objects, sort_keys=True))
    print(json.dumps(native, separators=(",", ":")))
    sys.exit(0)
if "wait" in args and any(value.startswith("ksvc/") for value in args):
    sys.exit(0)
sys.exit(95)
""" % (str(state), str(calls), str(errors), live_kubectl))
    kubectl.chmod(0o755)
    return binary, state, calls, errors


def make_repo(scratch, environment):
    repo = scratch / "source"
    config_dir = repo / "nagare"
    config_dir.mkdir(parents=True)
    example = (ROOT / "cluster/examples/static-site/nagare/Config.hs").read_text()
    (config_dir / "Config.hs").write_text(example.replace('"static-site"', '"webhook-test"'))
    (repo / "public").mkdir()
    (repo / "public/index.html").write_text("webhook test\n")
    command(["git", "init", "-b", "main"], environment, repo)
    command(["git", "add", "."], environment, repo)
    git_environment = environment | {"GIT_AUTHOR_NAME": "Nagare Test",
        "GIT_AUTHOR_EMAIL": "test@example.invalid", "GIT_COMMITTER_NAME": "Nagare Test",
        "GIT_COMMITTER_EMAIL": "test@example.invalid",
        "GIT_AUTHOR_DATE": "2026-09-26T00:00:00Z",
        "GIT_COMMITTER_DATE": "2026-09-26T00:00:00Z"}
    command(["git", "commit", "-m", "test: seed reviewed webhook fixture"], git_environment, repo)
    return repo, command(["git", "rev-parse", "HEAD"], environment, repo)


def deliver(port, sha, repo, preview=False, timeout=60):
    if preview:
        named_repo = {"clone_url": repo.as_uri(), "full_name": "fixture/site"}
        event = {"action": "opened", "number": 7, "pull_request": {
            "head": {"ref": "feature", "sha": sha, "repo": named_repo},
            "base": {"repo": named_repo}}}
    else:
        event = {"ref": "refs/heads/main", "after": sha,
                 "repository": {"clone_url": repo.as_uri(),
                                "full_name": "fixture/site"}}
    body = json.dumps(event, separators=(",", ":")).encode()
    signature = hmac.new(b"topsecret", body, hashlib.sha256).hexdigest()
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        connection.request("POST", "/webhooks/github/static/webhook-test", body,
            {"X-GitHub-Event": "pull_request" if preview else "push",
             "X-Hub-Signature-256": "sha256=" + signature,
             "Content-Type": "application/json"})
        response = connection.getresponse()
        return response.status, response.read().decode()
    finally:
        connection.close()


def main():
    if len(sys.argv) not in (3, 7) or (len(sys.argv) == 7 and sys.argv[3] != "--live-context"):
        raise SystemExit("usage: test-nagared-reviewed-deploy.py BUILT_NAGARED BUILT_NAGARECTL "
            "[--live-context K3D_CONTEXT REGISTRY_HOST SOURCE_IMAGE]")
    nagared, cli = (str(Path(argument).resolve(strict=True)) for argument in sys.argv[1:3])
    live_context = sys.argv[4] if len(sys.argv) == 7 else None
    registry_host = sys.argv[5] if live_context else "k3d-registry.localhost:5000"
    source_image = sys.argv[6] if live_context else None
    if live_context and not live_context.startswith("k3d-nagare-inventory-"):
        raise SystemExit("live provider mode requires a disposable nagare inventory k3d context")
    live_kubectl = shutil.which("kubectl") if live_context else None
    if live_context and not live_kubectl:
        raise SystemExit("live provider mode requires kubectl")
    with tempfile.TemporaryDirectory(prefix="nagared-reviewed-deploy-") as temporary:
        scratch = Path(temporary)
        context_dir = scratch / "config/nagare/contexts"
        context_dir.mkdir(parents=True)
        (context_dir / "guarded.env").write_text(
            "CLOUDSDK_CORE_PROJECT=project\nNAGARE_MODE=local\n"
            f"NAGARE_REGISTRY_HOST={registry_host}\n"
            "NAGARE_BASE_DOMAIN=127-0-0-1.sslip.io\n"
            "NAGARE_LOCAL_OBJECT_STORE=http://minio:9000/nagare-backups\n")
        binary, state, calls, errors = make_provider(scratch, live_kubectl)
        environment = {key: value for key, value in os.environ.items()
            if not key.startswith("NAGARE_") and not key.startswith("CLOUDSDK_")}
        environment.update({"XDG_CONFIG_HOME": str(scratch / "config"),
            "XDG_STATE_HOME": str(scratch / "state"), "NAGARE_CONTEXT": "guarded",
            "NAGARE_MODE": "local", "NAGARE_WEBHOOK_SECRET": "topsecret",
            "CLOUDSDK_CORE_PROJECT": "project",
            "PATH": str(binary) + os.pathsep + os.environ.get("PATH", "")})
        if live_context:
            kubeconfig = scratch / "kubeconfig"
            kubeconfig.write_text(command([live_kubectl, "config", "view", "--raw",
                "--minify", "--context", live_context], os.environ.copy()) + "\n")
            command([live_kubectl, "--kubeconfig", str(kubeconfig), "config",
                "rename-context", live_context, "guarded"], os.environ.copy())
            environment["KUBECONFIG"] = str(kubeconfig)
            command([live_kubectl, "--context", "guarded", "-n", "knative-serving",
                "rollout", "status", "deployment/webhook", "--timeout=45s"],
                environment, timeout=70)
            for kind, name in (("ksvc", "webhook-test"),
                               ("configmap", "nagare-static-releases-webhook-test")):
                existing = command([live_kubectl, "--context", "guarded", "-n",
                    "personal", "get", kind, name, "--ignore-not-found", "-o", "name"],
                    environment, timeout=30)
                assert not existing, "disposable native fixture already exists: " + existing
        ghc_version = command(["ghc", "--numeric-version"], environment)
        ghc_matches = list((ROOT / "cli/nagarectl").glob(
            ".ghc.environment.*-" + ghc_version))
        assert len(ghc_matches) == 1, "expected one GHC package environment for " + ghc_version
        ghc_environment = ghc_matches[0]
        repo, sha = make_repo(scratch, environment)
        destination = registry_host + "/project/nagare/webhook-test:" + sha[:12]
        if source_image:
            command(["docker", "tag", source_image, destination], environment)
            command(["docker", "push", destination], environment)
        image_id, overlay_ids = seed_history(cli, scratch, environment, destination)
        assert not calls.exists(), "history seeding invoked a provider"
        reviewed_output = scratch / "reviewed-command-output.txt"
        reviewed_arguments = scratch / "reviewed-command-arguments.jsonl"
        reviewed_command = binary / "reviewed-site-command"
        reviewed_command.write_text("""#!/usr/bin/env python3
import json
import subprocess
import sys
from pathlib import Path

with Path(%r).open("a") as output:
    output.write(json.dumps(sys.argv[1:]) + "\\n")
result = subprocess.run([%r, *sys.argv[1:]], text=True, capture_output=True)
Path(%r).write_text(result.stdout + result.stderr)
sys.exit(result.returncode)
""" % (str(reviewed_arguments), cli, str(reviewed_output)))
        reviewed_command.chmod(0o755)
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        process = subprocess.Popen([nagared, "--port", str(port), "--workspace",
            str(scratch / "workspace"), "--nagarectl-bin", str(reviewed_command), "--ghc-env",
            str(ghc_environment)], cwd=ROOT / "cli/nagarectl", env=environment,
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            for _ in range(100):
                if process.poll() is not None:
                    raise AssertionError(process.stderr.read().decode())
                try:
                    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=1)
                    connection.request("GET", "/healthz")
                    healthy = connection.getresponse().status == 200
                    connection.close()
                    if healthy:
                        break
                except (OSError, TimeoutError):
                    time.sleep(0.1)
            else:
                raise AssertionError("nagared did not become healthy")
            status, response = deliver(port, sha, repo,
                timeout=360 if live_context else 60)
            assert status == 200, (status, response,
                reviewed_output.read_text() if reviewed_output.exists() else "",
                errors.read_text() if errors.exists() else "",
                process.stderr.read().decode() if process.poll() is not None else "")
            assert response.strip() == "reviewed site deployed: " + sha[:12], response
            head = json.loads((scratch / "state/nagare/guarded/inventory/head.json").read_text())
            names = {entry["scope"]["name"] for entry in head["accepted"]}
            assert "webhook-image" in names and "site-webhook-test" in names, names
            if live_context:
                service = json.loads(command([live_kubectl, "--context", "guarded", "-n",
                    "personal", "get", "ksvc", "webhook-test", "-o", "json"], environment))
                assert service["metadata"].get("uid"), service
                objects = {"personal:service:webhook-test": service}
                assert service.get("status", {}).get("conditions"), service
            else:
                objects = json.loads(state.read_text())
                assert "personal:service:webhook-test" in objects, objects.keys()
                assert any(key.startswith("personal:configmap:") for key in objects), objects.keys()
            invocations = [json.loads(line) for line in calls.read_text().splitlines()]
            assert sum("create" in args for args in invocations) >= len(objects), invocations
            submitted = [json.loads(line) for line in reviewed_arguments.read_text().splitlines()]
            assert len(submitted) == 1 and submitted[0][submitted[0].index("--image-resource") + 1] == image_id, submitted
            prior_revisions = {entry["scope"]["name"]: entry["revision"]
                for entry in head["accepted"]}
            if live_context:
                print("nagared reviewed deploy: signed push converged against native Knative provider")
                return
            status, response = deliver(port, sha, repo, preview=True)
            assert status == 200, (status, response,
                reviewed_output.read_text() if reviewed_output.exists() else "")
            assert response.strip() == "reviewed site deployed: " + sha[:12], response
            after = json.loads((scratch / "state/nagare/guarded/inventory/head.json").read_text())
            current_revisions = {entry["scope"]["name"]: entry["revision"]
                for entry in after["accepted"]}
            assert all(current_revisions[name] == revision for name, revision
                in prior_revisions.items()), "preview changed a prior scope revision"
            assert any("pr-7" in name for name in current_revisions), current_revisions
            preview_objects = json.loads(state.read_text())
            assert len(preview_objects) > len(objects), "preview did not create provider objects"
            preview_service = preview_objects["personal:service:webhook-test-pr-pr-7"]
            references = preview_service["spec"]["template"]["spec"]["containers"][0]["envFrom"]
            assert references == [
                {"configMapRef": {"name": "nagare-env-webhook-test-runtime", "optional": True}},
                {"secretRef": {"name": "nagare-secret-webhook-test-runtime", "optional": True}},
                {"configMapRef": {"name": "nagare-env-webhook-test-preview", "optional": True}},
                {"secretRef": {"name": "nagare-secret-webhook-test-preview", "optional": True}},
            ], references
            submitted = [json.loads(line) for line in reviewed_arguments.read_text().splitlines()]
            assert len(submitted) == 2, submitted
            preview_args = submitted[1]
            selected_stores = [preview_args[index + 1] for index, value
                in enumerate(preview_args) if value == "--preview-env-resource"]
            assert set(selected_stores) == set(overlay_ids), selected_stores
            print("nagared reviewed deploy: signed push and preview converged through inventory and provider")
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
            if live_context:
                for kind, name in (("ksvc", "webhook-test"),
                                   ("configmap", "nagare-static-releases-webhook-test")):
                    try:
                        subprocess.run([live_kubectl, "--context", "guarded", "-n",
                            "personal", "delete", kind, name, "--ignore-not-found",
                            "--wait=false"], env=environment, capture_output=True,
                            check=False, timeout=20)
                    except subprocess.TimeoutExpired:
                        pass


if __name__ == "__main__":
    main()
