# C2 on the final candidate `83124396`

nagare-verify ran this on 2026-10-09 on cp3. It used a fresh k3d context bootstrapped from the
candidate's own payload (`platform-root.json`: `nagare-0.4.0-831243962c6b`), with the driver set that
passed on `3b59bcb7`. The run finalized 16 of 16 assertions (`local-health.json`), and the assembler
accepted it (`inventory-evidence.json`). The candidate gate (C1) proof is `c1-proof.json`: 214
operations, all `VerifyResource`, with no provider mutation. The console log is `chain.log`.

C1 refused to start twice, and both refusals were harness scheduling on nagare-verify's side, not
candidate behavior:
1. `run-local-candidate-gate.py` requires the cp3 Colima profile to be the only one running. The
   x86_64 C4 container (profile `nagare-c4-amd64`) was running at the same time.
2. The rerun then found the first attempt's output directory. It was moved aside, not deleted.

The chain then resumed at C1 (phase 1 had already passed) and ran to the end without a stop.

The images are the same as on `3b59bcb7` (`images.env`).
