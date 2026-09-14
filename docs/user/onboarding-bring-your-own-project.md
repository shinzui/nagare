---
type: Tutorial
title: "Bring-your-own-project onboarding"
description: "Onboard a new Google Cloud project and complete the first Nagare platform setup from prerequisites through verification."
docId: DOC-24
tags: [onboarding, gcp, contexts, tutorial]
generated:
  by: human:nadeem
  at: 2026-08-25T20:53:35Z
---

# Bring-your-own-project onboarding

> **Status:** 🟡 Built and hermetically rehearsed — this is the consolidated zero-to-running
> runbook. A disposable-project rehearsal of the complete sequence is still required. Each
> numbered step carries its own real status badge inline, so you are never misled
> about what is built. For laptop-only testing without GCP, use
> [Local development](local-development.md) instead.

From an empty GCP project and a domain you own to a running Nagare cluster, using only this
page and the pages it links. Commands use the placeholders `CURRENT_RELEASE_TAG`,
`CONTEXT_NAME`, `PROJECT_ID`, and `BASE_DOMAIN`; replace every placeholder before running it.
For new setups, put those values in a named [target context](contexts.md), such as `prod` or
`labs`.

**Before you begin:**

1. The GCP-side setup from [GCP prerequisites](gcp-prerequisites.md) is done.
2. You installed the pinned full operator package from [Installing Nagare](installation.md).

---

## Step 0 — Workstation + pinned release  ✅

Install [Nix](https://nixos.org/download), select the newest release you have reviewed from
[Nagare releases](https://github.com/shinzui/nagare/releases), and install its operator package.
Replace `CURRENT_RELEASE_TAG` with that immutable tag (including the leading `v`) and confirm its
release notes include the bootstrap interfaces used below:

```bash
export NAGARE_RELEASE=CURRENT_RELEASE_TAG
nix profile install "github:shinzui/nagare/${NAGARE_RELEASE}#nagare"
nagarectl version --json
```

The `nagare` launcher resolves its immutable payload and writable context workspace, so everything
below runs from any directory. Install the external cloud and Kubernetes clients listed in
[getting started](getting-started.md); a Nagare checkout is not required.

## Step 1 — GCP prerequisites  ✅

Follow [GCP prerequisites](gcp-prerequisites.md) once. In short: an authenticated
`gcloud` **plus ADC**; the six operator IAM roles (or `roles/owner`); a project with
billing; the service APIs enabled (or let `nagarectl init` enable them); and a domain
ready to delegate. Don't repeat the detail here — follow the linked page.

Before initialization, explicitly bind both interactive gcloud and ADC quota attribution to the
project you are bringing:

```bash
gcloud auth login
gcloud auth application-default login
export PROJECT_ID=YOUR_DISPOSABLE_OR_TARGET_PROJECT_ID
export CONTEXT_NAME=YOUR_CONTEXT_NAME
export BASE_DOMAIN=apps.yourdomain.example
gcloud config set project "$PROJECT_ID"
gcloud auth application-default set-quota-project "$PROJECT_ID"
```

Nagare context selection does not switch ADC. `nagarectl init` checks the selected ADC file before
writing the context and refuses if its `quota_project_id` names another project.

## Step 2 — `nagarectl init`  ✅

This is the centerpiece. It is the **one** command that writes a target context
and drives that context's Pulumi config projection — you do not hand-edit either
for onboarding.

```bash
nagarectl init "$CONTEXT_NAME" --project "$PROJECT_ID" --base-domain "$BASE_DOMAIN" \
  --machine-type e2-standard-4 --boot-disk-type pd-balanced \
  --boot-disk-size-gb 100 --data-disk-size-gb 100 \
  --acme-email you@yourdomain.com
# On a TTY it also prompts for the four VM-shape values.
export NAGARE_WORKSPACE_ROOT="$(nagarectl platform root --json | jq -er '.workspaceRoot')"
```

Flags (exactly as shipped):

| Flag | Effect |
|------|--------|
| `--project` | GCP project id. Supplying it makes the run non-interactive. |
| `--region` | Compute region (default `us-west1`). |
| `--zone` | Compute zone (default `us-west1-a`). |
| `--base-domain` | Apps base domain (default `apps.example.com`). |
| `--machine-type` | GCE machine type (default `e2-standard-2`; use `e2-standard-4` when installing observability). |
| `--boot-disk-type` | Boot disk type (default `pd-balanced`; changing it later replaces the VM). |
| `--boot-disk-size-gb` | Boot disk size in GB (default `100`; changing it on a live VM replaces the instance and its boot-resident k3s state). Size it for the VM lifetime. |
| `--data-disk-size-gb` | Protected data disk size in GB (default `100`). |
| `--acme-email` | **Required.** The Let's Encrypt contact address for this context's cluster. There is no default — any default would be somebody's real mailbox. On a TTY you are prompted; without a TTY and without the flag the run exits non-zero naming it. See [ACME identity](contexts.md#acme-identity). |
| `--acme-directory` | ACME service: `production` (default), `staging` (untrusted certificates, far looser rate limits — use it to rehearse issuance on a new domain), or an absolute `https://` directory URL. |
| `--force` | Overwrite an existing named context, or an existing `nagare.target.env` in legacy mode. |
| `--skip-preflight` | Skip the gcloud-auth + operator-IAM checks. |
| `--skip-enable` | Skip running `scripts/enable-apis.sh`. |
| `--skip-seed` | Skip seeding the Pulumi stack config. |
| `--dry-run` | Show what would be written/enabled/seeded, doing none of it. |

There is **no** `--yes` / `--non-interactive` flag — supplying `--project` **and**
`--acme-email` is what makes the run non-interactive. Those are the two fields
with no safe default; supply either alone on a TTY and you are still prompted for
the other.

Ordered effect: resolve defaults → **preflight** (gcloud active account + the six operator
IAM roles) → write the named context (the same `export` lines shown below) and make it
current → **enable** the six APIs →
**seed** twelve Pulumi stack-config keys for that context (`gcp:project`, `gcp:region`, `gcp:zone`,
`nagare:baseDomain`, `nagare:imageBucket`, `nagare:backupBucket`, `nagare:artifactRegistryId`,
`nagare:instanceName`, `nagare:machineType`, `nagare:bootDiskType`,
`nagare:bootDiskSizeGb`, `nagare:dataDiskSizeGb`) → print next steps.

The generated context is your single source of truth. `nagarectl context show "$CONTEXT_NAME"`
prints it in the same flat format:

```bash
export CLOUDSDK_CORE_PROJECT=YOUR_PROJECT_ID
export CLOUDSDK_COMPUTE_REGION=us-west1
export CLOUDSDK_COMPUTE_ZONE=us-west1-a
export NAGARE_REGISTRY_HOST=us-west1-docker.pkg.dev      # derived as <region>-docker.pkg.dev
export NAGARE_ARTIFACT_REGISTRY_ID=nagare
export NAGARE_IMAGE_BUCKET=YOUR_PROJECT_ID-nagare-images   # derived as <project>-nagare-images
export NAGARE_BACKUP_BUCKET=YOUR_PROJECT_ID-nagare-backups # derived as <project>-nagare-backups
export NAGARE_BASE_DOMAIN=apps.yourdomain.example
export NAGARE_ACME_EMAIL=you@yourdomain.com               # YOUR Let's Encrypt contact; no default
export NAGARE_ACME_DIRECTORY=production                   # or `staging` while rehearsing issuance
export NAGARE_INSTANCE_NAME=nagare-01
export NAGARE_MACHINE_TYPE=e2-standard-4
export NAGARE_BOOT_DISK_TYPE=pd-balanced
export NAGARE_BOOT_DISK_SIZE_GB=100
export NAGARE_DATA_DISK_SIZE_GB=100
```

Those four shape values are recorded in the context, so later source releases
cannot silently change the shape of this stack through a fallback literal.

If you omit `NAME`, `nagarectl init` keeps the legacy behavior and writes
`./nagare.target.env`. That path is still supported, but named contexts are the
multi-target workflow.

`init` does **not** do the next two host-identity steps (SSH key, age key, Tailscale key) or the
Docker-auth step — its printed "Next steps" stop at the `just` recipes. Do them now, in
order.

## Step 3 — Select the operator SSH public key  ✅

Choose one or more public-key files. Nagare reads only public `.pub` files and rejects private-key
material. Do not edit the packaged NixOS modules:

```bash
test -f "$HOME/.ssh/id_ed25519.pub"
nagarectl host init --context "$CONTEXT_NAME" \
  --ssh-public-key-file "$HOME/.ssh/id_ed25519.pub" --dry-run
```

The dry run shows the context, hostname, registry, generated-flake path, and public configuration.
It writes nothing and does not require the host secrets file yet.

## Step 4 — Encrypt host secrets and generate the context host flake  🟡

`init` does not do this either. Prepare both parts before building the image, but keep the age
private key on the workstation until the VM exists:

- **(a) Host age key.** Generate the host's age keypair, record the **public** key in
  the `.sops.yaml` beside your context's host secrets (in your own private operator repository,
  not `nixos/.sops.yaml`, which holds only an example), and back up the **private** key outside
  Git. Do not add it to the image or try to place it yet; Step 8 streams it after the VM boots.
- **(b) Tailscale pre-auth key.** Put a Tailscale pre-auth key (a token that lets
  the context's host join your tailnet unattended at first boot) into a sops-encrypted YAML file
  under `tailscale/authkey`.

Generate the identity into an operator-controlled location, extract only its public recipient for
`.sops.yaml`, encrypt the Tailscale value with `sops`, and install the public configuration plus
ciphertext under the context-owned XDG configuration root:

```bash
install -d -m 0700 /secure/path
age-keygen -o /secure/path/prod-host.agekey
age-keygen -y /secure/path/prod-host.agekey   # put this public age1… recipient in .sops.yaml
sops /secure/path/prod-host-secrets.yaml      # add tailscale/authkey and save encrypted

nagarectl host init --context "$CONTEXT_NAME" \
  --ssh-public-key-file "$HOME/.ssh/id_ed25519.pub" \
  --sops-file /secure/path/prod-host-secrets.yaml
nagarectl host path --context "$CONTEXT_NAME"
nagarectl host show --context "$CONTEXT_NAME"
```

The resulting directory is
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare/hosts/prod/`. It contains `flake.nix`, `host.nix`,
the sops-encrypted `secrets.yaml`, and a generated `flake.lock`. `host init` never reads or copies
the age private key; `--age-key-file` records only its eventual on-host path. Repeating the command is unchanged, and
`--force` atomically replaces generated scaffolding while preserving `secrets.yaml` if
`--sops-file` is omitted.

See [secrets](secrets.md) for the exact `sops` and age-recipient mechanics — this page
states only *that* and *when*.

## Step 5 — Provision the cloud perimeter (first `nagare infra-up`)  🟡  *(EP-2)*

This first billable mutation targets project `$PROJECT_ID` and Pulumi stack `$CONTEXT_NAME`.
`nagarectl context guard` prints both identities before the saved preview, and this apply must not
contain a VM because no image self-link exists yet.

```bash
nagarectl --context "$CONTEXT_NAME" context guard
plan_dir="${XDG_STATE_HOME:-$HOME/.local/state}/nagare/reviews/perimeter"
nagare infra-preview --save-plan "$plan_dir"
jq . "$plan_dir/review.json"
nagare infra-up --plan "$plan_dir" --yes
```

The first apply creates everything **except the VM**, because
`nagareImageSelfLink` isn't set yet (you build the image in Step 8). See
[provisioning with Pulumi](provisioning-with-pulumi.md). Observable check — the reserved
static IP exists:

```bash
pulumi -C "$NAGARE_WORKSPACE_ROOT/infra/pulumi" stack output publicIp
```

## Step 6 — Delegate DNS now that the zone exists  🟡

The Cloud DNS managed zone was created in Step 5, so its nameservers now exist. Read them
and set NS records at your registrar (this must happen **after** Step 5 and **before**
HTTPS can be issued in Step 10):

```bash
pulumi -C "$NAGARE_WORKSPACE_ROOT/infra/pulumi" stack output dnsZoneName
gcloud dns managed-zones describe \
  "$(pulumi -C "$NAGARE_WORKSPACE_ROOT/infra/pulumi" stack output dnsZoneName)"
```

## Step 7 — Authenticate Docker to your registry  🟡  *(manual; before first deploy)*

Before `nagarectl deploy` can push an app image, register the credential helper for your
Artifact Registry host — `$NAGARE_REGISTRY_HOST`, i.e. `<region>-docker.pkg.dev`:

```bash
gcloud auth configure-docker us-west1-docker.pkg.dev    # use YOUR NAGARE_REGISTRY_HOST
```

(On the deploy path `nagarectl` configures this for you, but doing it once by hand removes
a first-deploy surprise.)

## Step 8 — Build + register the NixOS image, then boot the VM  🟡  *(EP-3 / EP-4)*

This stage starts the context builder in `$PROJECT_ID`, writes an image into that project's image
bucket, then applies stack `$CONTEXT_NAME` to create its single cluster VM. The dry run must print
the exact builder project, zone, and instance; stop if any differ from the selected context.

```bash
nagare host-image --dry-run
nagare host-image      # builds on the on-demand x86_64-linux Nix builder, uploads to
                       # $NAGARE_IMAGE_BUCKET, registers the GCE image, and writes
                       # nagare:nagareImageSelfLink into Pulumi config
vm_plan="${XDG_STATE_HOME:-$HOME/.local/state}/nagare/reviews/first-vm"
nagare infra-preview --save-plan "$vm_plan"
jq . "$vm_plan/review.json"
nagare infra-up --plan "$vm_plan" --yes
```

See [host image and boot](host-image-and-boot.md). `nagareImageSelfLink` embeds the
project, so it is target-specific and regenerated per target — never carried from another
project. Dry-run must show this context's project as the builder project. A deliberate shared
builder in another project requires the matching `--allow-shared-builder PROJECT` acknowledgement;
otherwise the build refuses before starting a VM.

On a new VM, the blank data disk is formatted before fsck can inspect it, then
mounted and populated before k3s starts. The first-boot acceptance suite repeats
that path with five independent disks and reaches one `Ready` node without a
reboot. This first boot is intentionally secretless: Tailscale autoconnect stops with
`age key missing` instead of starting an interactive login. Deliver the key immediately over IAP,
then verify secret activation before relying on the tailnet:

```bash
nagarectl host place-age-key --context "$CONTEXT_NAME" --key-file /secure/path/host.agekey
nagarectl --context "$CONTEXT_NAME" server status
nagare iap-ssh ssh nagare-01 -- sudo -- test -s /run/secrets/tailscale/authkey
nagare iap-ssh ssh nagare-01 -- sudo -- tailscale status
```

The placement command validates and hashes the local file, streams it only through SSH stdin,
installs it as root with mode `0400`, reruns sops-nix, and starts Tailscale. `server status` must
show `OK` for `host age key`; a confirmed missing or invalid key is `FAIL` and `doctor` prints the
same placement command as its remedy.

## Step 9 — Get on the host, confirm the node is Ready  🟡  *(EP-3 / EP-4, verified live and in VM tests)*

After Step 8 reports the host age key ready and Tailscale joined, use Tailscale SSH (primary) or
`nagare iap-ssh` (break-glass on macOS), then fetch the selected
context's credentials—see [accessing the host](accessing-the-host.md). Observable check:

```bash
nagarectl kubeconfig fetch --context "$CONTEXT_NAME"
export KUBECONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/nagare/kubeconfigs/${CONTEXT_NAME}.yaml"
nagarectl cluster guard --context "$CONTEXT_NAME"
kubectl get nodes      # ${CONTEXT_NAME}-nagare should be Ready
```

No reboot or manual layout/k3s restart belongs in this path. If the data-disk
mount is retried after a transient failure, its systemd transaction pulls both
units back in declaratively.

Do not reuse another context's kubeconfig or rename a manually copied `default` context. The fetch
selects the GCE instance through the context's project, addresses the API by its context-owned host
name, and installs a distinct mode-`0600` file. Every cloud cluster mutation below repeats the
identity guard before its first `kubectl` write.

## Step 10 — Bootstrap the cluster + observability  🟡  *(components verified; one-pass live rehearsal pending)*

These commands mutate only the cluster accepted by `nagarectl cluster guard`: its API endpoint and
sole node must identify `$CONTEXT_NAME`. A successful first invocation reaches ready cert-manager
and Knative webhooks without a retry, then certificate policy reports only opted-in app namespaces.

```bash
nagare cluster-bootstrap   # cert-manager + letsencrypt-dns issuer, Knative Serving, Kourier
nagare cluster-enable-tls  # enable external-domain TLS only after Step 6 delegation
kubectl -n personal wait --for=condition=Ready certificate --all --timeout=10m
nagare observability       # VictoriaMetrics/Logs/Traces + OTel Collector + Grafana
```

The `letsencrypt-dns` issuer is rendered from the **active context**: its
contact, its ACME endpoint and the project its DNS-01 solver writes into are the
context's own. If the active context has no `NAGARE_ACME_EMAIL`, bootstrap
**refuses** — it stops before `kubectl apply` and names the field — so no cluster
registers a Let's Encrypt account under an address you did not choose. Set it
with `nagarectl context create <name> --force --acme-email you@yourdomain.com`
and re-run.

Bootstrap imports Nagare's patched build of the latest archived
net-certmanager v1.14.0 controller from the immutable platform payload. Public
wildcards are opt-in: `personal` and namespaces reconciled by application
deployment carry `nagare.dev/app-namespace=true`; Kubernetes and platform
namespaces do not. Before switching a new domain to production ACME, run
`nagarectl cluster certificate-policy` and keep staging selected until it exits
zero. This avoids spending the registered-domain rate budget or exposing
control-plane namespace names in Certificate Transparency.

See [cluster bootstrap](cluster-bootstrap.md) and [observability](observability.md).
The HTTPS smoke test (a hello service answering over a valid Let's Encrypt cert
under your wildcard) depends on Step 6's DNS delegation having propagated.

## Step 11 — Deploy your first app  🟡  *(built; target-aware deploy path)*

See [deploying apps](deploying-apps.md) and [config reference](config-reference.md). An
app's `nagare/Config.hs` now supplies only the image **name** (e.g. `mkImageRef "notes"`);
the registry prefix comes from your active context at deploy time. A `/`-bearing ref (a
public image) is used as-is.

## Step 12 — Backups and recovery  🟡  *(DB/volume backups built; full DR drill deferred)*

See [backups and disaster recovery](backups-and-disaster-recovery.md) and the
[runbooks](../runbooks/disaster-recovery.md). Keep the host **age private key** off-machine and
back up the context configuration plus Pulumi state. An installed release keeps its writable
context under the XDG configuration/state roots shown by `nagarectl context path` and
`nagarectl platform root --json`; a remote Pulumi backend needs its own tested recovery path.

---

## Switching projects later

To point the same installed release at a different GCP project, create or initialize a
second context:

```bash
nagarectl init labs --project LABS_PROJECT_ID --base-domain labs.example.com \
  --acme-email you@example.com
nagarectl context use labs
nagarectl --context prod deploy -f nagare/Config.hs    # one-command override
```

`nagarectl context create labs ...` is the lighter-weight path when the GCP
project already exists and you only need to record the target bundle. The legacy
path still works too:

```bash
nagarectl init --force     # rewrites nagare.target.env and re-seeds the default projection
```

See [Target contexts](contexts.md) for `--context`, `NAGARE_CONTEXT`, migration
from old profile files, and the selection precedence. Before onboarding a
second cloud target, read
[Running multiple Nagare clusters](../guides/running-multiple-clusters.md) for
the supported one-project-per-cluster topology and the separate kubeconfig
requirement.

## See also

- [`CLAUDE.md`](../../CLAUDE.md) — the configurable project-isolation policy.
- [Target contexts](contexts.md) — named cloud/local targets and migration from
  `nagare.target.env` / `nagare.local.env`.
- [MasterPlan 17](../masterplans/17-first-class-target-contexts-for-nagare.md) —
  the context-model decision.
- [GCP prerequisites](gcp-prerequisites.md) — the GCP-account setup this runbook assumes.
