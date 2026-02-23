# ── GET LATEST COMPATIBLE ADDON VERSIONS ──────────────────────
K8S_VERSION="1.33"

for ADDON in coredns kube-proxy vpc-cni aws-ebs-csi-driver; do
  LATEST=$(aws eks describe-addon-versions \
    --kubernetes-version ${K8S_VERSION} \
    --addon-name ${ADDON} \
    --query 'addons[0].addonVersions[0].addonVersion' \
    --output text)
  echo "${ADDON}: ${LATEST}"
done

# ── UPGRADE EACH ADDON ─────────────────────────────────────────
# vpc-cni FIRST (networking dependency)
VPC_CNI_VERSION=$(aws eks describe-addon-versions \
  --kubernetes-version 1.33 \
  --addon-name vpc-cni \
  --query 'addons[0].addonVersions[0].addonVersion' \
  --output text)

aws eks update-addon \
  --cluster-name ${CLUSTER_NAME} \
  --addon-name vpc-cni \
  --addon-version ${VPC_CNI_VERSION} \
  --resolve-conflicts OVERWRITE \
  --region ${REGION}

# Wait for vpc-cni to be ACTIVE
aws eks wait addon-active \
  --cluster-name ${CLUSTER_NAME} \
  --addon-name vpc-cni

echo "✅ vpc-cni upgraded"

# kube-proxy
KUBE_PROXY_VERSION=$(aws eks describe-addon-versions \
  --kubernetes-version 1.33 \
  --addon-name kube-proxy \
  --query 'addons[0].addonVersions[0].addonVersion' \
  --output text)

aws eks update-addon \
  --cluster-name ${CLUSTER_NAME} \
  --addon-name kube-proxy \
  --addon-version ${KUBE_PROXY_VERSION} \
  --resolve-conflicts OVERWRITE \
  --region ${REGION}

aws eks wait addon-active \
  --cluster-name ${CLUSTER_NAME} \
  --addon-name kube-proxy

echo "✅ kube-proxy upgraded"

# CoreDNS
COREDNS_VERSION=$(aws eks describe-addon-versions \
  --kubernetes-version 1.33 \
  --addon-name coredns \
  --query 'addons[0].addonVersions[0].addonVersion' \
  --output text)

aws eks update-addon \
  --cluster-name ${CLUSTER_NAME} \
  --addon-name coredns \
  --addon-version ${COREDNS_VERSION} \
  --resolve-conflicts OVERWRITE \
  --region ${REGION}

aws eks wait addon-active \
  --cluster-name ${CLUSTER_NAME} \
  --addon-name coredns

echo "✅ CoreDNS upgraded"

# EBS CSI Driver
EBS_CSI_VERSION=$(aws eks describe-addon-versions \
  --kubernetes-version 1.33 \
  --addon-name aws-ebs-csi-driver \
  --query 'addons[0].addonVersions[0].addonVersion' \
  --output text)

aws eks update-addon \
  --cluster-name ${CLUSTER_NAME} \
  --addon-name aws-ebs-csi-driver \
  --addon-version ${EBS_CSI_VERSION} \
  --resolve-conflicts OVERWRITE \
  --region ${REGION}

aws eks wait addon-active \
  --cluster-name ${CLUSTER_NAME} \
  --addon-name aws-ebs-csi-driver

echo "✅ EBS CSI Driver upgraded"

# ── VERIFY ALL ADDONS ─────────────────────────────────────────
aws eks list-addons --cluster-name ${CLUSTER_NAME} \
  --query 'addons[*]' --output table

for ADDON in coredns kube-proxy vpc-cni aws-ebs-csi-driver; do
  aws eks describe-addon \
    --cluster-name ${CLUSTER_NAME} \
    --addon-name ${ADDON} \
    --query 'addon.{Name:addonName,Version:addonVersion,Status:status}' \
    --output table
done