#!/usr/bin/env bash
# Startup script for the on-demand x86_64-linux Nix remote builder.
# Templated: @BUILDER_PUBKEY@ is replaced by scripts/setup-nix-builder.sh
# at metadata-set time. The script provisions on first boot only — a
# sentinel file at /var/lib/nix-builder.provisioned short-circuits later
# boots.

set -euo pipefail

# --- KVM for sandboxed builds (every boot, idempotent) ------------------------
# Ubuntu's 50-udev-default.rules makes /dev/kvm root:kvm 0660. The Nix build
# sandbox does not map the kvm group, so NixOS VM tests (`kvm` system feature)
# silently fall back to TCG emulation and run 10-50x slower. NixOS itself makes
# /dev/kvm 0666; do the same. Runs before the first-boot sentinel so existing
# builders keep it too. (ExecPlan 115, Surprises & Discoveries.)
cat >/etc/udev/rules.d/99-kvm-nix-builds.rules <<'UDEV'
KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"
UDEV
udevadm control --reload-rules || true
if [ -e /dev/kvm ]; then
  chmod 0666 /dev/kvm
fi

# --- Tailscale (every boot, idempotent, never fatal) ---------------------------
# Remote builds reach this VM over the operator's tailnet instead of a gcloud
# IAP TCP tunnel: on 2026-10-05 the IAP websocket of a long nagarectl build
# dropped and gcloud failed to reconnect ("Unexpected error while
# reconnecting"), killing the build (EP-174). Tailscale keeps its state in
# /var/lib/tailscale on the boot disk, so the VM rejoins on every start. Join
# once, either with a one-time auth key in the instance metadata attribute
# `tailscale-authkey` (remove it afterwards) or interactively:
#   sudo tailscale up --hostname=nix-builder-x86
# Runs before the first-boot sentinel so existing builders get it too. A
# failure here leaves the IAP path working, so it never aborts the script.
ensure_tailscale() {
  if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  systemctl enable --now tailscaled
  if ! tailscale status >/dev/null 2>&1; then
    local key
    key="$(curl -fsS -H 'Metadata-Flavor: Google' \
      'http://metadata.google.internal/computeMetadata/v1/instance/attributes/tailscale-authkey' 2>/dev/null || true)"
    if [ -n "$key" ]; then
      tailscale up --auth-key="$key" --hostname="$(hostname -s)"
    fi
  fi
}
ensure_tailscale || echo "nix-builder: tailscale setup failed; the IAP path still works" >&2
# --- Idle-shutdown watchdog (every boot, idempotent) ----------------------------
# Stops the VM after 30 minutes in which every check found it idle. A check
# runs every 5 minutes and finds it busy when ANY of these is true, which
# resets the idle clock:
#   * an established TCP connection on port 22 (the headless
#     `nix-store --serve` transport while the consumer's SSH channel is open)
#   * a `nix-store --serve` process (a build in flight whose SSH session
#     dropped between derivations; single-user Determinate Nix keeps the
#     process across the gap; MasterPlan #2 EP-7 surprises 2026-05-17 #10/#11)
#   * a live build subprocess of the nix-daemon
# It used to stop the VM on one idle check, every 15 minutes. A full gate
# whose remote work paused between derivations lost the builder that way
# (2026-10-14: guestTerminate at 18:29Z mid-gate); a woken VM then needs about
# 30 s before SSH answers, longer than Nix's 10 s connect timeout. Runs before
# the first-boot sentinel so existing builders get it too.
cat >/usr/local/bin/idle-shutdown.sh <<'WD'
#!/usr/bin/env bash
set -e
SINCE_FILE=/run/idle-shutdown.since
busy() {
  rm -f "$SINCE_FILE"
  exit 0
}
ESTABLISHED=$(ss -Htn 'sport = :22' state established 2>/dev/null | wc -l)
[ "$ESTABLISHED" -gt 0 ] && busy
pgrep -f 'nix-store --serve' >/dev/null 2>&1 && busy
DAEMON_PID=$(pgrep -f 'nix-daemon --daemon' | head -n1 || true)
if [ -n "$DAEMON_PID" ]; then
  CHILDREN=$(pgrep -P "$DAEMON_PID" 2>/dev/null | wc -l)
  [ "$CHILDREN" -gt 0 ] && busy
fi
NOW=$(date +%s)
if [ ! -f "$SINCE_FILE" ]; then
  echo "$NOW" >"$SINCE_FILE"
  exit 0
fi
IDLE_S=$((NOW - $(cat "$SINCE_FILE")))
[ "$IDLE_S" -lt 1800 ] && exit 0
logger -t idle-shutdown "shutting down: idle for $((IDLE_S / 60)) min"
/sbin/shutdown -h now
WD
chmod +x /usr/local/bin/idle-shutdown.sh

cat >/etc/systemd/system/idle-shutdown.service <<'SVC'
[Unit]
Description=Shut down the VM after 30 idle minutes
[Service]
Type=oneshot
ExecStart=/usr/local/bin/idle-shutdown.sh
SVC

cat >/etc/systemd/system/idle-shutdown.timer <<'TMR'
[Unit]
Description=Periodic idle check for the Nix builder VM
[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Unit=idle-shutdown.service
[Install]
WantedBy=timers.target
TMR

systemctl daemon-reload
systemctl enable idle-shutdown.timer
# Restart so a builder booted with the old 15-minute timer takes the new one.
systemctl restart idle-shutdown.timer

# scripts/setup-nix-builder.sh waits for this line on the serial console before
# it stops the VM after a startup-script change.
echo "nix-builder: every-boot setup done"

if [ -f /var/lib/nix-builder.provisioned ]; then
  exit 0
fi

# --- openssh-server -----------------------------------------------------------
# Ubuntu 24.04 minimal cloud image does not include openssh-server. Install
# and start it first so IAP-tunneled SSH (used by the wait-loop in
# scripts/setup-nix-builder.sh and by the on-demand wrapper in
# dotfiles.nix/home/gcp-nix-builder.nix) has something to connect to.
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y openssh-server
systemctl enable --now ssh

# --- builder user and SSH key -------------------------------------------------
useradd -m -s /bin/bash -G sudo builder
install -d -m 0700 -o builder -g builder /home/builder/.ssh
cat >/home/builder/.ssh/authorized_keys <<'KEY'
@BUILDER_PUBKEY@
KEY
chown builder:builder /home/builder/.ssh/authorized_keys
chmod 0600 /home/builder/.ssh/authorized_keys

echo 'builder ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/builder
chmod 0440 /etc/sudoers.d/builder

# --- Determinate Nix install --------------------------------------------------
# Trusted-users must include 'builder' so the remote Nix daemon will accept
# build instructions over the SSH transport.
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | \
  sh -s -- install linux --no-confirm \
       --extra-conf 'trusted-users = root builder'

touch /var/lib/nix-builder.provisioned
