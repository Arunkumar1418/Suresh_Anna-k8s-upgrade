#!/bin/bash
# rollback-nodegroup.sh

set -e

CLUSTER_NAME="eks-cluster-dev"
REGION="us-west-2"

echo "=========================================="
echo "Node Group Rollback Script"
echo "=========================================="

if [ -z "$1" ]; then
    echo "Usage: ./rollback-nodegroup.sh <nodegroup-name>"
    exit 1
fi

NODEGROUP=$1

echo "Rolling back node group: $NODEGROUP"
echo ""

read -p "Are you sure you want to rollback? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Rollback cancelled"
    exit 0
fi

echo "For managed node groups, create new node group with old version:"
echo ""
echo "aws eks create-nodegroup \\"
echo "  --cluster-name $CLUSTER_NAME \\"
echo "  --nodegroup-name ${NODEGROUP}-rollback \\"
echo "  --node-role <node-role-arn> \\"
echo "  --subnets <subnet-ids> \\"
echo "  --instance-types <instance-types> \\"
echo "  --kubernetes-version 1.33 \\"
echo "  --region $REGION"
echo ""
echo "Then drain and delete the upgraded node group"
