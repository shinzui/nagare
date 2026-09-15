---
type: Bug Report
title: Upgrade host switching confuses GCE instance and generated host names
description: >-
  The 0.3.0 host phase uses NAGARE_INSTANCE_NAME as both the NixOS attribute and
  SSH destination, so a context with a distinct generated host name cannot upgrade safely.
generated:
  by: process:openai-codex
  at: "2026-09-15T13:52:11Z"
bugId: BUG-2
status: confirmed
severity: degraded
origin: mori://tan/tan-ng-labs/docs/validate-the-labs-nagare-cluster-before-real-use
affects: mori://shinzui/nagare/packages/nagarectl
capability: mori://shinzui/nagare/okf/capabilities/concepts/CAP-19
affectedVersion: 0.3.0
environment: >-
  labs context with GCE instance nagare-01, generated host labs-nagare, and a
  sibling tailnet node already named nagare-01
observed: >-
  Host apply evaluates nixosConfigurations.nagare-01, which does not exist, while
  the default SSH name can resolve to a different Nagare cluster.
expected: >-
  Platform upgrade should use the context-owned generated host name for the NixOS
  attribute and Tailscale target while retaining the instance name only for GCE operations.
reproduction:
  - Create or use a context whose GCE instance is nagare-01 and generated host is labs-nagare.
  - Ensure its flake exports nixosConfigurations.labs-nagare and no nagare-01 attribute.
  - Apply a reviewed 0.3.0 upgrade transaction through the host phase.
  - Observe evaluation fail for nixosConfigurations.nagare-01; if that tailnet name exists, observe that the default SSH identity names the sibling node.
workaround: >-
  After independently verifying the tailnet identity, set NAGARE_HOST_ATTR=labs-nagare
  and use NIX_SSHOPTS with HostName and HostKeyAlias both set to labs-nagare.
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-09-15T13:52:11Z"
    document_timestamp: "2026-09-15T13:52:11Z"
    scope: content-and-metadata
    outcome: approved
    provider: openai
    model: gpt-5.6-sol
    effort: unspecified
    context: >-
      Reviewed against the generated labs flake, the live failure, both tailnet
      identities, and the successful safe-switch recovery.
---

# Upgrade host switching confuses GCE instance and generated host names

Nagare 0.3.0 intentionally supports a context-owned host name distinct from the project-scoped GCE
instance name. The upgrade transaction does not preserve that distinction: `host-switch.sh` defaults
both `NAGARE_HOST_ATTR` and the SSH target from `NAGARE_INSTANCE_NAME`. The live transaction stopped
because the generated flake exports only `nixosConfigurations.labs-nagare`; worse, `nagare-01` was a
real sibling tailnet node, so a partial override could have addressed the wrong cluster.

The fix should obtain the validated generated host name from context host configuration and pass it
separately for Nix and SSH. A two-context regression should prove no evaluation, copy, switch, or
verification request names the sibling instance identity.
