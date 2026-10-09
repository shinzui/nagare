#!/usr/bin/env bash
S=/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/fe35126f-a94c-4190-a632-3310e450547d/scratchpad
C=/private/tmp/nagare-x86-c4-83124396; W=/private/tmp/nagare-cand-83124396-src; REL=/private/tmp/nagare-release-83124396; D=$S/c4-83124396; mkdir -p $D
# aarch64-darwin: clone-free rehearsal and native output identities from the clean candidate worktree.
cd $W; [ -z "$(git status --porcelain)" ] || { echo "dirty worktree"; exit 1; }
s=$(date +%s); bash scripts/rehearse-clone-free-release.sh --version 0.4.0 --output $D/clone-free-aarch64-darwin.json > $D/clone-free-aarch64-darwin.log 2>&1; echo "darwin rehearsal exit=$? seconds=$(( $(date +%s) - s ))" | tee -a $D/clone-free-aarch64-darwin.log
out=$REL/aarch64-darwin; revision="$(jq -er '.revision' $out/nagare-release-0.4.0.json)"
cli_path="$(nix build --no-link --print-out-paths .#nagarectl 2>/dev/null)"; payload_path="$(nix build --no-link --print-out-paths .#nagare-platform 2>/dev/null)"
cli_info="$(nix path-info --json --json-format 1 "$cli_path" | jq --arg path "$cli_path" '.[$path] | {narHash, narSize}')"
payload_info="$(nix path-info --json --json-format 1 "$payload_path" | jq --arg path "$payload_path" '.[$path] | {narHash, narSize}')"
jq -n -S --arg version 0.4.0 --arg revision "$revision" --arg system aarch64-darwin --argjson cli "$cli_info" --argjson payload "$payload_info" '{version: $version, revision: $revision, system: $system, outputs: {nagarectl: $cli, "nagare-platform": $payload}}' > $out/nix-output-aarch64-darwin.json
echo "darwin payload $(jq -r '.outputs["nagare-platform"].narHash' $out/nix-output-aarch64-darwin.json) manifest $(jq -r .payloadDigest $out/nagare-release-0.4.0.json)"
# x86_64-linux: rehearsal, then check-release and native identities, in the amd64 container.
colima start nagare-c4-amd64 > $C/colima.log 2>&1
docker --context colima-nagare-c4-amd64 run --rm --platform linux/amd64 -v $C:/c4 nixos/nix:2.35.2 bash /c4/x86.sh > $C/run.log 2>&1; echo "run exit=$?" >> $C/run.log; tail -2 $C/run.log
docker --context colima-nagare-c4-amd64 run --rm --platform linux/amd64 -v $C:/c4 nixos/nix:2.35.2 bash /c4/x86-release.sh > $C/release-run.log 2>&1; echo "run exit=$?" >> $C/release-run.log; tail -2 $C/release-run.log
colima stop nagare-c4-amd64 >> $C/colima.log 2>&1
grep "building '" $C/run.log $C/release-run.log | head -3
echo C4-DONE
