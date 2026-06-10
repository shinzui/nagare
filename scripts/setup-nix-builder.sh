#!/usr/bin/env bash
# Provision an on-demand x86_64-linux Nix remote builder in GCP.
#
# What this does, in order:
#   1. Enables compute, IAP, and storage APIs on the target project.
#   2. Creates a dedicated VPC (nix-builder-net), subnet, and IAP-only
#      ingress firewall rule for SSH.
#   3. Renders scripts/nix-builder-startup.sh.tpl with the host's builder
#      public key and creates an Ubuntu 24.04 n2-standard-2 VM (nested
#      virt enabled, ephemeral external IP for outbound) with that
#      startup script. Inbound SSH is restricted to GCP's IAP range
#      via the firewall rule, so the external IP only serves egress
#      (Determinate Nix installer + cache.nixos.org substitutes).
#   4. Waits for the startup script to finish provisioning (Determinate
#      Nix installed, builder user created, idle-shutdown watchdog armed).
#   5. Stops the VM so it costs only the boot disk while idle. The host's
#      ssh ProxyCommand (managed in dotfiles.nix) will start it again on
#      the next `nix build`.
#
# Idempotent: re-running this script only creates resources that are
# missing. Editing the startup template after the VM exists has no effect
# unless you delete the VM first.

set -euo pipefail

# Load the target profile and run the configurable, fail-closed project-isolation
# preflight (EP-60). Exports TARGET_PROJECT / TARGET_REGION / TARGET_ZONE.
source "$(dirname "$0")/lib/target.sh"
_require_target_project
PROJECT="$TARGET_PROJECT"
REGION="$TARGET_REGION"
ZONE="$TARGET_ZONE"

# Builder resource names. These are NOT target-profile fields — they name
# resources this script creates inside $PROJECT. They are env-overridable so a
# second operator sharing a project can avoid name collisions without editing
# this file; the defaults preserve today's behavior.
NETWORK="${NIX_BUILDER_NETWORK:-nix-builder-net}"
SUBNET="${NIX_BUILDER_SUBNET:-nix-builder-subnet}"
SUBNET_CIDR="${NIX_BUILDER_SUBNET_CIDR:-10.10.0.0/24}"
FIREWALL="${NIX_BUILDER_FIREWALL:-nix-builder-iap-ssh}"
INSTANCE="${NIX_BUILDER_INSTANCE:-nix-builder-x86}"
MACHINE_TYPE=n2-standard-2
DISK_SIZE=200GB
DISK_TYPE=pd-balanced
IMAGE_FAMILY=ubuntu-2404-lts-amd64
IMAGE_PROJECT=ubuntu-os-cloud
BUILDER_PUBKEY_PATH=/etc/nix/builder_ed25519.pub

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$REPO_ROOT/scripts/nix-builder-startup.sh.tpl"

if [ ! -r "$BUILDER_PUBKEY_PATH" ]; then
  echo "error: $BUILDER_PUBKEY_PATH is not readable" >&2
  exit 1
fi
if [ ! -r "$TEMPLATE" ]; then
  echo "error: $TEMPLATE is missing" >&2
  exit 1
fi

log()    { printf '\033[1;36m[setup-nix-builder]\033[0m %s\n' "$*"; }
exists() { "$@" >/dev/null 2>&1; }

PUBKEY=$(tr -d '\n' <"$BUILDER_PUBKEY_PATH")

log "Enabling APIs (idempotent)"
gcloud --project="$PROJECT" services enable \
  compute.googleapis.com iap.googleapis.com storage.googleapis.com

log "VPC $NETWORK"
if ! exists gcloud --project="$PROJECT" compute networks describe "$NETWORK"; then
  gcloud --project="$PROJECT" compute networks create "$NETWORK" --subnet-mode=custom
fi

log "Subnet $SUBNET ($SUBNET_CIDR in $REGION)"
if ! exists gcloud --project="$PROJECT" compute networks subnets describe "$SUBNET" --region="$REGION"; then
  gcloud --project="$PROJECT" compute networks subnets create "$SUBNET" \
    --network="$NETWORK" --region="$REGION" --range="$SUBNET_CIDR"
fi

log "Firewall $FIREWALL (allow tcp:22 from 35.235.240.0/20 — IAP only)"
if ! exists gcloud --project="$PROJECT" compute firewall-rules describe "$FIREWALL"; then
  gcloud --project="$PROJECT" compute firewall-rules create "$FIREWALL" \
    --network="$NETWORK" --direction=INGRESS --action=ALLOW \
    --rules=tcp:22 --source-ranges=35.235.240.0/20
fi

log "Rendering startup script"
STARTUP=$(mktemp)
trap 'rm -f "$STARTUP"' EXIT
# Substitute the public key. Pubkeys contain no `|` so we use it as the sed delim.
sed "s|@BUILDER_PUBKEY@|$PUBKEY|" "$TEMPLATE" >"$STARTUP"

disk_size_gb() {
  local size="$1"
  echo "${size%GB}"
}

ensure_boot_disk_size() {
  local disk_url disk_name current_size target_size
  target_size="$(disk_size_gb "$DISK_SIZE")"
  disk_url="$(gcloud --project="$PROJECT" compute instances describe "$INSTANCE" \
    --zone="$ZONE" --format='value(disks[0].source)')"
  disk_name="$(basename "$disk_url")"
  current_size="$(gcloud --project="$PROJECT" compute disks describe "$disk_name" \
    --zone="$ZONE" --format='value(sizeGb)')"
  if [ "$current_size" -lt "$target_size" ]; then
    log "Resizing boot disk $disk_name from ${current_size}GB to ${DISK_SIZE}"
    gcloud --project="$PROJECT" compute disks resize "$disk_name" \
      --zone="$ZONE" --size="$DISK_SIZE" --quiet
  fi
}

log "VM $INSTANCE ($MACHINE_TYPE, $IMAGE_FAMILY, nested-virt, ${DISK_SIZE} boot disk, ephemeral external IP)"
if exists gcloud --project="$PROJECT" compute instances describe "$INSTANCE" --zone="$ZONE"; then
  log "VM already exists; skipping create. Delete it to re-apply the startup script."
  ensure_boot_disk_size
else
  gcloud --project="$PROJECT" compute instances create "$INSTANCE" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --enable-nested-virtualization \
    --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT" \
    --boot-disk-size="$DISK_SIZE" --boot-disk-type="$DISK_TYPE" \
    --subnet="$SUBNET" \
    --metadata-from-file=startup-script="$STARTUP"
fi

log "Waiting up to 10 minutes for startup script to finish"
# We poll via start-iap-tunnel + nc rather than `gcloud compute ssh
# --tunnel-through-iap`. The latter uses --listen-on-stdin under the
# hood, which has a kex-handshake-eating timing bug with OpenSSH 10.x
# clients on macOS (the SSH banner arrives before the WebSocket is
# ready and gets dropped on the floor). The local-port + banner-probe
# approach is also a more honest readiness check: we only need proof
# that sshd is responding, not a successful login.
DEADLINE=$(( $(date +%s) + 600 ))
PROVISIONED=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  PORT=$(( RANDOM % 10000 + 20000 ))
  gcloud --project="$PROJECT" compute start-iap-tunnel "$INSTANCE" 22 \
    --zone="$ZONE" --local-host-port="localhost:$PORT" --quiet >/dev/null 2>&1 &
  TUNNEL_PID=$!
  sleep 5
  # nc -w 5 reads one packet then closes. sshd sends its banner immediately.
  if (echo ""; sleep 1) | nc -w 5 localhost "$PORT" 2>/dev/null | grep -q '^SSH-'; then
    PROVISIONED=1
    kill "$TUNNEL_PID" 2>/dev/null || true
    wait "$TUNNEL_PID" 2>/dev/null || true
    break
  fi
  kill "$TUNNEL_PID" 2>/dev/null || true
  wait "$TUNNEL_PID" 2>/dev/null || true
  sleep 10
done

if [ "$PROVISIONED" -ne 1 ]; then
  echo "error: startup script did not finish within 10 minutes" >&2
  echo "inspect with: gcloud --project=$PROJECT compute ssh $INSTANCE --zone=$ZONE --tunnel-through-iap -- sudo journalctl -u google-startup-scripts" >&2
  exit 2
fi

log "Stopping VM (idle cost = boot disk only; first build will start it again)"
gcloud --project="$PROJECT" compute instances stop "$INSTANCE" --zone="$ZONE" --quiet

log "Done. Try: nix build --builders 'ssh://nix-gcp-builder x86_64-linux' nixpkgs#hello"
