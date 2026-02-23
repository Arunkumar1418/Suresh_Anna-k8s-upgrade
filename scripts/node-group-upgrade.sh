# ── FOR MANAGED NODE GROUPS ───────────────────────────────────
# List all node groups
aws eks list-nodegroups --cluster-name ${CLUSTER_NAME}

# Upgrade each node group with surge strategy (zero downtime)
for NODEGROUP in $(aws eks list-nodegroups \
  --cluster-name ${CLUSTER_NAME} \
  --query 'nodegroups[*]' --output text); do

  echo "🔄 Upgrading node group: ${NODEGROUP}"

  aws eks update-nodegroup-version \
    --cluster-name ${CLUSTER_NAME} \
    --nodegroup-name ${NODEGROUP} \
    --release-version latest \
    --update-config maxUnavailable=1 \
    --region ${REGION}

  # Wait for nodegroup upgrade to complete
  echo "⏳ Waiting for ${NODEGROUP} upgrade..."
  aws eks wait nodegroup-active \
    --cluster-name ${CLUSTER_NAME} \
    --nodegroup-name ${NODEGROUP}

  echo "✅ ${NODEGROUP} upgraded successfully"

  # Verify nodes
  kubectl get nodes -l eks.amazonaws.com/nodegroup=${NODEGROUP}
done

# ── FOR SELF-MANAGED NODE GROUPS (if applicable) ──────────────
# This requires ASG rolling update - use below approach:

# 1. Update Launch Template with new AMI
NEW_AMI=$(aws ssm get-parameter \
  --name /aws/service/eks/optimized-ami/1.33/amazon-linux-2/recommended/image_id \
  --query 'Parameter.Value' --output text)
echo "New AMI for 1.33: ${NEW_AMI}"

# 2. Update Launch Template version with new AMI
# 3. Start instance refresh with healthy percentage
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name ${ASG_NAME} \
  --preferences '{
    "MinHealthyPercentage": 80,
    "InstanceWarmup": 300,
    "SkipMatching": false
  }'

# Monitor instance refresh
watch -n 30 aws autoscaling describe-instance-refreshes \
  --auto-scaling-group-name ${ASG_NAME} \
  --query 'InstanceRefreshes[0].{Status:Status,PercentageComplete:PercentageComplete}'

# ── VERIFY ALL NODES ARE ON NEW VERSION ───────────────────────
kubectl get nodes -o wide
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.kubeletVersion}{"\n"}{end}'