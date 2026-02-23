# ── INIT ───────────────────────────────────────────────────────
mkdir -p current_state

# ── CHECK CURRENT CLUSTER VERSION ──────────────────────────────
kubectl version --short > current_state/cluster_version.txt
aws eks describe-cluster --region us-west-2 --name <cluster-name> --query 'cluster.version' --output text > current_state/eks_version.txt

# ── SCAN FOR DEPRECATED APIs IN USE ────────────────────────────
# Install pluto (API deprecation scanner - critical tool)
curl -L https://github.com/FairwindsOps/pluto/releases/latest/download/pluto_linux_amd64.tar.gz | tar xz
sudo mv pluto /usr/local/bin/

# Run against live cluster
pluto detect-all-in-cluster --target-versions k8s=v1.33.0 > current_state/pluto_cluster_scan.txt

# Run against your helm releases
pluto detect-helm --target-versions k8s=v1.33.0 > current_state/pluto_helm_scan.txt

# ── USE KUBENT (kube-no-trouble) FOR DEEPER SCAN ───────────────
sh -c "$(curl -sSL https://git.io/install-kubent)"
kubent --target-version 1.33 > current_state/kubent_scan.txt

# ── CHECK ALL API RESOURCES CURRENTLY IN USE ───────────────────
kubectl api-resources --verbs=list --namespaced -o name | \
  xargs -n 1 kubectl get --show-kind --ignore-not-found -A 2>/dev/null | \
  grep -v "^NAME" > current_state/api_resources.txt

# ── CHECK NODE VERSIONS ────────────────────────────────────────
kubectl get nodes -o wide > current_state/node_details.txt
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' > current_state/node_versions.txt

# ── CHECK ADD-ON VERSIONS ──────────────────────────────────────
aws eks list-addons --region us-west-2 --cluster-name <cluster-name> > current_state/addons_list.txt
aws eks describe-addon --region us-west-2 --cluster-name <cluster-name> --addon-name coredns > current_state/addon_coredns.txt
aws eks describe-addon --region us-west-2 --cluster-name <cluster-name> --addon-name kube-proxy > current_state/addon_kube_proxy.txt
aws eks describe-addon --region us-west-2 --cluster-name <cluster-name> --addon-name vpc-cni > current_state/addon_vpc_cni.txt
aws eks describe-addon --region us-west-2 --cluster-name <cluster-name> --addon-name aws-ebs-csi-driver > current_state/addon_ebs_csi.txt

# ── CHECK POD DISRUPTION BUDGETS (critical for zero downtime) ──
kubectl get pdb -A > current_state/pdbs.txt
kubectl get pdb -A -o json | jq '.items[] | {name: .metadata.name, namespace: .metadata.namespace, minAvailable: .spec.minAvailable, maxUnavailable: .spec.maxUnavailable}' > current_state/pdbs_detailed.txt

# ── CHECK FOR PODS NOT IN RUNNING STATE ────────────────────────
kubectl get pods -A --field-selector=status.phase!=Running | grep -v Completed > current_state/non_running_pods.txt

# ── CHECK RESOURCE QUOTAS & LIMITS ────────────────────────────
kubectl get resourcequota -A > current_state/resourcequotas.txt
kubectl get limitrange -A > current_state/limitranges.txt
