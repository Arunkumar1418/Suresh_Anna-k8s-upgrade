# ── CREATE VALIDATION SCRIPT ──────────────────────────────────
#!/bin/bash

CLUSTER_NAME=$1
EXPECTED_VERSION="v1.34"
ERRORS=0

echo "═══════════════════════════════════════════════"
echo "   CLUSTER VALIDATION: ${CLUSTER_NAME}"
echo "═══════════════════════════════════════════════"

# 1. Check cluster version
echo ""
echo "1️⃣  Checking cluster version..."
CLUSTER_VERSION=$(kubectl version --short 2>/dev/null | grep "Server Version" | awk '{print $3}')
if [[ "${CLUSTER_VERSION}" == *"1.34"* ]]; then
  echo "   ✅ Cluster version: ${CLUSTER_VERSION}"
else
  echo "   ❌ Unexpected cluster version: ${CLUSTER_VERSION}"
  ERRORS=$((ERRORS+1))
fi

# 2. Check all nodes are Ready
echo ""
echo "2️⃣  Checking node status..."
NOT_READY=$(kubectl get nodes --no-headers | grep -v "Ready" | grep -v "^$" | wc -l)
TOTAL_NODES=$(kubectl get nodes --no-headers | wc -l)
if [ "${NOT_READY}" -eq 0 ]; then
  echo "   ✅ All ${TOTAL_NODES} nodes are Ready"
else
  echo "   ❌ ${NOT_READY} nodes are NOT Ready"
  kubectl get nodes | grep -v Ready
  ERRORS=$((ERRORS+1))
fi

# 3. Check node versions match
echo ""
echo "3️⃣  Checking node kubelet versions..."
OLD_NODES=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' | grep -v "1.34" | wc -l)
if [ "${OLD_NODES}" -eq 0 ]; then
  echo "   ✅ All nodes running kubelet 1.34"
else
  echo "   ❌ ${OLD_NODES} nodes still on old kubelet version"
  kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.kubeletVersion}{"\n"}{end}'
  ERRORS=$((ERRORS+1))
fi

# 4. Check all pods in Running/Completed state
echo ""
echo "4️⃣  Checking pod health..."
UNHEALTHY=$(kubectl get pods -A --no-headers | grep -v -E "Running|Completed|Succeeded" | wc -l)
if [ "${UNHEALTHY}" -eq 0 ]; then
  echo "   ✅ All pods are healthy"
else
  echo "   ⚠️  ${UNHEALTHY} pods in non-running state:"
  kubectl get pods -A | grep -v -E "Running|Completed|Succeeded|NAME"
  ERRORS=$((ERRORS+1))
fi

# 5. Check system namespace pods
echo ""
echo "5️⃣  Checking kube-system pods..."
KUBE_SYSTEM_ISSUES=$(kubectl get pods -n kube-system --no-headers | grep -v -E "Running|Completed" | wc -l)
if [ "${KUBE_SYSTEM_ISSUES}" -eq 0 ]; then
  echo "   ✅ All kube-system pods running"
else
  echo "   ❌ Issues in kube-system:"
  kubectl get pods -n kube-system | grep -v Running
  ERRORS=$((ERRORS+1))
fi

# 6. Check CoreDNS
echo ""
echo "6️⃣  Checking CoreDNS..."
kubectl run dns-test --image=busybox:1.28 --restart=Never --rm -i \
  --timeout=30s -- nslookup kubernetes.default.svc.cluster.local > /dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "   ✅ CoreDNS DNS resolution working"
else
  echo "   ❌ CoreDNS DNS resolution FAILED"
  ERRORS=$((ERRORS+1))
fi

# 7. Check services and endpoints
echo ""
echo "7️⃣  Checking services have endpoints..."
SERVICES_NO_ENDPOINTS=$(kubectl get endpoints -A --no-headers | awk '{print $3}' | grep -c "^<none>$" 2>/dev/null || echo 0)
echo "   ℹ️  Services with no endpoints: ${SERVICES_NO_ENDPOINTS}"

# 8. Check HPA status
echo ""
echo "8️⃣  Checking HPA..."
kubectl get hpa -A

# 9. Check PVC/PV binding
echo ""
echo "9️⃣  Checking PVC status..."
UNBOUND=$(kubectl get pvc -A --no-headers | grep -v Bound | wc -l)
if [ "${UNBOUND}" -eq 0 ]; then
  echo "   ✅ All PVCs are Bound"
else
  echo "   ❌ ${UNBOUND} PVCs not Bound"
  kubectl get pvc -A | grep -v Bound
  ERRORS=$((ERRORS+1))
fi

# 10. Check addon versions
echo ""
echo "🔟  Checking EKS addon versions..."
aws eks list-addons --cluster-name ${CLUSTER_NAME} --query 'addons[*]' --output text | \
  tr '\t' '\n' | while read addon; do
  VERSION=$(aws eks describe-addon --cluster-name ${CLUSTER_NAME} --addon-name ${addon} \
    --query 'addon.addonVersion' --output text)
  STATUS=$(aws eks describe-addon --cluster-name ${CLUSTER_NAME} --addon-name ${addon} \
    --query 'addon.status' --output text)
  echo "   📦 ${addon}: ${VERSION} [${STATUS}]"
done

echo ""
echo "═══════════════════════════════════════════════"
if [ "${ERRORS}" -eq 0 ]; then
  echo "   🎉 VALIDATION PASSED - ${CLUSTER_NAME} is healthy!"
else
  echo "   ❌ VALIDATION FAILED - ${ERRORS} error(s) found"
  echo "   🚫 DO NOT PROCEED to next environment"
fi
echo "═══════════════════════════════════════════════"

exit ${ERRORS}