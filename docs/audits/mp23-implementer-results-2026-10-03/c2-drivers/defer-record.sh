#!/usr/bin/env bash
# Queue one scenario-assertions record call; replayed against the runner's evidence dir after its plan creates it.
set -euo pipefail
Q=/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/dc0e8853-c761-4c35-88cd-db57750f8f5b/scratchpad/c2-next/record-queue.txt
args=("$@"); out=()
for ((i=0; i<${#args[@]}; i++)); do
  if [[ "${args[$i]}" == --evidence-dir ]]; then i=$((i+1)); continue; fi
  out+=("${args[$i]}")
done
printf '%q ' "${out[@]}" >> "$Q"; printf '\n' >> "$Q"
name=""; for ((i=0; i<${#out[@]}; i++)); do [[ "${out[$i]}" == --name ]] && name="${out[$((i+1))]}"; done
echo "Deferred local assertion $name"
