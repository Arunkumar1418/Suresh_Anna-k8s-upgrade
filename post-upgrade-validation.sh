#!/bin/bash
# post-upgrade-validation.sh

set -e

CLUSTER_NAME="osp-mmb-nonprod-eks-cluster"
REGION="eu-central-1"

echo "=========================================="
echo "Post-Upgrade Validation"
echo "=========================================="

echo ""
echo "1. Cluster Version"
aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query 'cluster.version' --output text

echo ""
echo "2. Node Status"
kubectl get nodes -o wide

echo ""
echo "3. System Pods"
kubectl get pods -n kube-system

echo ""
echo "4. All Pods (non-running)"
kubectl get pods --all-namespaces | grep -v Running | grep -v Completed || echo "All pods running"

echo ""
echo "5. StatefulSets"
kubectl get statefulsets --all-namespaces

echo ""
echo "6. PVCs"
kubectl get pvc --all-namespaces

echo ""
echo "7. Add-ons Status"
aws eks list-addons --cluster-name $CLUSTER_NAME --region $REGION

echo ""
echo "Validation complete"
