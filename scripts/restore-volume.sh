#!/usr/bin/env bash
# scripts/restore-volume.sh (EP-36) — restore an app-volume snapshot from GCS into
# a SCRATCH PVC, never over the live volume. Mirrors restore-sqlite.sh /
# restore-postgres.sh: project-isolation preflight, scratch-first, non-destructive.
#
# Usage:
#   scripts/restore-volume.sh gs://BUCKET/volumes/<app>/<volume>/<ts>.tar.gz [SCRATCH_PVC]
#
# Env:
#   NAGARE_NAMESPACE  namespace for the scratch PVC + Job (default: personal)
#   RESTORE_SIZE      scratch PVC size (default: 5Gi; must be >= the volume)
#
# The snapshot is untarred into a disposable PVC named SCRATCH_PVC (default
# vol-restore-scratch). The live PVC is never mounted. After the restore Job
# completes, its logs print a file listing of the restored tree so you can
# compare it to the source before promoting. Promotion (copying into the live
# volume) is a deliberate, separate, manual step.
set -euo pipefail

# --- project-isolation preflight: refuse to run outside tan-nb-exp ---
PROJECT=tan-nb-exp
ACTIVE_PROJECT="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
if [ "$ACTIVE_PROJECT" != "$PROJECT" ]; then
  echo "refusing to run: gcloud active project is '${ACTIVE_PROJECT:-<unset>}', expected '$PROJECT'." >&2
  exit 1
fi

OBJECT="${1:?usage: restore-volume.sh gs://BUCKET/volumes/<app>/<volume>/<ts>.tar.gz [SCRATCH_PVC]}"
SCRATCH_PVC="${2:-vol-restore-scratch}"
NS="${NAGARE_NAMESPACE:-personal}"
SIZE="${RESTORE_SIZE:-5Gi}"
JOB="nagare-restore-${SCRATCH_PVC}"

echo "restoring ${OBJECT} into scratch PVC '${SCRATCH_PVC}' (namespace '${NS}', size ${SIZE})"

# 1) Disposable scratch PVC (local-path, RWO). Never the live PVC.
kubectl apply -f - <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${SCRATCH_PVC}
  namespace: ${NS}
  labels:
    nagare.dev/managed-by: nagarectl
    nagare.dev/restore-scratch: "true"
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: ${SIZE}
YAML

# 2) One-off Job: stream the archive from GCS and untar it into the scratch PVC,
#    then print a listing. ADC resolves the node service account via the metadata
#    IP; the project is pinned to tan-nb-exp (in-cluster analogue of the preflight).
kubectl delete job "${JOB}" -n "${NS}" --ignore-not-found
kubectl apply -f - <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
  namespace: ${NS}
  labels:
    nagare.dev/managed-by: nagarectl
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: restore
          image: google/cloud-sdk:slim
          command: ["/bin/sh", "-c"]
          args:
            - >
              set -e;
              gsutil cp "\$OBJECT" - | tar -C /restore -xzf -;
              echo '--- restored tree (first 50 entries) ---';
              find /restore -maxdepth 3 | head -50
          env:
            - { name: OBJECT, value: "${OBJECT}" }
            - { name: GCE_METADATA_HOST, value: "169.254.169.254" }
            - { name: CLOUDSDK_CORE_PROJECT, value: "tan-nb-exp" }
          volumeMounts:
            - { name: restore, mountPath: /restore }
      volumes:
        - name: restore
          persistentVolumeClaim:
            claimName: ${SCRATCH_PVC}
YAML

# 3) Wait for completion and show the listing for comparison.
kubectl wait --for=condition=complete --timeout=600s "job/${JOB}" -n "${NS}"
kubectl logs "job/${JOB}" -n "${NS}"

echo
echo "restored into scratch PVC '${SCRATCH_PVC}' in namespace '${NS}'; listing above. Promote manually."
echo "clean up when done:  kubectl delete job ${JOB} pvc ${SCRATCH_PVC} -n ${NS}"
