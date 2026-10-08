F86 native proof (nagare-fix, 2026-10-08T17:08:15Z), build of branch f86 on c3c20eb5, payload 3ae20f8c, wrapper = runctl.sh with that build.
(1) inplace.log: app deploy planning upg-pg 17 -> 18 refuses (PostgreSQL major change in place). revert.log: the unchanged config plans (review b76889a1...).
(2) restart.log/restart-apply.log: first build planned replace-stuck-pod (overlap fixed) but apply failed: 'Error in $: key "action" not found' (also with the released 3ae20f8c binary: restart-apply-3ae.log). Cause: kubernetesSpecsFromReview decoded the PodReplacement native as a mutation.
    restart2.log/restart2-apply.log: fixed build, review 366999eb... (1 ReplaceStuckPod + 19 VerifyResource) converged.
    After: upg-pg-0 postgres:17 ready=true restarts=0 rev=upg-pg-679d94744b uid=31354dbd-...; PostgreSQL 17.11; hits 7:7; activeTransaction null.
