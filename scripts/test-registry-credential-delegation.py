#!/usr/bin/env python3
"""Run the actual rendered host timer against a private recording Kubernetes API."""
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile


REPO = Path(__file__).resolve().parents[1]
HOST = "platform:host/nixos-system/system"
ACCOUNT = "platform:serving/serving/object-" + "0" * 40
MODULE = Path(os.environ.get("NAGARE_TEST_REGISTRY_MODULE", REPO / "nixos/hosts/nagare-01/registries.nix"))

K3S = r'''#!/usr/bin/env python3
import base64,json,os,sys
from pathlib import Path
p=Path(os.environ["REGISTRY_TEST_STATE"])
s=json.loads(p.read_text())
a=sys.argv[1:]
assert a.pop(0)=="kubectl"
ns=None
if a[:1]==["-n"]: ns=a[1]; a=a[2:]
if a[:2]==["get","--raw=/readyz"]: print("ok"); sys.exit(0)
if a[:2]==["get","namespace"]: sys.exit(0 if a[2]==s["namespace"] else 1)
assert ns==s["namespace"], "effect outside selected namespace"
if a[:2]==["get","secret"]:
    if s["secret"]:
        print(json.dumps(s["secret"]))
        if s.get("secretRace"):
            s["secret"]["metadata"]["resourceVersion"]=str(int(s["secret"]["metadata"]["resourceVersion"])+1)
            s["secretRace"]=False
            p.write_text(json.dumps(s))
            sys.exit(0)
elif a[:2]==["get","serviceaccount"]:
    assert a[2]==s["account"]["metadata"]["name"]
    print(json.dumps(s["account"]))
elif a[:3]==["create","secret","docker-registry"]:
    opts={x.split("=",1)[0]:x.split("=",1)[1] for x in a if "=" in x}
    payload=json.dumps({"auths":{opts["--docker-server"]:{"username":opts["--docker-username"],"password":opts["--docker-password"]}}}).encode()
    print(json.dumps({"apiVersion":"v1","kind":"Secret","metadata":{"name":a[3],"namespace":ns},"type":"kubernetes.io/dockerconfigjson","data":{".dockerconfigjson":base64.b64encode(payload).decode()}}))
elif a[0] in ["create","replace"]:
    value=json.load(sys.stdin)
    current=s["secret"]
    if (a[0]=="create" and current) or (a[0]=="replace" and (not current or value["metadata"].get("resourceVersion")!=current["metadata"]["resourceVersion"])): sys.exit(1)
    value["metadata"]["uid"]=current["metadata"]["uid"] if current else "fixture-secret"
    value["metadata"]["resourceVersion"]=str(int(current["metadata"]["resourceVersion"])+1) if current else "1"
    s["secret"]=value
    s["writes"].append("secret:"+a[0])
elif a[:2]==["patch","serviceaccount"]:
    assert a[2]==s["account"]["metadata"]["name"]
    value=json.loads(a[a.index("-p")+1])
    assert value["metadata"]["resourceVersion"]==s["account"]["metadata"]["resourceVersion"]
    s["account"]["metadata"].setdefault("annotations",{}).update(value["metadata"]["annotations"])
    s["account"]["imagePullSecrets"]=value["imagePullSecrets"]
    s["writes"].append("account:patch")
else: raise AssertionError("unexpected operation: "+str(a[:3]))
p.write_text(json.dumps(s))
'''


def main():
    with tempfile.TemporaryDirectory(prefix="nagare-registry-delegation-") as temporary:
        root = Path(temporary)
        (root / "bin").mkdir()
        (root / "bin/k3s").write_text(K3S)
        (root / "bin/curl").write_text("#!/bin/sh\nprintf '%s\\n' '{\"access_token\":\"fixture-token\",\"expires_in\":3600}'\n")
        (root / "bin/jq").symlink_to(subprocess.check_output(["which", "jq"], text=True).strip())
        for name in ["k3s", "curl"]:
            (root / "bin" / name).chmod(0o700)
        env = os.environ.copy()
        env.update(REGISTRY_TEST_REPO=str(REPO), REGISTRY_TEST_ROOT=str(root), REGISTRY_TEST_MODULE=str(MODULE))
        expression = '''let
          repo = builtins.getEnv "REGISTRY_TEST_REPO";
          flake = builtins.getFlake ("git+file://" + repo);
          root = builtins.getEnv "REGISTRY_TEST_ROOT";
          module = builtins.toPath (builtins.getEnv "REGISTRY_TEST_MODULE");
          pkgs = { lib = flake.inputs.nixpkgs.lib; curl = root; jq = root; coreutils = root;
                   writeShellScript = name: body: body; };
          render = enabled: (import module { inherit pkgs;
            config = { nagare.host = { registryHost = "us-west1-docker.pkg.dev";
              registryCredentialOwner = if enabled then "platform:host/nixos-system/system" else "";
              registryServingControllerOwner = if enabled then "platform:serving/serving/object-0000000000000000000000000000000000000000" else "";
            }; services.k3s.package = root; };
          }).systemd.services.nagare-registry-pull-secret.serviceConfig.ExecStart;
        in { controller = render true; legacy = render false; }'''
        scripts = json.loads(subprocess.check_output(["nix", "eval", "--impure", "--json", "--expr", expression], env=env, text=True))
        for key, body in scripts.items():
            (root / (key + ".sh")).write_text(body)
        account = {"apiVersion": "v1", "kind": "ServiceAccount", "metadata": {
            "namespace": "knative-serving", "name": "controller", "uid": "fixture-account", "resourceVersion": "5",
            "annotations": {"nagare.dev/resource-id": ACCOUNT, "nagare.dev/registry-credential-controller": HOST}}}
        initial = {"namespace": "knative-serving", "account": account, "secret": None, "writes": []}

        def run(state, script="controller"):
            location = root / "state.json"
            location.write_text(json.dumps(state))
            result = subprocess.run(["bash", str(root / (script + ".sh"))], env=env | {"REGISTRY_TEST_STATE": str(location)}, text=True, capture_output=True, timeout=20)
            assert "fixture-token" not in result.stdout + result.stderr, "credential leaked in timer output"
            return result, json.loads(location.read_text())

        result, created = run(initial)
        assert result.returncode == 0, result.stderr
        assert created["writes"] == ["secret:create", "account:patch"], "controller credential target missing"
        assert created["secret"]["metadata"]["annotations"]["nagare.dev/resource-id"] == HOST
        assert created["account"]["metadata"]["annotations"]["nagare.dev/resource-id"] == ACCOUNT
        assert created["account"]["imagePullSecrets"] == [{"name": "nagare-registry-pull"}]
        result, replaced = run(created)
        assert result.returncode == 0 and replaced["secret"]["metadata"]["uid"] == "fixture-secret"
        assert replaced["secret"]["metadata"]["resourceVersion"] == "2"

        negatives = []
        for key, value in [("nagare.dev/resource-id", "foreign-account"), ("nagare.dev/registry-credential-controller", "foreign-host")]:
            changed = json.loads(json.dumps(initial))
            changed["account"]["metadata"]["annotations"][key] = value
            negatives.append(changed)
        for key, value in [("nagare.dev/delegated-owner", "foreign-timer"), ("nagare.dev/resource-id", "foreign-secret")]:
            changed = json.loads(json.dumps(created))
            changed["writes"] = []
            changed["secret"]["metadata"]["annotations"][key] = value
            negatives.append(changed)
        changed = json.loads(json.dumps(created))
        changed["writes"] = []
        changed["account"]["imagePullSecrets"] = [{"name": "foreign-pull"}]
        negatives.append(changed)
        changed = json.loads(json.dumps(created))
        changed["writes"] = []
        changed["secretRace"] = True
        negatives.append(changed)
        for state in negatives:
            result, refused = run(state)
            assert result.returncode != 0 and refused["writes"] == [], "foreign/raced target received a write"

        legacy = {"namespace": "personal", "account": {"metadata": {"name": "default", "resourceVersion": "5"}}, "secret": None, "writes": []}
        result, retained = run(legacy, "legacy")
        assert result.returncode == 0 and retained["writes"] == ["secret:create", "account:patch"]
        assert "nagare.dev/resource-id" not in retained["secret"]["metadata"]["annotations"]
        print("registry timer: owned controller create/refresh, six foreign/race refusals and legacy policy passed")


if __name__ == "__main__":
    main()
