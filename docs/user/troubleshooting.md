# Troubleshooting

> **Status:** ✅ Working — every entry below is a failure actually hit while
> bringing up `nagare-01`, with the fix that's now committed to the repo.

These are the non-obvious failures and their fixes. Many are already encoded in
the NixOS config (with explanatory comments) so they don't recur — they're
documented here so that if you see the *symptom* on a fresh boot or a new host,
you know what's going on and where the fix lives. The source of record is the
EP-3 **Surprises & Discoveries** section in the MasterPlan.

---

## Name resolution fails on the VM

**Symptom.** k3s can't pull images; logs show *"Temporary failure in name
resolution."* Pings/HTTP/DNS to the GCE metadata server time out.

**Cause.** On this VM the GCE metadata server (`169.254.169.254`) — which DHCP
hands out as the resolver — is unreachable, so every DNS lookup breaks.

**Fix (committed, `networking.nix`).** Use public resolvers and stop dhcpcd from
overwriting `resolv.conf` with the broken metadata nameserver:

```nix
networking.nameservers = [ "8.8.8.8" "8.8.4.4" ];
networking.dhcpcd.extraConfig = "nohook resolv.conf";
```

`metadata.google.internal` still resolves via `/etc/hosts` (set by the GCE
config), so the guest agent is unaffected. **Don't "simplify" this away** — it's
load-bearing.

---

## k3s won't start: "Dependency failed for k3s service"

**Symptom.** First boot leaves k3s dead; the data-disk mount failed.

**Cause.** Pulumi attaches a **blank** persistent disk (no filesystem). The
`/var/lib/nagare` mount can't succeed on an unformatted disk, and k3s `requires`
that mount, so it never starts.

**Fix (committed, `storage.nix`).** A `format-nagare-data` oneshot formats the
disk ext4 on first boot **only if it has no filesystem** (`blkid` guard), before
the mount. It's idempotent — once formatted, it skips, so existing data is never
touched.

```nix
if ! blkid /dev/disk/by-id/google-nagare-data >/dev/null 2>&1; then
  mkfs.ext4 -F -L nagare-data /dev/disk/by-id/google-nagare-data
fi
```

This is also why a **VM rebuild keeps your data**: the surviving disk already
has a filesystem, so the format step is skipped (see
[Backups and disaster recovery](backups-and-disaster-recovery.md)).

---

## `/var/lib/nagare` has only `lost+found` — the subdirectories vanished

**Symptom.** After boot, `/var/lib/nagare` is missing its expected subdirs
(`victoria-metrics`, `sqlite`, `local-path`, …) and shows only `lost+found`. k3s
local-path storage has no directory.

**Cause.** Creating the layout with `systemd.tmpfiles.rules` runs at
`systemd-tmpfiles-setup`, which can fire **before** the `nofail` data disk is
mounted. The dirs get created on the **root** filesystem, then the disk mounts
on top and shadows them — leaving only the disk's `lost+found` visible.

**Fix (committed, `storage.nix`).** Create the layout with an explicit oneshot
(`nagare-data-layout`) ordered **after** `var-lib-nagare.mount`
(`RequiresMountsFor`), so the directories land on the mounted data disk. k3s is
in turn ordered after that unit.

---

## SSH: connection closed right after the handshake

**Symptom.** SSH (including over the IAP tunnel) connects, completes the key
exchange, then drops at the start of user authentication — *"Connection closed
… at userauth."* After a couple of attempts the box is effectively unreachable.

**Two causes, both fixed in `security.nix`:**

1. **OpenSSH per-source penalties.** OpenSSH 9.8+/10.x `PerSourcePenalties`
   start dropping connections from a source after a couple of failures — and all
   IAP-tunneled connections share one source. Disabled:

   ```nix
   services.openssh.settings.PerSourcePenalties = "no";
   ```

2. **Google OS Login.** The GCE image module enables OS Login by default, which
   makes sshd authenticate via the OS Login `AuthorizedKeysCommand` helper
   instead of the `deploy` user's declarative `authorized_keys` — a second cause
   of the userauth-time close. Disabled so plain key auth is used:

   ```nix
   security.googleOsLogin.enable = lib.mkForce false;
   ```

We control access via the IAP firewall + key auth as the `deploy` user, so
neither feature is needed. If you re-enable either, expect this symptom back.

---

## `gcloud compute ssh --tunnel-through-iap` hangs / breaks on macOS

**Symptom.** On macOS (OpenSSH 10.x), `gcloud compute ssh --tunnel-through-iap`
fails during the kex handshake.

**Cause.** A known macOS OpenSSH 10.x + IAP interaction.

**Fix.** Use `scripts/iap-ssh.sh`, which opens the tunnel with
`gcloud compute start-iap-tunnel` and routes OpenSSH through `socat` as the
`ProxyCommand`. See [Accessing the host](accessing-the-host.md#path-2-iap-tunnel-break-glass).

---

## A script refuses to run: "wrong gcloud active project"

**Symptom.** A script aborts with *"refusing to run: gcloud active project is
'…', expected 'tan-nb-exp'."*

**Cause.** You're outside the dev shell, or your `gcloud` config overrides
`CLOUDSDK_CORE_PROJECT`. This is the intended project-isolation guard, not a bug.

**Fix.** Re-enter the dev shell so `.envrc` exports the project vars
(`direnv allow` or `nix develop`), and confirm `gcloud config get-value
project` (or the env var) is `tan-nb-exp`. See
[Getting started](getting-started.md#project-isolation-read-this-once-internalize-it).

---

## `kubectl` can't reach the cluster

**Likely causes.**

- Kubeconfig still points at `https://127.0.0.1:6443`. Repoint `server:` at the
  host's tailnet address (`https://nagare-01:6443`) — the firewall trusts
  `tailscale0`, not your workstation's public IP. See
  [Accessing the host](accessing-the-host.md#getting-a-working-kubectl).
- The host isn't on the tailnet (Tailscale didn't get its auth key). Check the
  sops secret and `systemctl status tailscaled`.
- k3s isn't up — work back through the storage/DNS entries above.

---

## Where the authoritative record lives

If a symptom here doesn't match what you see, or you hit something new, check the
EP-3 **Surprises & Discoveries** and **Decision Log** in
[`docs/masterplans/1-bootstrap-nagare-personal-paas.md`](../masterplans/1-bootstrap-nagare-personal-paas.md)
— that's kept current as the build proceeds, and new findings are recorded there
first.
