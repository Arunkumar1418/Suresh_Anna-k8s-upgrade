# EKS Cluster Upgrade Plan: 1.33 → 1.34
## Cluster: osp-mmb-nonprod-eks-cluster (eu-central-1)

---

## ⚠️ CRITICAL: Clicking "Upgrade" in GUI is NOT Sufficient

**NO** - Simply clicking the upgrade button in EKS console only upgrades the control plane. You must also:
- Upgrade all EKS add-ons
- Upgrade all node groups
- Update workload configurations for deprecated APIs
- Test application compatibility

---

## Phase 1: PRE-UPGRADE ASSESSMENT & INFORMATION GATHERING

### 1.1 Gather Current Cluster State
```bash
# Set region
export AWS_REGION=eu-central-1
export CLUSTER_NAME=osp-mmb-nonprod-eks-cluster

# Get cluster details
aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION > cluster-info.json

# Get current version
aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query 'cluster.version' --output text

# List all node groups
aws eks list-nodegroups --cluster-name $CLUSTER_NAME --region $AWS_REGION

# Get node group details for each
aws eks describe-nodegroup --cluster-name $CLUSTER_NAME --nodegroup-name <nodegroup-name> --region $AWS_REGION

# List all add-ons and versions
aws eks list-addons --cluster-name $CLUSTER_NAME --region $AWS_REGION
aws eks describe-addon --cluster-name $CLUSTER_NAME --addon-name <addon-name> --region $AWS_REGION
```

### 1.2 Document All Kubernetes Resources
```bash
# Get all namespaces
kubectl get namespaces -o yaml > backup/namespaces.yaml

# Get all deployments
kubectl get deployments --all-namespaces -o yaml > backup/deployments.yaml

# Get all StatefulSets (CRITICAL for stateful apps)
kubectl get statefulsets --all-namespaces -o yaml > backup/statefulsets.yaml

# Get all DaemonSets
kubectl get daemonsets --all-namespaces -o yaml > backup/daemonsets.yaml

# Get all Services
kubectl get services --all-namespaces -o yaml > backup/services.yaml

# Get all ConfigMaps
kubectl get configmaps --all-namespaces -o yaml > backup/configmaps.yaml

# Get all Secrets
kubectl get secrets --all-namespaces -o yaml > backup/secrets.yaml

# Get all PVCs
kubectl get pvc --all-namespaces -o yaml > backup/pvcs.yaml

# Get all PVs
kubectl get pv -o yaml > backup/pvs.yaml

# Get all StorageClasses
kubectl get storageclass -o yaml > backup/storageclasses.yaml

# Get all Ingress
kubectl get ingress --all-namespaces -o yaml > backup/ingress.yaml

# Get all CRDs
kubectl get crd -o yaml > backup/crds.yaml

# Get all ServiceAccounts
kubectl get serviceaccounts --all-namespaces -o yaml > backup/serviceaccounts.yaml

# Get all RBAC
kubectl get roles,rolebindings,clusterroles,clusterrolebindings --all-namespaces -o yaml > backup/rbac.yaml
```

### 1.3 Check for Deprecated APIs
```bash
# Install kubent (Kubernetes No Trouble) to check deprecated APIs
brew install kubent  # or download from GitHub

# Run deprecation check
kubent

# Alternative: Use Pluto
brew install pluto
pluto detect-all-in-cluster
```

### 1.4 Identify StatefulSet Applications
```bash
# List all StatefulSets with details
kubectl get statefulsets --all-namespaces -o wide

# For each StatefulSet, check:
# - PVC bindings
# - Update strategy
# - Pod disruption budgets
kubectl get pdb --all-namespaces
```

---

## Phase 2: BACKUP STRATEGY

### 2.1 ETCD Backup (Automatic by AWS)
- AWS automatically backs up etcd every 6 hours
- Retained for 7 days
- Cannot be manually triggered but happens automatically

### 2.2 Application-Level Backups

#### For StatefulSets with Persistent Data:
```bash
# Option 1: Velero (Recommended for production)
# Install Velero
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm install velero vmware-tanzu/velero \
  --namespace velero \
  --create-namespace \
  --set configuration.provider=aws \
  --set configuration.backupStorageLocation.bucket=<your-s3-bucket> \
  --set configuration.backupStorageLocation.config.region=eu-central-1 \
  --set snapshotsEnabled=true \
  --set configuration.volumeSnapshotLocation.config.region=eu-central-1

# Create full cluster backup
velero backup create pre-upgrade-backup-$(date +%Y%m%d-%H%M%S) \
  --include-namespaces '*' \
  --wait

# Verify backup
velero backup describe <backup-name>
velero backup logs <backup-name>
```

#### For Database StatefulSets:
```bash
# PostgreSQL example
kubectl exec -n <namespace> <postgres-pod> -- pg_dump -U <user> <database> > postgres-backup.sql

# MySQL example
kubectl exec -n <namespace> <mysql-pod> -- mysqldump -u <user> -p<password> <database> > mysql-backup.sql

# MongoDB example
kubectl exec -n <namespace> <mongo-pod> -- mongodump --out=/backup
```

#### EBS Volume Snapshots:
```bash
# Get all PVs and their EBS volume IDs
kubectl get pv -o json | jq -r '.items[] | select(.spec.awsElasticBlockStore != null) | .spec.awsElasticBlockStore.volumeID'

# Create snapshots for each volume
aws ec2 create-snapshot \
  --volume-id <volume-id> \
  --description "Pre-upgrade backup $(date +%Y%m%d)" \
  --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Purpose,Value=EKS-Upgrade-Backup}]' \
  --region eu-central-1
```

### 2.3 Configuration Backup
```bash
# Create backup directory
mkdir -p eks-upgrade-backup-$(date +%Y%m%d)
cd eks-upgrade-backup-$(date +%Y%m%d)

# Export all resources
kubectl get all --all-namespaces -o yaml > all-resources.yaml

# Backup Helm releases
helm list --all-namespaces -o yaml > helm-releases.yaml

# For each Helm release, get values
helm get values <release-name> -n <namespace> > helm-values-<release-name>.yaml
```

---

## Phase 3: UPGRADE EXECUTION PLAN (ZERO DOWNTIME)

### 3.1 Control Plane Upgrade (5-10 minutes downtime for API server)

**Important**: During control plane upgrade:
- Existing workloads continue running
- Cannot create/update/delete resources via kubectl
- Applications remain accessible to end users

```bash
# Check upgrade compatibility
aws eks describe-update --name $CLUSTER_NAME --update-id <update-id> --region $AWS_REGION

# Initiate control plane upgrade
aws eks update-cluster-version \
  --name $CLUSTER_NAME \
  --kubernetes-version 1.34 \
  --region $AWS_REGION

# Monitor upgrade progress
aws eks describe-update \
  --name $CLUSTER_NAME \
  --update-id <update-id> \
  --region $AWS_REGION

# Or watch status
watch -n 10 'aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query "cluster.status"'
```

### 3.2 Update EKS Add-ons (CRITICAL - Do this BEFORE node upgrades)

```bash
# Get compatible add-on versions for 1.34
aws eks describe-addon-versions --kubernetes-version 1.34 --region $AWS_REGION

# Update each add-on (in this order):
# 1. VPC CNI
aws eks update-addon \
  --cluster-name $CLUSTER_NAME \
  --addon-name vpc-cni \
  --addon-version <compatible-version> \
  --resolve-conflicts OVERWRITE \
  --region $AWS_REGION

# 2. CoreDNS
aws eks update-addon \
  --cluster-name $CLUSTER_NAME \
  --addon-name coredns \
  --addon-version <compatible-version> \
  --resolve-conflicts OVERWRITE \
  --region $AWS_REGION

# 3. kube-proxy
aws eks update-addon \
  --cluster-name $CLUSTER_NAME \
  --addon-name kube-proxy \
  --addon-version <compatible-version> \
  --resolve-conflicts OVERWRITE \
  --region $AWS_REGION

# 4. EBS CSI Driver (if installed)
aws eks update-addon \
  --cluster-name $CLUSTER_NAME \
  --addon-name aws-ebs-csi-driver \
  --addon-version <compatible-version> \
  --resolve-conflicts OVERWRITE \
  --region $AWS_REGION

# Monitor add-on updates
aws eks describe-addon --cluster-name $CLUSTER_NAME --addon-name <addon-name> --region $AWS_REGION
```

### 3.3 Node Group Upgrade Strategy (ZERO DOWNTIME)

**Strategy: Rolling Update with New Node Group**

#### Option A: Managed Node Groups (Recommended)
```bash
# For each node group:
# 1. Get current node group configuration
aws eks describe-nodegroup \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name <nodegroup-name> \
  --region $AWS_REGION > nodegroup-config.json

# 2. Update node group to use 1.34 AMI
aws eks update-nodegroup-version \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name <nodegroup-name> \
  --region $AWS_REGION

# This will:
# - Launch new nodes with 1.34
# - Drain old nodes gracefully
# - Respect PodDisruptionBudgets
# - Maintain desired capacity

# 3. Monitor the update
aws eks describe-nodegroup \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name <nodegroup-name> \
  --region $AWS_REGION \
  --query 'nodegroup.status'
```

#### Option B: Self-Managed Node Groups (ASG)
```bash
# 1. Get current Launch Template
aws ec2 describe-launch-templates --region $AWS_REGION

# 2. Create new Launch Template version with 1.34 AMI
# Get latest EKS optimized AMI for 1.34
aws ssm get-parameter \
  --name /aws/service/eks/optimized-ami/1.34/amazon-linux-2/recommended/image_id \
  --region $AWS_REGION \
  --query 'Parameter.Value' \
  --output text

# 3. Update ASG with new Launch Template version
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name <asg-name> \
  --launch-template LaunchTemplateId=<template-id>,Version=<new-version> \
  --region $AWS_REGION

# 4. Perform rolling update
# Increase desired capacity temporarily
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name <asg-name> \
  --desired-capacity <current+1> \
  --region $AWS_REGION

# Wait for new node to be ready
kubectl get nodes -w

# Drain old nodes one by one
kubectl drain <old-node-name> \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force \
  --grace-period=300

# Terminate old instance
aws autoscaling terminate-instance-in-auto-scaling-group \
  --instance-id <instance-id> \
  --should-decrement-desired-capacity \
  --region $AWS_REGION

# Repeat for each old node
```

### 3.4 StatefulSet Handling During Node Upgrade

```bash
# Before draining nodes with StatefulSets:

# 1. Check PodDisruptionBudgets
kubectl get pdb --all-namespaces

# 2. If no PDB exists, create one
cat <<EOF | kubectl apply -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: <statefulset-name>-pdb
  namespace: <namespace>
spec:
  minAvailable: 1  # or maxUnavailable: 1
  selector:
    matchLabels:
      app: <statefulset-label>
EOF

# 3. Verify StatefulSet update strategy
kubectl get statefulset <name> -n <namespace> -o yaml | grep -A 5 updateStrategy

# 4. During drain, StatefulSet pods will:
# - Terminate gracefully
# - PVC remains attached
# - Pod reschedules on new node
# - Reattaches to same PVC
# - No data loss
```

---

## Phase 4: POST-UPGRADE VALIDATION

### 4.1 Verify Cluster Health
```bash
# Check cluster version
kubectl version --short

# Check node versions
kubectl get nodes -o wide

# Check all nodes are Ready
kubectl get nodes

# Check system pods
kubectl get pods -n kube-system

# Check add-on status
aws eks list-addons --cluster-name $CLUSTER_NAME --region $AWS_REGION
```

### 4.2 Verify Applications
```bash
# Check all pods are running
kubectl get pods --all-namespaces | grep -v Running

# Check StatefulSets
kubectl get statefulsets --all-namespaces

# Check PVC bindings
kubectl get pvc --all-namespaces

# Check services
kubectl get svc --all-namespaces

# Run smoke tests
kubectl run test-pod --image=busybox --rm -it -- wget -O- http://<service-name>.<namespace>.svc.cluster.local
```

### 4.3 Application Testing
```bash
# Test each critical application endpoint
curl -I https://<application-url>

# Check logs for errors
kubectl logs -n <namespace> <pod-name> --tail=100

# Monitor metrics
kubectl top nodes
kubectl top pods --all-namespaces
```

---

## Phase 5: ROLLBACK STRATEGY

### 5.1 Control Plane Rollback
**IMPORTANT**: AWS EKS does NOT support downgrading control plane version.

**If upgrade fails during control plane upgrade:**
- AWS will automatically rollback
- Monitor via AWS console or CLI

**If issues discovered after control plane upgrade:**
- Cannot rollback control plane
- Must fix forward or restore from backup

### 5.2 Node Group Rollback

#### For Managed Node Groups:
```bash
# If using update-nodegroup-version, AWS handles rollback automatically on failure

# Manual rollback: Create new node group with old version
aws eks create-nodegroup \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name <nodegroup-name>-rollback \
  --node-role <node-role-arn> \
  --subnets <subnet-ids> \
  --instance-types <instance-types> \
  --scaling-config minSize=<min>,maxSize=<max>,desiredSize=<desired> \
  --kubernetes-version 1.33 \
  --region $AWS_REGION

# Drain and delete new node group
kubectl drain <new-node> --ignore-daemonsets --delete-emptydir-data
aws eks delete-nodegroup --cluster-name $CLUSTER_NAME --nodegroup-name <new-nodegroup> --region $AWS_REGION
```

#### For Self-Managed Node Groups:
```bash
# Revert ASG to old Launch Template version
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name <asg-name> \
  --launch-template LaunchTemplateId=<template-id>,Version=<old-version> \
  --region $AWS_REGION

# Perform rolling update back to old version (same process as upgrade)
```

### 5.3 Application Rollback (Velero)
```bash
# List backups
velero backup get

# Restore from backup
velero restore create --from-backup pre-upgrade-backup-<timestamp>

# Monitor restore
velero restore describe <restore-name>
velero restore logs <restore-name>
```

### 5.4 StatefulSet Data Rollback
```bash
# If data corruption occurred:

# 1. Scale down StatefulSet
kubectl scale statefulset <name> -n <namespace> --replicas=0

# 2. Restore from EBS snapshot
aws ec2 create-volume \
  --snapshot-id <snapshot-id> \
  --availability-zone <az> \
  --region eu-central-1

# 3. Update PV to point to new volume
kubectl edit pv <pv-name>
# Update spec.awsElasticBlockStore.volumeID

# 4. Scale up StatefulSet
kubectl scale statefulset <name> -n <namespace> --replicas=<original-count>
```

---

## Phase 6: DETAILED EXECUTION TIMELINE

### Day 1: Preparation (2-4 hours)
1. ✅ Run information gathering scripts
2. ✅ Document all resources
3. ✅ Check deprecated APIs with kubent/pluto
4. ✅ Create backup directory structure
5. ✅ Install Velero (if not already)
6. ✅ Create full Velero backup
7. ✅ Create EBS snapshots for all PVs
8. ✅ Export all Kubernetes resources
9. ✅ Backup databases from StatefulSets
10. ✅ Review and approve upgrade plan with team

### Day 2: Upgrade Execution (2-4 hours)
**Maintenance Window: Schedule during low-traffic period**

**Step 1: Control Plane Upgrade (10-15 min)**
```bash
# 09:00 - Initiate control plane upgrade
aws eks update-cluster-version --name $CLUSTER_NAME --kubernetes-version 1.34 --region $AWS_REGION

# 09:00-09:15 - Monitor progress
watch -n 30 'aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query "cluster.status"'

# Expected: 5-10 minutes API server unavailability
# Applications continue running normally
```

**Step 2: Update Add-ons (15-20 min)**
```bash
# 09:15 - Update VPC CNI
aws eks update-addon --cluster-name $CLUSTER_NAME --addon-name vpc-cni --addon-version <version> --region $AWS_REGION

# 09:20 - Update CoreDNS
aws eks update-addon --cluster-name $CLUSTER_NAME --addon-name coredns --addon-version <version> --region $AWS_REGION

# 09:25 - Update kube-proxy
aws eks update-addon --cluster-name $CLUSTER_NAME --addon-name kube-proxy --addon-version <version> --region $AWS_REGION

# 09:30 - Update EBS CSI Driver
aws eks update-addon --cluster-name $CLUSTER_NAME --addon-name aws-ebs-csi-driver --addon-version <version> --region $AWS_REGION

# Monitor each add-on until Active
```

**Step 3: Node Group Upgrade (1-3 hours depending on node count)**
```bash
# 09:35 - For each node group (one at a time):
aws eks update-nodegroup-version --cluster-name $CLUSTER_NAME --nodegroup-name <nodegroup-1> --region $AWS_REGION

# Monitor node replacement
kubectl get nodes -w

# Verify pods are rescheduled correctly
kubectl get pods --all-namespaces -o wide

# Wait for node group to complete before starting next
# Repeat for each node group
```

**Step 4: Validation (30 min)**
```bash
# 12:00 - Run all validation checks
kubectl get nodes
kubectl get pods --all-namespaces
kubectl get pvc --all-namespaces

# Test critical applications
# Run smoke tests
# Check monitoring dashboards
```

### Day 3: Monitoring (24-48 hours)
1. ✅ Monitor application logs
2. ✅ Monitor cluster metrics
3. ✅ Monitor error rates
4. ✅ Verify StatefulSet data integrity
5. ✅ Keep backups for 7 days before cleanup

---

## CRITICAL CONSIDERATIONS

### 1. StatefulSet Applications
- **Zero Data Loss**: PVCs remain attached during node drain
- **Graceful Shutdown**: Respect terminationGracePeriodSeconds
- **PodDisruptionBudgets**: Ensure at least 1 replica always available
- **Update Strategy**: Use RollingUpdate, not OnDelete
- **Backup Before**: Always backup data before upgrade

### 2. Downtime Expectations
- **Control Plane**: 5-10 min API server unavailability (apps keep running)
- **Node Upgrade**: Zero downtime if done correctly with PDBs
- **StatefulSets**: Brief pod restarts (30-60 sec per pod)
- **Total User Impact**: Near-zero if properly planned

### 3. What Can Go Wrong
- **Deprecated APIs**: Apps using old APIs will fail
- **Add-on Incompatibility**: Old add-ons may not work with 1.34
- **Node Capacity**: Insufficient capacity during rolling update
- **PVC Binding**: PVCs may fail to bind if storage class changed
- **Network Policies**: CNI upgrade may temporarily affect networking

### 4. Rollback Limitations
- ❌ Cannot downgrade control plane
- ✅ Can rollback node groups
- ✅ Can restore applications from Velero
- ✅ Can restore data from EBS snapshots
- ⚠️ Best strategy: Fix forward, not rollback

---

## AUTOMATION SCRIPTS

### Complete Pre-Upgrade Script
```bash
#!/bin/bash
# pre-upgrade-check.sh

set -e

CLUSTER_NAME="osp-mmb-nonprod-eks-cluster"
REGION="eu-central-1"
BACKUP_DIR="eks-upgrade-backup-$(date +%Y%m%d-%H%M%S)"

echo "Creating backup directory: $BACKUP_DIR"
mkdir -p $BACKUP_DIR
cd $BACKUP_DIR

echo "1. Gathering cluster information..."
aws eks describe-cluster --name $CLUSTER_NAME --region $REGION > cluster-info.json
aws eks list-nodegroups --cluster-name $CLUSTER_NAME --region $REGION > nodegroups.json
aws eks list-addons --cluster-name $CLUSTER_NAME --region $REGION > addons.json

echo "2. Backing up Kubernetes resources..."
kubectl get all --all-namespaces -o yaml > all-resources.yaml
kubectl get namespaces -o yaml > namespaces.yaml
kubectl get deployments --all-namespaces -o yaml > deployments.yaml
kubectl get statefulsets --all-namespaces -o yaml > statefulsets.yaml
kubectl get daemonsets --all-namespaces -o yaml > daemonsets.yaml
kubectl get services --all-namespaces -o yaml > services.yaml
kubectl get configmaps --all-namespaces -o yaml > configmaps.yaml
kubectl get secrets --all-namespaces -o yaml > secrets.yaml
kubectl get pvc --all-namespaces -o yaml > pvcs.yaml
kubectl get pv -o yaml > pvs.yaml
kubectl get storageclass -o yaml > storageclasses.yaml
kubectl get ingress --all-namespaces -o yaml > ingress.yaml
kubectl get crd -o yaml > crds.yaml

echo "3. Checking for deprecated APIs..."
if command -v kubent &> /dev/null; then
    kubent > deprecated-apis.txt
else
    echo "kubent not installed, skipping deprecation check"
fi

echo "4. Creating Velero backup..."
velero backup create pre-upgrade-backup-$(date +%Y%m%d-%H%M%S) --wait

echo "5. Creating EBS snapshots..."
kubectl get pv -o json | jq -r '.items[] | select(.spec.awsElasticBlockStore != null) | .spec.awsElasticBlockStore.volumeID' | while read vol; do
    echo "Creating snapshot for $vol"
    aws ec2 create-snapshot --volume-id $vol --description "Pre-upgrade backup $(date +%Y%m%d)" --region $REGION
done

echo "Backup completed in: $BACKUP_DIR"
```

### Complete Upgrade Script
```bash
#!/bin/bash
# upgrade-cluster.sh

set -e

CLUSTER_NAME="osp-mmb-nonprod-eks-cluster"
REGION="eu-central-1"
TARGET_VERSION="1.34"

echo "Starting EKS cluster upgrade to $TARGET_VERSION"

echo "1. Upgrading control plane..."
UPDATE_ID=$(aws eks update-cluster-version \
    --name $CLUSTER_NAME \
    --kubernetes-version $TARGET_VERSION \
    --region $REGION \
    --query 'update.id' \
    --output text)

echo "Update ID: $UPDATE_ID"
echo "Waiting for control plane upgrade to complete..."

while true; do
    STATUS=$(aws eks describe-update \
        --name $CLUSTER_NAME \
        --update-id $UPDATE_ID \
        --region $REGION \
        --query 'update.status' \
        --output text)
    
    echo "Status: $STATUS"
    
    if [ "$STATUS" == "Successful" ]; then
        echo "Control plane upgrade completed successfully"
        break
    elif [ "$STATUS" == "Failed" ] || [ "$STATUS" == "Cancelled" ]; then
        echo "Control plane upgrade failed"
        exit 1
    fi
    
    sleep 30
done

echo "2. Upgrading add-ons..."
for addon in vpc-cni coredns kube-proxy aws-ebs-csi-driver; do
    if aws eks describe-addon --cluster-name $CLUSTER_NAME --addon-name $addon --region $REGION &> /dev/null; then
        echo "Upgrading $addon..."
        ADDON_VERSION=$(aws eks describe-addon-versions \
            --kubernetes-version $TARGET_VERSION \
            --addon-name $addon \
            --region $REGION \
            --query 'addons[0].addonVersions[0].addonVersion' \
            --output text)
        
        aws eks update-addon \
            --cluster-name $CLUSTER_NAME \
            --addon-name $addon \
            --addon-version $ADDON_VERSION \
            --resolve-conflicts OVERWRITE \
            --region $REGION
        
        sleep 10
    fi
done

echo "3. Upgrading node groups..."
NODEGROUPS=$(aws eks list-nodegroups \
    --cluster-name $CLUSTER_NAME \
    --region $REGION \
    --query 'nodegroups' \
    --output text)

for ng in $NODEGROUPS; do
    echo "Upgrading node group: $ng"
    aws eks update-nodegroup-version \
        --cluster-name $CLUSTER_NAME \
        --nodegroup-name $ng \
        --region $REGION
    
    echo "Waiting for node group $ng to complete..."
    while true; do
        STATUS=$(aws eks describe-nodegroup \
            --cluster-name $CLUSTER_NAME \
            --nodegroup-name $ng \
            --region $REGION \
            --query 'nodegroup.status' \
            --output text)
        
        echo "Node group $ng status: $STATUS"
        
        if [ "$STATUS" == "ACTIVE" ]; then
            break
        elif [ "$STATUS" == "DEGRADED" ]; then
            echo "Node group upgrade failed"
            exit 1
        fi
        
        sleep 60
    done
done

echo "Upgrade completed successfully!"
```

---

## FINAL ANSWER TO YOUR QUESTIONS

### Q: Is clicking "Upgrade" in GUI sufficient?
**A: NO.** It only upgrades the control plane. You must also upgrade add-ons and node groups manually.

### Q: How to upgrade without downtime?
**A:** 
1. Control plane upgrade: 5-10 min API unavailability (apps keep running)
2. Use PodDisruptionBudgets for all critical apps
3. Rolling node group updates (one node at a time)
4. Ensure sufficient capacity for pod rescheduling

### Q: How to rollback if something fails?
**A:**
- Control plane: Cannot rollback (AWS auto-rollbacks on failure)
- Node groups: Revert to old Launch Template/AMI
- Applications: Restore from Velero backup
- Data: Restore from EBS snapshots
- **Best practice**: Fix forward, not backward

### Q: How I would do it:
1. **Day 1**: Full backup (Velero + EBS snapshots)
2. **Day 2 Morning**: Upgrade control plane → add-ons → node groups
3. **Day 2-3**: Monitor for 48 hours
4. **Day 7**: Clean up old backups

**Total time**: 3-4 hours execution, 48 hours monitoring
**Downtime**: Near-zero for end users
**Risk**: Low with proper backups and PDBs
