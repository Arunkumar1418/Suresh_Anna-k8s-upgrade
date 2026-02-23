#!/usr/bin/env bash

# ── CONFIG ─────────────────────────────────────────────────────
CLUSTER_NAME="eks-cluster-dev"
TARGET_K8S_VERSION="v1.34.0"
LOG_DIR="logs"
AWS_REGION="us-west-2"

# ── INIT ───────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
export AWS_DEFAULT_REGION="$AWS_REGION"

# ── UTILS ──────────────────────────────────────────────────────
install_if_missing() {
  local cmd=$1
  local install_cmd=$2

  if ! command -v "$cmd" &>/dev/null; then
    echo ">>> $cmd not found. Installing..."
    eval "$install_cmd"
  else
    echo ">>> $cmd already installed."
  fi
}

# ── PRE-CHECKS: CORE TOOLS ─────────────────────────────────────
check_core_tools() {
  echo ">>> Checking core tools..."
  sudo yum update -y

  install_if_missing kubectl "sudo curl -o /usr/local/bin/kubectl https://amazon-eks.s3.$AWS_REGION.amazonaws.com/$(curl -s https://api.github.com/repos/kubernetes/kubernetes/releases/latest | jq -r .tag_name)/bin/linux/amd64/kubectl && sudo chmod +x /usr/local/bin/kubectl"
  install_if_missing aws "sudo yum install -y awscli"
  install_if_missing velero "curl -s https://github.com/vmware-tanzu/velero/releases/latest/download/velero-linux-amd64.tar.gz | tar xz && sudo mv velero /usr/local/bin/"
  install_if_missing jq "sudo yum install -y jq"
}

# ── PRE-CHECKS: DEPRECATION SCANNERS ───────────────────────────
check_scanners() {
  echo ">>> Checking API deprecation scanners..."
  install_if_missing pluto "curl -L https://github.com/FairwindsOps/pluto/releases/latest/download/pluto_linux_amd64.tar.gz | tar xz && sudo mv pluto /usr/local/bin/"
  install_if_missing kubent "sh -c \"\$(curl -sSL https://git.io/install-kubent)\""
}

# ── CHECK CURRENT CLUSTER VERSION ──────────────────────────────
check_cluster_version() {
  echo ">>> Checking cluster version..."
  {
    echo "### kubectl version"
    kubectl version --client
    echo
    echo "### EKS cluster version"
    aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" --query 'cluster.version' --output text
  } > "$LOG_DIR/cluster_version.txt"
}

# ── SCAN FOR DEPRECATED APIs ───────────────────────────────────
scan_deprecated_apis() {
  echo ">>> Scanning for deprecated APIs..."
  {
    echo "### Pluto detect-all-in-cluster"
    pluto detect-all-in-cluster --target-versions k8s="$TARGET_K8S_VERSION"
    echo
    echo "### Pluto detect-helm"
    pluto detect-helm --target-versions k8s="$TARGET_K8S_VERSION"
  } > "$LOG_DIR/deprecated_apis.txt"
}

# ── USE KUBENT ─────────────────────────────────────────────────
scan_with_kubent() {
  echo ">>> Running kube-no-trouble (kubent)..."
  kubent --target-version "${TARGET_K8S_VERSION#v}" > "$LOG_DIR/kubent_scan.txt"
}

# ── CHECK ALL API RESOURCES ────────────────────────────────────
check_api_resources() {
  echo ">>> Checking API resources in use..."
  kubectl api-resources --verbs=list --namespaced -o name | \
    xargs -n 1 kubectl get --show-kind --ignore-not-found -A 2>/dev/null | \
    grep -v "^NAME" > "$LOG_DIR/api_resources.txt"
}

# ── CHECK NODE VERSIONS ────────────────────────────────────────
check_node_versions() {
  echo ">>> Checking node versions..."
  {
    echo "### Node details"
    kubectl get nodes -o wide
    echo
    echo "### Node kubelet versions"
    kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.kubeletVersion}{"\n"}{end}'
  } > "$LOG_DIR/node_versions.txt"
}

# ── CHECK ADD-ON VERSIONS ──────────────────────────────────────
check_addons() {
  echo ">>> Checking EKS addons..."
  {
    aws eks list-addons --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME"
    for addon in coredns kube-proxy vpc-cni aws-ebs-csi-driver; do
      echo
      echo "### $addon"
      aws eks describe-addon --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --addon-name "$addon"
    done
  } > "$LOG_DIR/addons.txt"
}

# ── CHECK POD DISRUPTION BUDGETS ───────────────────────────────
check_pdbs() {
  echo ">>> Checking Pod Disruption Budgets..."
  {
    kubectl get pdb -A
    echo
    kubectl get pdb -A -o json | jq '.items[] | {name: .metadata.name, namespace: .metadata.namespace, minAvailable: .spec.minAvailable, maxUnavailable: .spec.maxUnavailable}'
  } > "$LOG_DIR/pdbs.txt"
}

# ── CHECK NON-RUNNING PODS ─────────────────────────────────────
check_non_running_pods() {
  echo ">>> Checking pods not in Running state..."
  kubectl get pods -A --field-selector=status.phase!=Running | grep -v Completed > "$LOG_DIR/non_running_pods.txt"
}

# ── CHECK RESOURCE QUOTAS & LIMITS ─────────────────────────────
check_resource_quotas_limits() {
  echo ">>> Checking resource quotas and limits..."
  {
    kubectl get resourcequota -A
    echo
    kubectl get limitrange -A
  } > "$LOG_DIR/resource_quotas_limits.txt"
}

# ── MAIN ───────────────────────────────────────────────────────
main() {
  check_core_tools
  check_scanners
  check_cluster_version
  scan_deprecated_apis
  scan_with_kubent
  check_api_resources
  check_node_versions
  check_addons
  check_pdbs
  check_non_running_pods
  check_resource_quotas_limits

  echo ">>> Audit complete. Logs saved in $LOG_DIR/"
}

main "$@"
