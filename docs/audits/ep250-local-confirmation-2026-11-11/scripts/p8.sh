# EP-250 D6, after the EP-248 phases P1-P4 (the deployer Pod deployed protected docs and hello into team-a).
. "$HOME/Keikaku/bokuno/nagare/docs/audits/ep248-local-confirmation-2026-11-11/scripts/lib.sh"; . "$R/serve.sh"
HOST=docs.team-a.127-0-0-1.sslip.io
review_apply() { OP inventory apply "$1" --yes 2>&1 | tail -1; }
# A request through the ingress over the local CA, with extra curl arguments.
req() { # host path [curl args...]
  local host="$1" path="$2"; shift 2
  curl -sS -o "$R/body" -w '%{http_code}' --max-time 20 --cacert "$R/ca.pem" --connect-to "$host:443:127.0.0.1:$INGRESS_PORT" "$@" "https://$host$path" 2>/dev/null || true
}
step "P8a the backend map names the delegation for both deployed hosts"
K -n nagare-system get configmap nagare-access-backends -o jsonpath='{.data.backends\.json}' | jq .
[ "$(K -n nagare-system get configmap nagare-access-backends -o jsonpath='{.data.backends\.json}' | jq -r --arg h "$HOST" '.[$h].delegation')" = ci ] || { echo "UNEXPECTED: the entry names no delegation" >&2; exit 1; }
# access list reads En directly, through its own forward.
K -n nagare-system port-forward svc/en 18090:80 >/dev/null 2>&1 & EN_PF=$!
for _ in $(seq 1 30); do nc -z 127.0.0.1 18090 2>/dev/null && break; sleep 1; done
EN=(--en-url http://127.0.0.1:18090)
step "P8b a member of engineering and an outsider sign up; engineering gets delegation ci"
export NAGARE_EN_API_KEY="$(K -n nagare-system get secret nagare-en-api-keys -o jsonpath='{.data.read-write}' | base64 -d)"
mkuser() { # label -> prints id email password
  local secret email password id
  secret="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')"; email="ep250-$1-$(printf '%s' "$secret" | tr 'A-Z' 'a-z' | head -c 6)@example.test"; password="Ep-$secret"
  id="$(printf '%s\n' "$password" | K -n nagare-system exec -i deploy/shomei -- env LC_ALL=C.UTF-8 shomei-admin users create --email "$email" --display-name "ep250 $1" --email-verified | sed -n 's/^created user \(user_[A-Za-z0-9_-]*\).*/\1/p')"
  [ -n "$id" ] || { echo "shomei-admin created no user" >&2; exit 1; }
  printf '%s %s %s\n' "$id" "$email" "$password"
}
read -r MEMBER MEMBER_EMAIL MEMBER_PASSWORD < <(mkuser member)
read -r OUTSIDER OUTSIDER_EMAIL OUTSIDER_PASSWORD < <(mkuser outsider)
echo "member $MEMBER, outsider $OUTSIDER"
rm -rf "$R/reviews/team-member" "$R/reviews/delegation-grant" "$R/reviews/delegation-revoke" "$R/reviews/outsider-grant"
run OP access team add-member --team engineering --user "$MEMBER" --save-plan "$R/reviews/team-member" | tail -1; review_apply "$R/reviews/team-member"
if OP access list "${EN[@]}" --host "$HOST" --json | jq -e '.inherited.teams | index("engineering")' >/dev/null 2>&1; then echo "engineering already holds delegation ci"
else run OP access grant --delegation ci --team engineering --save-plan "$R/reviews/delegation-grant" | tail -1; review_apply "$R/reviews/delegation-grant"; fi
step "P8c with no grant of its own on the host: anonymous signs in, the member gets 200, the outsider 403"
start_forwards
trap 'kill $KOURIER_PF $INTERNAL_PF $EN_PF 2>/dev/null || true' EXIT
login() { # email password -> session cookie
  local csrf token
  req "$HOST" "/_nagare/login?rd=%2F" -D "$R/login-headers" > /dev/null
  csrf="$(sed -n 's/^[Ss]et-[Cc]ookie: __Host-nagare_csrf=\([^;]*\).*/\1/p' "$R/login-headers" | tail -1)"
  token="$(sed -n 's/.*name="csrf" value="\([^"]*\)".*/\1/p' "$R/body" | head -1)"
  [ -n "$csrf" ] && [ "$csrf" = "$token" ] || { echo "no matching CSRF cookie and form token" >&2; exit 1; }
  req "$HOST" "/_nagare/login" -X POST -H "Cookie: __Host-nagare_csrf=$csrf" --data-urlencode "csrf=$token" --data-urlencode "rd=/" --data-urlencode "email=$1" --data-urlencode "password=$2" -D "$R/session-headers" > /dev/null
  sed -n 's/^[Ss]et-[Cc]ookie: nagare_session=\([^;]*\).*/\1/p' "$R/session-headers" | tail -1
  rm -f "$R/login-headers" "$R/session-headers"
}
MEMBER_SESSION="$(login "$MEMBER_EMAIL" "$MEMBER_PASSWORD")"; OUTSIDER_SESSION="$(login "$OUTSIDER_EMAIL" "$OUTSIDER_PASSWORD")"
unset MEMBER_PASSWORD OUTSIDER_PASSWORD
[ -n "$MEMBER_SESSION" ] && [ -n "$OUTSIDER_SESSION" ] || { echo "a login set no session" >&2; exit 1; }
as() { req "$HOST" / -H "Cookie: nagare_session=$1"; }
await "anonymous request" 302 public "$HOST" /
await "member through the delegation grant" 200 as "$MEMBER_SESSION"
grep -q 'MP-33 delegated site docs' "$R/body" && echo "ok   the member sees the site"
await "outsider" 403 as "$OUTSIDER_SESSION"
run OP access check --host "$HOST" --user "$MEMBER" --json
run OP access check --host "$HOST" --user "$OUTSIDER" --json
run OP access list "${EN[@]}" --host "$HOST"
step "P8d revoking the delegation grant turns the member's 200 into 403 within the decision TTL"
run OP access revoke --delegation ci --team engineering --save-plan "$R/reviews/delegation-revoke" | tail -1; review_apply "$R/reviews/delegation-revoke"
revoked=$(date +%s)
await "member after the revocation" 403 as "$MEMBER_SESSION"
echo "seconds from revoke to 403: $(( $(date +%s) - revoked ))"
step "P8e a direct host grant still admits the outsider"
run OP access grant --host "$HOST" --user "$OUTSIDER" --save-plan "$R/reviews/outsider-grant" | tail -1; review_apply "$R/reviews/outsider-grant"
await "outsider through a direct grant" 200 as "$OUTSIDER_SESSION"
