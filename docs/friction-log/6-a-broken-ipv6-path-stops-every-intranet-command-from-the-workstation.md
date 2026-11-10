---
type: Friction Entry
title: "A broken IPv6 path stops every intranet command from the workstation"
description: "gcloud and nagarectl try IPv6 first and spend their whole timeout on it, so a home router losing IPv6 looked like store and ownership failures and left one transaction ambiguous."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-10T03:29:55Z"
frictionId: FRIC-6
status: logged
impact: blocked
kind: environment
origin: "mori://shinzui/nagare"
affects: "mori://shinzui/nagare"
plan: "docs/plans/239-deliver-rotated-session-cookies-before-waiting-on-the-upstream.md"
workaround: "networksetup -setv6off Wi-Fi, then inventory resume"
---
# A broken IPv6 path stops every intranet command from the workstation

## Attempted

Publish and deploy the labs portal from the workstation

## Encountered

The IPv6 gateway was unreachable and the prefix deprecated; nagarectl's store reads used their 20-second budget on IPv6, the ownership guard refused, and an apply stopped ambiguous

```text
StoreConditionFailed refusing: could not read the owning project number; StoreIoError inventory object metadata could not be read
```

## Workaround

networksetup -setv6off Wi-Fi, then inventory resume
