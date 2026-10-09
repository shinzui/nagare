#!/usr/bin/env python3
"""Generate an exact, ordered disposal script for one disposable Nagare cloud context.

Input: the context's own `pulumi stack export`, plus the names outside the stack (state bucket,
host image). Output: a bash script whose every command names one exact resource from that export.
Nothing is matched by prefix, label or project-wide listing, except snapshots, which are selected
at run time by their exact source disk. The script refuses unless gcloud's project is the expected
one, and it runs in dry mode (prints only) unless DISPOSE_EXECUTE=1.
"""
import json, sys, argparse, shlex

p = argparse.ArgumentParser()
p.add_argument("--export", required=True)
p.add_argument("--project", required=True)
p.add_argument("--state-bucket", required=True)
p.add_argument("--image", required=True)
p.add_argument("--expect-suffix", required=True, help="every instance/bucket/repo/SA name must contain this, e.g. c3-1008")
a = p.parse_args()

res = [r for r in json.load(open(a.export))["deployment"]["resources"] if r["type"].startswith("gcp:")]
by = {}
for r in res:
    by.setdefault(r["type"].split(":")[-1], []).append(r)

def ids(kind):
    return [r["id"] for r in by.get(kind, [])]

def base(i):
    return i.rstrip("/").split("/")[-1]

def one(kind):
    v = ids(kind)
    if len(v) != 1:
        sys.exit(f"expected exactly one {kind}, found {v}")
    return v[0]

P = a.project
inst = one("Instance"); zone = inst.split("/zones/")[1].split("/")[0]; inst_name = base(inst)
region = zone.rsplit("-", 1)[0]
sa_email = base(one("Account"))
repo = base(one("Repository"))
for name in (inst_name, sa_email, repo, a.state_bucket, *ids("Bucket")):
    if a.expect_suffix not in name:
        sys.exit(f"{name} does not carry the context suffix {a.expect_suffix}")

cmds = []
def c(s):
    cmds.append(s)

c(f"gcloud compute instances update {inst_name} --zone {zone} --no-deletion-protection")
for i in ids("GlobalForwardingRule"): c(f"gcloud compute forwarding-rules delete {base(i)} --global")
for i in ids("TargetHttpsProxy"): c(f"gcloud compute target-https-proxies delete {base(i)}")
for i in ids("TargetHttpProxy"): c(f"gcloud compute target-http-proxies delete {base(i)}")
for i in ids("URLMap"): c(f"gcloud compute url-maps delete {base(i)} --global")
for i in ids("BackendService"): c(f"gcloud compute backend-services delete {base(i)} --global")
for i in ids("HealthCheck"): c(f"gcloud compute health-checks delete {base(i)} --global")
for i in ids("ManagedSslCertificate"): c(f"gcloud compute ssl-certificates delete {base(i)} --global")
for i in ids("GlobalAddress"): c(f"gcloud compute addresses delete {base(i)} --global")
for i in ids("InstanceGroup"): c(f"gcloud compute instance-groups unmanaged delete {base(i)} --zone {zone}")
c(f"gcloud compute instances delete {inst_name} --zone {zone}")
rp = ids("ResourcePolicy")
for d in ids("Disk"):
    dn = base(d)
    for r in rp: c(f"gcloud compute disks remove-resource-policies {dn} --zone {zone} --resource-policies {base(r)}")
    c(f"gcloud compute disks delete {dn} --zone {zone}")
    c(f"for s in $(gcloud compute snapshots list --filter='sourceDisk~/zones/{zone}/disks/{dn}$' --format='value(name)'); do gcloud compute snapshots delete \"$s\"; done")
for r in rp: c(f"gcloud compute resource-policies delete {base(r)} --region {region}")
c(f"gcloud compute images delete {a.image}")
zones = ids("ManagedZone")
for r in by.get("RecordSet", []):
    z, rest = r["id"].split("/managedZones/")[1].split("/rrsets/")
    name, typ = rest.rsplit("/", 1)
    c(f"gcloud dns record-sets delete '{name}' --type {typ} --zone {z}")
for z in zones: c(f"gcloud dns managed-zones delete {base(z)}")
for i in ids("Firewall"): c(f"gcloud compute firewall-rules delete {base(i)}")
for i in ids("Subnetwork"): c(f"gcloud compute networks subnets delete {base(i)} --region {region}")
for i in ids("Network"): c(f"gcloud compute networks delete {base(i)}")
for i in ids("Address"): c(f"gcloud compute addresses delete {base(i)} --region {region}")
for m in ids("IAMMember"):
    role = "roles/" + m.split("/roles/")[1].split("/")[0]
    c(f"gcloud projects remove-iam-policy-binding {P} --member serviceAccount:{sa_email} --role {role} --condition=None")
c(f"gcloud iam service-accounts delete {sa_email}")
c(f"gcloud artifacts repositories delete {repo} --location {region}")
for b in ids("Bucket"): c(f"gcloud storage rm --recursive --all-versions gs://{b}")
c(f"gcloud storage rm --recursive --all-versions gs://{a.state_bucket}")

print("#!/usr/bin/env bash")
print(f"# Exact disposal of {inst_name} in {P}, generated from its own Pulumi stack export ({len(res)} gcp resources) plus the state bucket and host image.")
print("set -euo pipefail")
print(f"export CLOUDSDK_ACTIVE_CONFIG_NAME=labs CLOUDSDK_CORE_PROJECT={P} CLOUDSDK_CORE_DISABLE_PROMPTS=true")
print(f"[ \"$(gcloud config get-value core/project 2>/dev/null)\" = {P} ] || {{ echo 'REFUSED: gcloud project is not {P}'; exit 1; }}")
print('run() { echo "+ $*"; if [ "${DISPOSE_EXECUTE:-0}" = 1 ]; then bash -c "$*" || { echo "STOPPED at: $*"; exit 1; }; fi; }')
for s in cmds:
    print("run " + shlex.quote(s))
print('echo DISPOSE-DONE')
