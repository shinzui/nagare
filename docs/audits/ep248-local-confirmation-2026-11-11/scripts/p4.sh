. "$(dirname "$0")/lib.sh"
REV="$(cat "$R/revision")"; IMAGE_REF="k3d-registry.localhost:5000/nagarectl-linux:${REV:0:8}"
step "P4 EP-248 D5/D8: a deployer Pod holding only the bundle reads, is refused outside its delegation, and deploys"
docker tag "nagarectl-linux:${REV:0:8}" "localhost:5000/nagarectl-linux:${REV:0:8}"
docker push "localhost:5000/nagarectl-linux:${REV:0:8}" | tail -1
K -n "$DEPLOYER_NS" delete pod ep248-deployer --ignore-not-found --wait >/dev/null
K apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata: {name: ep248-deployer, namespace: $DEPLOYER_NS}
spec:
  automountServiceAccountToken: false
  enableServiceLinks: false
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, fsGroup: 65532, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: deploy
    image: $IMAGE_REF
    command: ["/bin/sleep", "7200"]
    securityContext: {readOnlyRootFilesystem: true, allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
    resources: {requests: {cpu: 500m, memory: 1Gi}, limits: {cpu: "2", memory: 3Gi}}
    volumeMounts: [{name: work, mountPath: /work}]
  volumes: [{name: work, emptyDir: {}}]
YAML
K -n "$DEPLOYER_NS" wait pod/ep248-deployer --for=condition=Ready --timeout=600s
# The bundle and the rendered fixtures; the Pod has no ServiceAccount token of its own.
tar -C "$R/bundle" -cf - . | D /bin/bash -c 'mkdir -p /work/home /work/tmp /work/in && tar -x -C /work/home && chmod 700 /work/home'
tar -C "$R" -cf - rendered fixtures hello-v1.tar docs-pod.tar | D tar -x -C /work/in
D /bin/bash -c 'test -e /var/run/secrets/kubernetes.io/serviceaccount/token && echo "token present" || echo "no service account token of its own"; ls -la /work/home/.config/nagare/kubeconfigs /work/home/.config/nagare/credentials'

step "P4a D5: with only HOME and XDG_CONFIG_HOME, the guard passes and the store is read"
run DN version --json
run DN inventory history --limit 3
run DN inventory status --scope standalone:site-docs || echo "(status of a scope not yet deployed: exit $?)"
run DN inventory publications || echo "(publications: exit $?)"

step "P4b D8: Kubernetes refuses the bundle everything outside the delegation"
refused DK -n personal create configmap ep248-probe --from-literal=a=b --dry-run=server
refused DK -n nagare-system get secret nagare-minio-credentials
refused DK -n nagare-system patch configmap nagare-shomei-settings --type merge -p '{"data":{"x":"y"}}' --dry-run=server
refused DK create namespace ep248-probe --dry-run=server
refused DK -n team-a get secrets
run DK -n team-a auth can-i create services.serving.knative.dev
run DK -n nagare-system auth can-i update configmap/nagare-access-backends

step "P4c D5/D8: the deployer publishes and deploys a protected site, a protected app and a worker"
SRC=(--source-repository https://forge.example.test/team-a/site --source-run https://ci.example.test/runs/48 --source-revision 5ca1ab1e)
out="$(DN app image-plan --archive /work/in/docs-pod.tar --destination "$IMG/team-a/docs:d1" --key docs-d1 "${SRC[@]}")"; printf '%s\n' "$out" | tail -3
DOCS_IMAGE="$(printf '%s\n' "$out" | sed -n 's/^Image resource: //p' | tail -1)"
out="$(DN app image-plan --archive /work/in/hello-v1.tar --destination "$IMG/team-a/hello:v1" --key team-a-hello-v1 "${SRC[@]}")"; printf '%s\n' "$out" | tail -3
HELLO_IMAGE="$(printf '%s\n' "$out" | sed -n 's/^Image resource: //p' | tail -1)"
printf 'DOCS_IMAGE=%q\nHELLO_IMAGE=%q\n' "$DOCS_IMAGE" "$HELLO_IMAGE" > "$R/ids.env"
SRC2=(--source-repository https://forge.example.test/team-a/site --source-run https://ci.example.test/runs/48)
run DN site deploy --rendered /work/in/rendered/docs.json -C /work/in/fixtures/docs --skip-build --tag d1 --image-resource "$DOCS_IMAGE" "${SRC2[@]}" --source 5ca1ab1e 2>&1 | tail -3
run DN app deploy --rendered /work/in/rendered/app.json --tag v1 --image-resource "$HELLO_IMAGE" "${SRC2[@]}" --source 5ca1ab1e --save-plan /work/tmp/hello-v1 2>&1 | tail -3
run DN inventory apply /work/tmp/hello-v1 --yes 2>&1 | tail -3
run DN worker deploy --rendered /work/in/rendered/worker.json --tag v1 --image-resource "$HELLO_IMAGE" "${SRC[@]}" 2>&1 | tail -3
run DN inventory status --scope standalone:site-docs
K -n team-a wait ksvc/docs --for=condition=Ready --timeout=300s
K -n team-a wait ksvc/hello --for=condition=Ready --timeout=300s
run K -n nagare-system get domainmapping -o custom-columns=NAME:.metadata.name,TARGET:.spec.ref.name
run K -n nagare-system get configmap nagare-access-backends -o jsonpath='{.data.backends\.json}'; echo
run OP inventory history --limit 5
