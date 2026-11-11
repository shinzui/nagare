. "$(dirname "$0")/lib.sh"; . "$R/serve.sh"; ids
REV="$(cat "$R/revision")"; IMAGE_REF="k3d-registry.localhost:5000/nagarectl-linux:${REV:0:8}"
step "P5a EP-252 D5: a hardened Pod with no Docker socket packages the site with the layered builder"
docker tag "nagarectl-linux:${REV:0:8}" "localhost:5000/nagarectl-linux:${REV:0:8}"
docker push "localhost:5000/nagarectl-linux:${REV:0:8}" | tail -1
K -n team-a-build delete pod mp33-builder --ignore-not-found --wait >/dev/null
K apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata: {name: mp33-builder, namespace: team-a-build}
spec:
  automountServiceAccountToken: false
  enableServiceLinks: false
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, fsGroup: 65532, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: build
    image: $IMAGE_REF
    command: ["/bin/sleep", "3600"]
    securityContext: {readOnlyRootFilesystem: true, allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
    resources: {requests: {cpu: 500m, memory: 1Gi}, limits: {cpu: "2", memory: 3Gi}}
    volumeMounts: [{name: work, mountPath: /work}]
  volumes: [{name: work, emptyDir: {}}]
YAML
K -n team-a-build wait pod/mp33-builder --for=condition=Ready --timeout=600s
run K -n team-a-build get pod mp33-builder -o jsonpath='{.spec.securityContext} {.spec.containers[0].securityContext} {.spec.automountServiceAccountToken} {.spec.volumes}'; echo
X() { K -n team-a-build exec -i mp33-builder -- "$@"; }
tar -C "$R" -cf - fixtures/docs package-rehearsal/base.tar | X /bin/bash -c 'mkdir -p $HOME $TMPDIR /work/in /work/out && tar -x -C /work/in'
X /bin/bash -c 'id; test -e /var/run/docker.sock && echo "docker socket present" || echo "no docker socket"; command -v docker || echo "no docker binary"; test -e /var/run/secrets/kubernetes.io/serviceaccount/token && echo "token present" || echo "no service account token"; touch /probe 2>/dev/null && echo "root writable" || echo "root read-only"'
run X /bin/bash -c 'cd /work/in/fixtures/docs && nagarectl site package -f nagare/Config.hs --builder layered --base-archive /work/in/package-rehearsal/base.tar --platform linux/arm64 --tag d1 --archive /work/out/docs.tar && sha256sum /work/out/docs.tar'
X cat /work/out/docs.tar > "$R/docs-pod.tar"
sha256sum "$R/docs-pod.tar"
K -n team-a-build delete pod mp33-builder --wait=false >/dev/null

step "P5b EP-247 D9 / EP-249 D6 / EP-252 D5: the deployer publishes and deploys from rendered documents"
out="$(CI app image-plan --archive "$R/docs-pod.tar" --destination "$IMG/team-a/docs:d1" --key docs-d1 "${SRC[@]}" --source-revision 5ca1ab1e)"; printf '%s\n' "$out" | tail -3
setid DOCS_IMAGE "$(printf '%s\n' "$out" | imageid)"
out="$(CI app image-plan --archive "$R/hello-v1.tar" --destination "$IMG/team-a/hello:v1" --key team-a-hello-v1 "${SRC[@]}" --source-revision 5ca1ab1e)"; printf '%s\n' "$out" | tail -3
setid HELLO_IMAGE "$(printf '%s\n' "$out" | imageid)"; ids
run CI site deploy --rendered "$R/rendered/docs.json" -C "$R/fixtures/docs" --skip-build --tag d1 --image-resource "$DOCS_IMAGE" "${SRC[@]}" --source 5ca1ab1e 2>&1 | tail -3
run CI app deploy --rendered "$R/rendered/app.json" --tag v1 --image-resource "$HELLO_IMAGE" "${SRC[@]}" --source 5ca1ab1e 2>&1 | tail -3

step "P5c EP-247 D4/D9: a hostname outside the delegation is refused before any store write"
before="$(OP inventory store status --json | jq -c '{generation, accepted: (.accepted|length)}')"
refused CI site deploy --rendered "$R/rendered/rogue.json" -C "$R/fixtures/docs" --skip-build --tag d1 --image-resource "$DOCS_IMAGE" "${SRC[@]}" --source 5ca1ab1e --save-plan "$R/reviews/rogue"
after="$(OP inventory store status --json | jq -c '{generation, accepted: (.accepted|length)}')"
echo "store before $before after $after"; [ "$before" = "$after" ] || { echo "UNEXPECTED: the refused proposal changed the store" >&2; exit 1; }
[ ! -e "$R/reviews/rogue/review.json" ] || { echo "UNEXPECTED: a refused proposal saved a review" >&2; exit 1; }

step "P5d the protected site and app serve"
K -n team-a wait ksvc/docs --for=condition=Ready --timeout=300s; K -n team-a wait ksvc/hello --for=condition=Ready --timeout=300s
run K -n nagare-system get domainmapping docs.team-a.127-0-0-1.sslip.io hello.team-a.127-0-0-1.sslip.io -o custom-columns=NAME:.metadata.name,TARGET:.spec.ref.name
start_forwards
await "anonymous docs.team-a (protected)" 302 public docs.team-a.127-0-0-1.sslip.io
await "anonymous hello.team-a (protected)" 302 public hello.team-a.127-0-0-1.sslip.io
await "docs origin serves its files" 200 origin docs.team-a.svc.cluster.local
grep -q 'MP-33 delegated site docs' "$R/body" && echo "ok   docs origin body: $(cat "$R/body")"
await "hello origin serves" 200 origin hello.team-a.svc.cluster.local
grep -q 'MP-33 delegated hello' "$R/body" && echo "ok   hello origin body: $(cat "$R/body")"
run K -n team-a get ksvc -o custom-columns=NAME:.metadata.name,URL:.status.url,VISIBILITY:.metadata.labels.networking\\.knative\\.dev/visibility,IMAGE:.spec.template.spec.containers[0].image
