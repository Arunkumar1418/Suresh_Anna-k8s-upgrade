# ── SET VARIABLES ─────────────────────────────────────────────
CLUSTER_NAME="eks-cluster-dev"    # Change per env
REGION="us-west-2"
NEW_VERSION="1.34"

# ── PRE-FLIGHT: CHECK UPGRADE READINESS ──────────────────────
aws eks describe-addon-versions --kubernetes-version ${NEW_VERSION} \
  --query 'addons[*].{Name:addonName,Versions:addonVersions[0].addonVersion}' \
  --output table

# Check if upgrade is available
aws eks describe-cluster \
  --name ${CLUSTER_NAME} \
  --query 'cluster.{Name:name,Version:version,Status:status}' \
  --output table

# ── CORDON ALL NODES (optional - for controlled maintenance) ───
# NOTE: For zero downtime, skip this and let rolling update handle it
# kubectl cordon $(kubectl get nodes -o name)

# ── UPGRADE CONTROL PLANE ─────────────────────────────────────
echo "🚀 Starting Control Plane upgrade for ${CLUSTER_NAME}..."
aws eks update-cluster-version \
  --name ${CLUSTER_NAME} \
  --kubernetes-version ${NEW_VERSION} \
  --region ${REGION}

# ── MONITOR UPGRADE PROGRESS ──────────────────────────────────
# This takes 10-20 minutes typically
watch -n 30 aws eks describe-cluster \
  --name ${CLUSTER_NAME} \
  --query 'cluster.{Status:status,Version:version,UpdateStatus:update}' \
  --output table

# OR use this loop
while true; do
  STATUS=$(aws eks describe-cluster \
    --name ${CLUSTER_NAME} \
    --query 'cluster.status' \
    --output text)
  echo "$(date): Cluster status: ${STATUS}"
  if [ "$STATUS" = "ACTIVE" ]; then
    echo "✅ Control plane upgrade complete!"
    break
  fi
  sleep 30
done

# ── VERIFY CONTROL PLANE VERSION ──────────────────────────────
aws eks describe-cluster \
  --name ${CLUSTER_NAME} \
  --query 'cluster.version' \
  --output text