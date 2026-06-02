#!/usr/bin/env bash
# Startup script for the on-demand x86_64-linux Nix remote builder.
# Templated: @BUILDER_PUBKEY@ is replaced by scripts/setup-nix-builder.sh
# at metadata-set time. The script provisions on first boot only — a
# sentinel file at /var/lib/nix-builder.provisioned short-circuits later
# boots.

set -euo pipefail

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

# --- Idle-shutdown watchdog ---------------------------------------------------
# Stops the VM only when ALL of these are true:
#   * uptime > 30 min (give the first build room to settle)
#   * zero established TCP connections on port 22 (catches the common
#     headless `nix-store --serve` transport when the consumer-side SSH
#     channel is currently connected)
#   * zero `nix-store --serve` processes running (catches the case where
#     a build is in flight but the SSH session has momentarily dropped
#     between derivations — single-user Determinate Nix on the builder
#     leaves the nix-store --serve process running across the gap)
#   * the nix-daemon (when present) has no live build subprocesses
# Without the nix-store --serve guard the watchdog has been observed
# killing the VM mid-build during multi-derivation closure transfers;
# see MasterPlan #2 EP-7 surprises 2026-05-17 #10 / #11 for the
# original root-cause investigation.
cat >/usr/local/bin/idle-shutdown.sh <<'WD'
#!/usr/bin/env bash
set -e
UPTIME_S=$(awk '{print int($1)}' /proc/uptime)
[ "$UPTIME_S" -lt 1800 ] && exit 0
ESTABLISHED=$(ss -Htn 'sport = :22' state established 2>/dev/null | wc -l)
[ "$ESTABLISHED" -gt 0 ] && exit 0
# Protect active remote builds: nix-store --serve stays running across
# brief SSH disconnects between derivations.
pgrep -f 'nix-store --serve' >/dev/null 2>&1 && exit 0
DAEMON_PID=$(pgrep -f 'nix-daemon --daemon' | head -n1 || true)
if [ -n "$DAEMON_PID" ]; then
  CHILDREN=$(pgrep -P "$DAEMON_PID" 2>/dev/null | wc -l)
  [ "$CHILDREN" -gt 0 ] && exit 0
fi
logger -t idle-shutdown "shutting down: idle"
/sbin/shutdown -h now
WD
chmod +x /usr/local/bin/idle-shutdown.sh

cat >/etc/systemd/system/idle-shutdown.service <<'SVC'
[Unit]
Description=Shut down the VM if idle
[Service]
Type=oneshot
ExecStart=/usr/local/bin/idle-shutdown.sh
SVC

cat >/etc/systemd/system/idle-shutdown.timer <<'TMR'
[Unit]
Description=Periodic idle check for the Nix builder VM
[Timer]
OnBootSec=30min
OnUnitActiveSec=15min
Unit=idle-shutdown.service
[Install]
WantedBy=timers.target
TMR

systemctl daemon-reload
systemctl enable --now idle-shutdown.timer

touch /var/lib/nix-builder.provisioned
