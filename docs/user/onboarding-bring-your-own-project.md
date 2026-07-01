# Bring-your-own-project onboarding

> **Status:** ✅ Working — this is the consolidated zero-to-running runbook. Each
> numbered step carries its own real status badge inline, so you are never misled
> about what is built. For laptop-only testing without GCP, use
> [Local development](local-development.md) instead.

From an empty GCP project and a domain you own to a running nagare, using only this
page and the pages it links. The default worked example targets project `tan-nb-exp`,
region `us-west1`, zone `us-west1-a`, base domain `apps.example.com` — **every one of
those is substitutable** for your own values via the target context.
For new setups, put those values in a named [target context](contexts.md), such
as `prod` or `labs`.

**Before you begin:**

1. The GCP-side setup from [GCP prerequisites](gcp-prerequisites.md) is done.
2. You have cloned this repository and can open a terminal in it.

---

## Step 0 — Workstation + dev shell  ✅

Install [Nix](https://nixos.org/download), then enter the pinned dev shell so every tool
below (`pulumi`, `gcloud`, `kubectl`, `helm`, `ghc`/`cabal`, `sops`, `age`, `just`,
`nagarectl`) comes from the flake, not a global install:

```bash
direnv allow      # one-time authorization of .envrc; or run `nix develop`
```

Everything below runs **inside that shell, from the repo root**. See
[getting started](getting-started.md) for detail.

## Step 1 — GCP prerequisites  ✅

Follow [GCP prerequisites](gcp-prerequisites.md) once. In short: an authenticated
`gcloud` **plus ADC**; the six operator IAM roles (or `roles/owner`); a project with
billing; the service APIs enabled (or let `nagarectl init` enable them); and a domain
ready to delegate. Don't repeat the detail here — follow the linked page.

## Step 2 — `nagarectl init`  ✅

This is the centerpiece. It is the **one** command that writes a target context
and drives that context's Pulumi config projection — you do not hand-edit either
for onboarding.

```bash
nagarectl init prod --project YOUR_PROJECT_ID --base-domain apps.yourdomain.com
# On a TTY it prompts for project / region / zone / base domain with sensible defaults.
```

Flags (exactly as shipped):

| Flag | Effect |
|------|--------|
| `--project` | GCP project id. Supplying it makes the run non-interactive. |
| `--region` | Compute region (default `us-west1`). |
| `--zone` | Compute zone (default `us-west1-a`). |
| `--base-domain` | Apps base domain (default `apps.example.com`). |
| `--force` | Overwrite an existing named context, or an existing `nagare.target.env` in legacy mode. |
| `--skip-preflight` | Skip the gcloud-auth + operator-IAM checks. |
| `--skip-enable` | Skip running `scripts/enable-apis.sh`. |
| `--skip-seed` | Skip seeding the Pulumi stack config. |
| `--dry-run` | Show what would be written/enabled/seeded, doing none of it. |

There is **no** `--yes` / `--non-interactive` flag — supplying `--project` is what makes
the run non-interactive.

Ordered effect: resolve defaults → **preflight** (gcloud active account + the six operator
IAM roles) → write the named context (the same `export` lines shown below) and make it
current → **enable** the six APIs →
**seed** eight Pulumi stack-config keys for that context (`gcp:project`, `gcp:region`, `gcp:zone`,
`nagare:baseDomain`, `nagare:imageBucket`, `nagare:backupBucket`, `nagare:artifactRegistryId`,
`nagare:instanceName`) → print next steps.

The generated context is your single source of truth. `nagarectl context show prod`
prints it in the same flat format:

```bash
export CLOUDSDK_CORE_PROJECT=tan-nb-exp                 # YOUR project
export CLOUDSDK_COMPUTE_REGION=us-west1
export CLOUDSDK_COMPUTE_ZONE=us-west1-a
export NAGARE_REGISTRY_HOST=us-west1-docker.pkg.dev      # derived as <region>-docker.pkg.dev
export NAGARE_ARTIFACT_REGISTRY_ID=nagare
export NAGARE_IMAGE_BUCKET=tan-nb-exp-nagare-images       # derived as <project>-nagare-images
export NAGARE_BACKUP_BUCKET=tan-nb-exp-nagare-backups     # derived as <project>-nagare-backups
export NAGARE_BASE_DOMAIN=apps.example.com
export NAGARE_INSTANCE_NAME=nagare-01
```

If you omit `NAME`, `nagarectl init` keeps the legacy behavior and writes
`./nagare.target.env`. That path is still supported, but named contexts are the
multi-target workflow.

`init` does **not** do the next two manual steps (SSH key, age key, Tailscale key) or the
Docker-auth step — its printed "Next steps" stop at the `just` recipes. Do them now, in
order.

## Step 3 — Operator SSH key in the host config  🟡  *(manual; before image build)*

The image bakes in the `deploy` user's authorized SSH key from
`nixos/hosts/nagare-01/users.nix`. **Edit that file to your own public key before building
the image**, or you cannot log in. See [accessing the host](accessing-the-host.md).

## Step 4 — Host age key + Tailscale pre-auth key  🟡  *(manual; before first boot)*

`init` does not do this either. Both parts are required before the host boots cleanly:

- **(a) Host age key.** Generate the host's age keypair, record the **public** key in
  `nixos/.sops.yaml`, and place the **private** key on the VM at
  `/var/lib/sops-nix/age-key.txt` (mode `0400`, owned by root) before first boot. At NixOS
  activation, `sops-nix` decrypts the secrets file with this key.
- **(b) Tailscale pre-auth key.** Put a Tailscale pre-auth key (a token that lets
  `nagare-01` join your tailnet unattended at first boot) into the sops secrets file
  `nixos/hosts/nagare-01/secrets/nagare-01.yaml` under `tailscale/authkey`, encrypted to
  the host's age public key.

See [secrets](secrets.md) for the exact `sops` and `.sops.yaml` mechanics — this page
states only *that* and *when*.

## Step 5 — Provision the cloud perimeter (first `just infra-up`)  🟡  *(EP-2)*

```bash
just infra-up
```

On a clean checkout the first apply creates everything **except the VM**, because
`nagareImageSelfLink` isn't set yet (you build the image in Step 8). See
[provisioning with Pulumi](provisioning-with-pulumi.md). Observable check — the reserved
static IP exists:

```bash
pulumi -C infra/pulumi stack output publicIp
```

## Step 6 — Delegate DNS now that the zone exists  🟡

The Cloud DNS managed zone was created in Step 5, so its nameservers now exist. Read them
and set NS records at your registrar (this must happen **after** Step 5 and **before**
HTTPS can be issued in Step 10):

```bash
pulumi -C infra/pulumi stack output dnsZoneName
gcloud dns managed-zones describe "$(pulumi -C infra/pulumi stack output dnsZoneName)"
```

## Step 7 — Authenticate Docker to your registry  🟡  *(manual; before first deploy)*

Before `nagarectl deploy` can push an app image, register the credential helper for your
Artifact Registry host — `$NAGARE_REGISTRY_HOST`, i.e. `<region>-docker.pkg.dev`:

```bash
gcloud auth configure-docker us-west1-docker.pkg.dev    # use YOUR NAGARE_REGISTRY_HOST
```

(On the deploy path `nagarectl` configures this for you, but doing it once by hand removes
a first-deploy surprise.)

## Step 8 — Build + register the NixOS image, then boot the VM  🟡  *(EP-3)*

```bash
just host-image        # builds on the on-demand x86_64-linux Nix builder, uploads to
                       # $NAGARE_IMAGE_BUCKET, registers the GCE image, and writes
                       # nagare:nagareImageSelfLink into Pulumi config
just infra-up          # re-run: the VM is created now that the self-link is set
```

See [host image and boot](host-image-and-boot.md). `nagareImageSelfLink` embeds the
project, so it is target-specific and regenerated per target — never carried from another
project.

## Step 9 — Get on the host, confirm the node is Ready  🟡  *(EP-3, verified live)*

Use Tailscale SSH (primary) or `scripts/iap-ssh.sh` (break-glass on macOS) — see
[accessing the host](accessing-the-host.md). Observable check:

```bash
kubectl get nodes      # nagare-01 should be Ready
```

## Step 10 — Bootstrap the cluster + observability  ✅  *(EP-4 / EP-5, verified live)*

```bash
just cluster-bootstrap     # cert-manager + letsencrypt-dns issuer, Knative Serving, Kourier
just observability         # VictoriaMetrics/Logs/Traces + OTel Collector + Grafana
```

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
[runbooks](../runbooks/disaster-recovery.md). Keep two things off-machine: the host **age
private key** and a copy of this repo (including Pulumi state under `infra/pulumi/`).

---

## Switching projects later

To point the same checkout at a different GCP project, create or initialize a
second context:

```bash
nagarectl init labs --project LABS_PROJECT_ID --base-domain labs.example.com
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
from old profile files, and the selection precedence.

## See also

- [`CLAUDE.md`](../../CLAUDE.md) — the configurable project-isolation policy.
- [Target contexts](contexts.md) — named cloud/local targets and migration from
  `nagare.target.env` / `nagare.local.env`.
- [MasterPlan 17](../masterplans/17-first-class-target-contexts-for-nagare.md) —
  the context-model decision.
- [GCP prerequisites](gcp-prerequisites.md) — the GCP-account setup this runbook assumes.
