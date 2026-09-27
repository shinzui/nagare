#!/usr/bin/env python3
"""Record reviewed kubectl writes for the public bootstrap interruption fixture."""

import json
import os
import pathlib
import subprocess
import sys


state = pathlib.Path(os.environ["XDG_STATE_HOME"])
store = state / "kubectl-objects"
store.mkdir(exist_ok=True)
args = sys.argv[1:]
with (state / "kubectl.log").open("a", encoding="utf-8") as log:
    log.write(" ".join(args) + "\n")
if os.environ.get("KUBECONFIG") != os.environ["NAGARE_TEST_KUBECONFIG_DESTINATION"]:
    raise SystemExit("kubectl was not given the reviewed context kubeconfig")


def option(name, default=None):
    if name in args:
        return args[args.index(name) + 1]
    return default


def key(kind, name, namespace):
    return store / (kind.replace("/", "_") + "__" + (namespace or "_") + "__" + name + ".json")


if "version" in args and "-o" in args:
    print('{"serverVersion":{"gitVersion":"v1.34.6+k3s1"}}')
    raise SystemExit(0)

if "rollout" in args or "wait" in args:
    raise SystemExit(0)

if "get" in args:
    position = args.index("get")
    if args[position + 1] in ("nodes", "node"):
        print('{"items":[{"metadata":{"name":"k3d-nagare-local-server-0",'
              '"labels":{"node-role.kubernetes.io/control-plane":""}}}]}')
        raise SystemExit(0)
    kind = args[position + 1]
    name = args[position + 2]
    namespace = option("-n") or option("--namespace")
    if kind == "secret" and name.startswith("sh.helm.release.v1."):
        print('{"metadata":{"uid":"fixture-helm-secret"}}')
        raise SystemExit(0)
    if (state / "unresolved-get").exists():
        raise SystemExit("simulated unavailable Kubernetes observation")
    if (kind == "configmap" and name == "nagare-platform-version"
            and os.environ.get("NAGARE_TEST_NATIVE_MARKER") == "1"):
        os.execv(os.environ["NAGARE_TEST_REAL_KUBECTL"],
                 [os.environ["NAGARE_TEST_REAL_KUBECTL"], *args])
    path = key(kind, name, namespace)
    if path.exists():
        print(path.read_text())
    raise SystemExit(0)

if "create" in args and option("-f") == "-":
    value = json.load(sys.stdin)
    metadata = value.setdefault("metadata", {})
    kind = value["kind"].lower()
    api_group = value.get("apiVersion", "v1").split("/")[0]
    if "/" in value.get("apiVersion", "v1"):
        kind += "." + api_group
    name = metadata["name"]
    namespace = metadata.get("namespace")
    path = key(kind, name, namespace)
    if path.exists():
        raise SystemExit("fixture object already exists")
    if name == "nagare-platform-version" and (state / "fail-marker-before").exists():
        (state / "fail-marker-before").rename(state / "failed-marker-before")
        raise SystemExit("simulated interruption just before the final marker")
    if name == "nagare-platform-version" and os.environ.get("NAGARE_TEST_NATIVE_MARKER") == "1":
        result = subprocess.run([os.environ["NAGARE_TEST_REAL_KUBECTL"], *args],
                                input=json.dumps(value), text=True,
                                capture_output=True, check=False)
        if result.returncode:
            sys.stderr.write(result.stderr)
            raise SystemExit(result.returncode)
        observed = subprocess.run(
            [os.environ["NAGARE_TEST_REAL_KUBECTL"], "--context", option("--context"),
             "-n", namespace, "get", "configmap", name, "-o", "json"],
            text=True, capture_output=True, check=False)
        if observed.returncode:
            sys.stderr.write(observed.stderr)
            raise SystemExit(observed.returncode)
        path.write_text(observed.stdout)
        with (state / "kubectl-writes").open("a", encoding="utf-8") as writes:
            writes.write(kind + "/" + name + "\n")
        print(result.stdout, end="")
        raise SystemExit(0)
    metadata["uid"] = "fixture-" + str(len(list(store.glob("*.json"))) + 1)
    metadata["resourceVersion"] = "1"
    metadata["generation"] = 1
    status = value.setdefault("status", {})
    status["observedGeneration"] = 1
    status["conditions"] = [
        {"type": condition, "status": "True"}
        for condition in ("Complete", "Established", "Ready", "Available")
    ]
    status["readyReplicas"] = value.get("spec", {}).get("replicas", 1)
    status["updatedReplicas"] = status["readyReplicas"]
    path.write_text(json.dumps(value, sort_keys=True))
    with (state / "kubectl-writes").open("a", encoding="utf-8") as writes:
        writes.write(kind + "/" + name + "\n")
    if (state / "fail-cluster-ack").exists():
        (state / "fail-cluster-ack").rename(state / "failed-cluster-ack")
        raise SystemExit("simulated lost cluster component acknowledgement")
    if name == "nagare-platform-version" and (state / "fail-marker-ack").exists():
        (state / "fail-marker-ack").rename(state / "failed-marker-ack")
        raise SystemExit("simulated lost final marker acknowledgement")
    print(json.dumps(value, sort_keys=True))
    raise SystemExit(0)

raise SystemExit("unexpected kubectl command: " + " ".join(args))
