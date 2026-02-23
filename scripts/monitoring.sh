# ── CHECK CLUSTER EVENTS FOR ERRORS ───────────────────────────
kubectl get events -A --sort-by='.lastTimestamp' | tail -50
kubectl get events -A --sort-by='.lastTimestamp' | grep -E "Warning|Error"

# ── CHECK CONTROL PLANE LOGS (CloudWatch) ─────────────────────
# Enable API server logging if not enabled
aws eks update-cluster-config \
  --name ${CLUSTER_NAME} \
  --logging '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":true}]}'

# Query control plane logs from CloudWatch
aws logs filter-log-events \
  --log-group-name "/aws/eks/${CLUSTER_NAME}/cluster" \
  --filter-pattern "ERROR" \
  --start-time $(date -d '1 hour ago' +%s000) \
  --query 'events[*].message' \
  --output text | head -50

# ── MONITOR NODE METRICS ───────────────────────────────────────
kubectl top nodes
kubectl top pods -A --sort-by=cpu | head -20
kubectl top pods -A --sort-by=memory | head -20

# ── CHECK DEPLOYMENT ROLLOUT STATUS ───────────────────────────
kubectl get deployments -A | grep -v "AVAILABLE"
for deploy in $(kubectl get deployments -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'); do
  ns=$(echo $deploy | cut -d/ -f1)
  name=$(echo $deploy | cut -d/ -f2)
  kubectl rollout status deployment/${name} -n ${ns} --timeout=10s 2>/dev/null
done

# ── SETUP ALERTING (recommended CloudWatch alarms) ────────────
# Node Not Ready alarm
aws cloudwatch put-metric-alarm \
  --alarm-name "eks-${CLUSTER_NAME}-nodes-not-ready" \
  --alarm-description "Alert when EKS nodes are not ready" \
  --metric-name "cluster_failed_node_count" \
  --namespace "ContainerInsights" \
  --dimensions Name=ClusterName,Value=${CLUSTER_NAME} \
  --period 300 \
  --evaluation-periods 2 \
  --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --statistic Average \
  --alarm-actions arn:aws:sns:us-east-1:ACCOUNT_ID:eks-alerts