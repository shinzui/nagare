. "$(dirname "$0")/lib.sh"; ids
step "P7a EP-247 D6/D9: inventory history names the actor and the source"
HISTORY_LIMIT=12 run history OP
OP inventory history --limit 12 --contract 1 > "$EV/history.json"
jq -c '.transactions[] | {transaction, actor, scopes, source, state}' "$EV/history.json"

step "P7b EP-247 D5/D9: after revocation, a review saved before it and a new one are refused"
rm -rf "$R/reviews/pre-revoke" "$R/reviews/revoke-ci" "$R/reviews/post-revoke"
run CI app image-plan --archive "$R/hello-v1.tar" --destination "$IMG/team-a/hello:v2" --key team-a-hello-v2 "${SRC[@]}" --source-revision 0ddba11 --save-plan "$R/reviews/pre-revoke" | tail -2
run OP delegation revoke ci --save-plan "$R/reviews/revoke-ci"
run OP inventory apply "$R/reviews/revoke-ci" --yes 2>&1 | tail -2
run OP delegation show ci --contract 1
before="$(OP inventory store status --json | jq -c '{generation, accepted: (.accepted|length)}')"
refused CI inventory apply "$R/reviews/pre-revoke" --yes --contract 1
refused CI app image-plan --archive "$R/hello-v1.tar" --destination "$IMG/team-a/hello:v3" --key team-a-hello-v3 "${SRC[@]}" --source-revision 0ddba11 --save-plan "$R/reviews/post-revoke"
after="$(OP inventory store status --json | jq -c '{generation, accepted: (.accepted|length)}')"
echo "store before $before after $after"; [ "$before" = "$after" ] || { echo "UNEXPECTED: a refused deployer review changed the store" >&2; exit 1; }
run K get ns -l nagare.dev/delegation=ci
run K -n team-a get ksvc,deploy -o name
HISTORY_LIMIT=3 run history OP
