#!/bin/bash

source anyscale-az-envvars.sh

AKS_VNET_SUBNET_ID=$(az network vnet subnet show -g $RESOURCE_GROUP --vnet-name $VNET_NAME -n aks -o tsv --query id)
STORAGE_SUBNET_ID=$(az network vnet subnet show -g $RESOURCE_GROUP --vnet-name $VNET_NAME -n storage-pe-subnet -o tsv --query id)

############################
# Below is creating the AKS cluster with configuration below:
# 2 nodepools (1 systempool, 1 job execution pool)
# Network Plugin: Azure
# Network Plugin Mode: Overlay
# Network Dataplane: Cilium
# Set the Pod and Service CIDRs to not overlap with the Vnet
# Enable Managed Identity
# Enable OIDC Issuer for Workload Identity
# Enable Workload Identity
# Enable Cluster Autoscaler and set min and max node counts on all nodepools
############################
echo "Creating AKS Cluster with name $CLUSTER_NAME in resource group $RESOURCE_GROUP"
# Cluster Creation Command
az aks create \
-g $RESOURCE_GROUP \
-n $CLUSTER_NAME \
--nodepool-name systempool \
--node-vm-size standard_d2s_v5 \
--node-count 1 \
--network-plugin azure \
--network-plugin-mode overlay \
--network-dataplane cilium \
--vnet-subnet-id $AKS_VNET_SUBNET_ID \
--pod-cidr 10.244.0.0/16 \
--service-cidr 10.245.0.0/24 \
--dns-service-ip 10.245.0.10 \
--enable-managed-identity \
--enable-oidc-issuer \
--enable-workload-identity \
--enable-cluster-autoscaler \
--min-count 1 \
--max-count 3 \
--generate-ssh-keys

# Add a nodepool for anyscale jobs and taint the nodes for Anyscale
echo "Adding a CPU nodepool with autoscaling enabled for Anyscale with name cpu16 to cluster $CLUSTER_NAME"
az aks nodepool add \
-g $RESOURCE_GROUP \
--cluster-name $CLUSTER_NAME \
-n cpu16 \
--node-vm-size "standard_d16s_v5" \
--enable-cluster-autoscaler \
--min-count 0 \
--max-count 5
#--node-taints "node.anyscale.com/capacity-type=ON_DEMAND:NoSchedule"

# Add a H100 gpu nodepool with spot instances for anyscale jobs and taint the nodes for Anyscale
echo "Adding a GPU nodepool with autoscaling enabled for Anyscale with name h100 to cluster $CLUSTER_NAME"
az aks nodepool add \
-g $RESOURCE_GROUP \
--cluster-name $CLUSTER_NAME \
-n h100 \
--node-vm-size "Standard_NC40ads_H100_v5" \
--enable-cluster-autoscaler \
--node-count 1 \
--min-count 0 \
--max-count 1 \
--priority Spot \
--eviction-policy Delete \
--tags EnableManagedGPUExperience=true \
--node-taints "gpu-type=h100:NoSchedule" \
--labels "nvidia.com/gpu.product=NVIDIA-H100"


# Add a T4 GPU spot instance nodepool for anyscale jobs and taint the nodes for Anyscale
echo "Adding a T4 GPU spot instance nodepool with autoscaling enabled for Anyscale with name t4-spot to cluster $CLUSTER_NAME"
az aks nodepool add \
-g $RESOURCE_GROUP \
--cluster-name $CLUSTER_NAME \
-n t4-spot \
--node-vm-size "Standard_NC4as_T4_v3" \
--enable-cluster-autoscaler \
--node-count 1 \
--min-count 0 \
--max-count 8 \
--priority Spot \
--eviction-policy Delete \
--tags EnableManagedGPUExperience=true \
--node-taints "gpu-type=t4:NoSchedule" \
--labels "nvidia.com/gpu.product=NVIDIA-T4"

# Add a A100 GPU instance nodepool for anyscale jobs and taint the nodes for Anyscale
echo "Adding an A100 GPU instance nodepool with autoscaling enabled for Anyscale with name a100 to cluster $CLUSTER_NAME"
az aks nodepool add \
-g $RESOURCE_GROUP \
--cluster-name $CLUSTER_NAME \
-n a100 \
--node-vm-size "Standard_NC24ads_A100_v4" \
--enable-cluster-autoscaler \
--node-count 1 \
--min-count 0 \
--max-count 4 \
--priority Spot \
--eviction-policy Delete \
--tags EnableManagedGPUExperience=true \
--node-taints "gpu-type=a100:NoSchedule" \
--labels "nvidia.com/gpu.product=NVIDIA-A100"

# install nvidia device plugin (production)
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update
helm upgrade --install nvdp nvdp/nvidia-device-plugin -n kube-system
###############
# kube-system（或你指定的 namespace）里一个 DaemonSet：nvidia-device-plugin-daemonset
# Node 上出现资源：
# .status.capacity["nvidia.com/gpu"]
# .status.allocatable["nvidia.com/gpu"]
# 它只把 GPU “报”出来，至于驱动是否齐全、容器能否跑 nvidia-smi，不一定由它保证。
####################

# Get the AKS Cluster credentials
echo "Getting AKS cluster credentials for cluster $CLUSTER_NAME"
az aks get-credentials -g $RESOURCE_GROUP -n $CLUSTER_NAME --overwrite-existing

###################################
# Setting up the Federated Credential for the Managed Identity
# the service account will be used by pods to access storage account with workload identity
####################################
ANYSCALE_NAMESPACE=anyscale-operator 

# Get the OIDC Issuer URL
export AKS_OIDC_ISSUER="$(az aks show -n $CLUSTER_NAME -g $RESOURCE_GROUP --query "oidcIssuerProfile.issuerUrl" -otsv)"

# delete the federated credential if it already exists
echo "Creating federated identity credential with name anyscale-federated-id for the managed identity anyscale-mi"
az identity federated-credential delete \
--name anyscale-federated-id \
--identity-name anyscale-mi \
--resource-group $RESOURCE_GROUP \
--yes
# Create the federated identity credential, mapping the service account to the managed identity
az identity federated-credential create \
--name anyscale-federated-id \
--identity-name anyscale-mi \
--resource-group $RESOURCE_GROUP \
--issuer ${AKS_OIDC_ISSUER} \
--subject system:serviceaccount:${ANYSCALE_NAMESPACE}:anyscale-operator

#############################
# Configure the Storage Account to use blobfuse for the CSI driver and grant access to the kubelet identity
################################
az aks update --enable-blob-driver --resource-group "${RESOURCE_GROUP}" --name "${CLUSTER_NAME}"

KUBELET_IDENTITY=$(az aks show \
-g $RESOURCE_GROUP \
-n $CLUSTER_NAME \
--query identityProfile.kubeletidentity.clientId \
-o tsv)

STORAGE_ACCOUNT_ID=$(az storage account show \
--name $STORAGE_ACCOUNT_NAME \
--resource-group $RESOURCE_GROUP \
--query id \
--output tsv)

az role assignment create \
--role "Storage Blob Data Contributor" \
--assignee $KUBELET_IDENTITY \
--scope $STORAGE_ACCOUNT_ID

#############################
# Configure the Persistent Volume and PVC to be used by pod mounting as file system.
# It is needed when do distributed training in anyscale to store the checkpoints
################################
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-blob-wi
spec:
  capacity:
    storage: 100Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: azureblob-fuse-premium
  csi:
    driver: blob.csi.azure.com
    volumeHandle: ${STORAGE_ACCOUNT_NAME}_${STORAGE_CONTAINER_NAME}
    volumeAttributes:
      storageAccount: ${STORAGE_ACCOUNT_NAME}
      containerName: ${STORAGE_CONTAINER_NAME}

      # 关键字段
      AzureStorageAuthType: MSI
      AzureStorageIdentityClientID: ${KUBELET_IDENTITY}
  mountOptions:
    - -o allow_other
    - --file-cache-timeout-in-seconds=120

---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: anyscale-shared-fuse
  namespace: ${ANYSCALE_NAMESPACE}
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 100Gi

  volumeName: pv-blob-wi
  storageClassName: azureblob-fuse-premium

EOF

#############################
# Install in-cluster ingress controller
################################
# Generate the values file
cat << EOF > anyscale-aks-nginx-values.yaml
controller:
  service:
    type: LoadBalancer
    annotations:
      service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path: "/healthz"
  allowSnippetAnnotations: true
  config:
    enable-underscores-in-headers: true
    annotations-risk-level: "Critical"
  autoscaling:
    enabled: true
EOF

echo "Installing ingress-nginx with Helm"
# Add the ingress-nginx helm repository
helm repo add nginx https://kubernetes.github.io/ingress-nginx
# Run a helm repo update
helm repo update
# Install ingress-nginx
helm upgrade ingress-nginx nginx/ingress-nginx \
--version 4.12.1 \
--namespace ingress-nginx \
--values anyscale-aks-nginx-values.yaml \
--create-namespace \
--install