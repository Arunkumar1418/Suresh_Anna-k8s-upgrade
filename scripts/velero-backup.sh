# ── TOOL: Velero for cluster backup ────────────────────────────
# Install Velero CLI
curl -L https://github.com/vmware-tanzu/velero/releases/latest/download/velero-linux-amd64.tar.gz | tar xz
sudo mv velero-v*/velero /usr/local/bin/

# Install Velero in cluster (with S3 backend)
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.9.0 \
  --bucket your-velero-backup-bucket \
  --backup-location-config region=us-east-1 \
  --snapshot-location-config region=us-east-1 \
  --secret-file ./credentials-velero

# ── CREATE PRE-UPGRADE BACKUP ──────────────────────────────────
CLUSTER_NAME="dev-cluster"
DATE=$(date +%Y%m%d-%H%M%S)

velero backup create "pre-upgrade-${CLUSTER_NAME}-${DATE}" \
  --include-namespaces '*' \
  --include-cluster-resources=true \
  --storage-location default \
  --wait

# Verify backup
velero backup describe "pre-upgrade-${CLUSTER_NAME}-${DATE}"
velero backup logs "pre-upgrade-${CLUSTER_NAME}-${DATE}"

# ── MANUAL BACKUP OF ALL MANIFESTS ────────────────────────────
mkdir -p backups/${CLUSTER_NAME}/{namespaces,crds,rbac,storage,networking}

# Backup all namespaced resources
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  mkdir -p backups/${CLUSTER_NAME}/namespaces/${ns}
  for resource in deployments statefulsets daemonsets services ingresses configmaps secrets pvc hpa vpa pdb; do
    kubectl get ${resource} -n ${ns} -o yaml > \
      backups/${CLUSTER_NAME}/namespaces/${ns}/${resource}.yaml 2>/dev/null
  done
done

# Backup CRDs
kubectl get crd -o yaml > backups/${CLUSTER_NAME}/crds/all-crds.yaml

# Backup RBAC
kubectl get clusterroles,clusterrolebindings,roles,rolebindings -A -o yaml > \
  backups/${CLUSTER_NAME}/rbac/all-rbac.yaml

# Backup Storage classes
kubectl get storageclass,pv -o yaml > \
  backups/${CLUSTER_NAME}/storage/storage.yaml

# Backup cluster-level configs
kubectl get configmap -n kube-system -o yaml > \
  backups/${CLUSTER_NAME}/kube-system-configmaps.yaml

# ── BACKUP EKS CLUSTER CONFIG (via AWS CLI) ────────────────────
aws eks describe-cluster --name ${CLUSTER_NAME} \
  > backups/${CLUSTER_NAME}/eks-cluster-config.json

aws eks list-nodegroups --cluster-name ${CLUSTER_NAME} \
  > backups/${CLUSTER_NAME}/nodegroups-list.json

# Backup each nodegroup config
for ng in $(aws eks list-nodegroups --cluster-name ${CLUSTER_NAME} \
  --query 'nodegroups[*]' --output text); do
  aws eks describe-nodegroup \
    --cluster-name ${CLUSTER_NAME} \
    --nodegroup-name ${ng} \
    > backups/${CLUSTER_NAME}/nodegroup-${ng}.json
done

# ── BACKUP HELM RELEASES ───────────────────────────────────────
helm list -A -o json > backups/${CLUSTER_NAME}/helm-releases.json
for release in $(helm list -A -q); do
  ns=$(helm list -A | grep "^${release}" | awk '{print $2}')
  helm get values ${release} -n ${ns} \
    > backups/${CLUSTER_NAME}/helm-values-${release}.yaml 2>/dev/null
done

# ── COMPRESS AND UPLOAD TO S3 ──────────────────────────────────
tar -czf "backup-${CLUSTER_NAME}-${DATE}.tar.gz" backups/${CLUSTER_NAME}/
aws s3 cp "backup-${CLUSTER_NAME}-${DATE}.tar.gz" \
  s3://your-backup-bucket/eks-upgrades/${CLUSTER_NAME}/