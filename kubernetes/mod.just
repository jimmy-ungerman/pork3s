set default-list
set default-script
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

[doc('Apply local Flux Kustomization')]
apply-ks ns ks:
    just kube render-local-ks "{{ ns }}" "{{ ks }}" | kubectl apply --server-side --force-conflicts --field-manager=kustomize-controller -f -

[doc('Browse a PVC')]
browse-pvc ns claim:
    kubectl run -n {{ ns }} browse-pvc-{{ claim }} -it --rm --restart=Never \
        --image=mirror.gcr.io/alpine:latest \
        --overrides='{"spec":{"containers":[{"name":"browse-pvc-{{ claim }}","image":"mirror.gcr.io/alpine:latest","stdin":true,"tty":true,"command":["/bin/sh"],"workingDir":"/mnt","volumeMounts":[{"mountPath":"/mnt","name":"data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"{{ claim }}"}}]}}'

[doc('Debug a node')]
debug-node node:
    trap 'kubectl delete pod -n default -l app.kubernetes.io/managed-by=kubectl-debug --field-selector spec.nodeName={{ node }} --ignore-not-found --wait=false' EXIT
    kubectl debug node/{{ node }} -n default -it --image=mirror.gcr.io/alpine:latest --profile=sysadmin

[doc('Delete local Flux Kustomization')]
delete-ks ns ks:
    just kube render-local-ks "{{ ns }}" "{{ ks }}" | kubectl delete -f -

[doc('Prune pods in Failed, Pending, or Succeeded state')]
prune-pods:
    for phase in Failed Pending Succeeded; do
        kubectl delete pods -A --field-selector status.phase="$phase" --ignore-not-found=true
    done

[arg('resource', pattern='hr|ks|gitrepo|ocirepo|es')]
[doc('Sync a resource')]
sync resource:
    kubectl get {{ resource }} --no-headers -A | while read -r ns name _; do
        kubectl -n "$ns" annotate --field-manager flux-client-side-apply --overwrite {{ resource }} "$name" \
            "force-sync=$(date +%s)" \
            "reconcile.fluxcd.io/requestedAt=$(date +%s)" \
            "reconcile.fluxcd.io/forceAt=$(date +%s)"
    done

[doc('View a secret')]
view-secret ns secret:
    kubectl view-secret -n {{ ns }} {{ secret }}

[doc('Migrate an app from volsync to kopiur')]
migrate-to-kopiur app ns='default' capacity='5Gi':
    #!/usr/bin/env bash
    set -euo pipefail
    APP="{{ app }}"
    NAMESPACE="{{ ns }}"
    CAPACITY="{{ capacity }}"
    KS_FILE="{{ source_directory() }}/apps/${NAMESPACE}/${APP}/ks.yaml"

    echo "==> Creating SnapshotPolicy and triggering kopiur snapshot..."
    kubectl apply -f - <<EOF
    apiVersion: kopiur.home-operations.com/v1alpha1
    kind: SnapshotPolicy
    metadata:
      name: ${APP}
      namespace: ${NAMESPACE}
    spec:
      compression:
        compressor: zstd
      mover:
        cache:
          capacity: ${CAPACITY}
          mode: Persistent
          storageClassName: openebs-hostpath
        securityContext:
          runAsUser: 1000
          runAsGroup: 1000
      repository:
        kind: ClusterRepository
        name: ba-sing-se
      retention:
        keepLatest: 3
        keepHourly: 24
        keepDaily: 7
        keepWeekly: 4
      sources:
        - pvc:
            name: ${APP}
      volumeSnapshotClassName: csi-ceph-blockpool
    ---
    apiVersion: kopiur.home-operations.com/v1alpha1
    kind: Snapshot
    metadata:
      name: ${APP}-migration
      namespace: ${NAMESPACE}
    spec:
      policyRef:
        name: ${APP}
      deletionPolicy: Retain
      description: "migration from volsync"
    EOF

    echo "==> Waiting for snapshot to complete..."
    kubectl wait snapshot/${APP}-migration -n ${NAMESPACE} \
      --for=jsonpath='{.status.phase}'=Succeeded \
      --timeout=10m

    echo "==> Cleaning up manual SnapshotPolicy..."
    kubectl delete snapshotpolicy ${APP} -n ${NAMESPACE}

    echo "==> Updating ks.yaml..."
    sed -i '' \
      -e 's|../../../../components/volsync|../../../../components/kopiur/backup|' \
      -e "s|VOLSYNC_CAPACITY:.*|KOPIUR_CAPACITY: ${CAPACITY}|" \
      "${KS_FILE}"

    echo "==> Scaling down ${APP}..."
    DEPLOYMENT=$(kubectl get deployment -n ${NAMESPACE} -l app.kubernetes.io/name=${APP} -o jsonpath='{.items[0].metadata.name}')
    kubectl scale deployment ${DEPLOYMENT} -n ${NAMESPACE} --replicas=0
    kubectl rollout status deployment/${DEPLOYMENT} -n ${NAMESPACE} --timeout=2m

    echo "==> Deleting old PVC..."
    kubectl delete pvc ${APP} -n ${NAMESPACE}

    echo "==> Committing and pushing..."
    git -C "{{ source_directory() }}/.." add "${KS_FILE}"
    git -C "{{ source_directory() }}/.." commit -m "chore: migrate ${APP} from volsync to kopiur"
    git -C "{{ source_directory() }}/.." push

    echo "==> Reconciling flux..."
    flux reconcile kustomization ${APP} -n ${NAMESPACE} --timeout=2m

    echo "==> Waiting for PVC to be bound..."
    kubectl wait pvc/${APP} -n ${NAMESPACE} --for=jsonpath='{.status.phase}'=Bound --timeout=5m

    echo "==> Scaling ${APP} back up..."
    kubectl scale deployment ${DEPLOYMENT} -n ${NAMESPACE} --replicas=1

    echo "==> Waiting for rollout..."
    kubectl rollout status deployment/${DEPLOYMENT} -n ${NAMESPACE} --timeout=5m

    echo "==> Final flux reconcile..."
    flux reconcile kustomization ${APP} -n ${NAMESPACE} --timeout=2m

    echo "==> Done! ${APP} migrated to kopiur."

[private]
render-local-ks ns ks:
    flate build ks --namespace "{{ ns }}" --output yaml "{{ ks }}"
