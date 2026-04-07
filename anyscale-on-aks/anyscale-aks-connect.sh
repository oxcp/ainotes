#!/bin/bash

source anyscale-az-envvars.sh

AKS_VNET_SUBNET_ID=$(az network vnet subnet show -g $RESOURCE_GROUP --vnet-name $VNET_NAME -n aks -o tsv --query id)
STORAGE_SUBNET_ID=$(az network vnet subnet show -g $RESOURCE_GROUP --vnet-name $VNET_NAME -n storage-pe-subnet -o tsv --query id)

# Register the Anyscale cloud instance
anyscale cloud register \
--name $ANYSCALE_CLOUD_INSTANCE_NAME \
--region $LOCATION \
--provider azure \
--compute-stack k8s \
--cloud-storage-bucket-name "azure://${STORAGE_CONTAINER_NAME}" \
--cloud-storage-bucket-endpoint "https://${STORAGE_ACCOUNT_NAME}.blob.core.windows.net"

export ANYSCALE_CLOUD_ID=$(anyscale cloud get -n $ANYSCALE_CLOUD_INSTANCE_NAME | yq '.resources[0].cloud_resource_id')
echo "Anyscale Cloud ID: $ANYSCALE_CLOUD_ID"

helm repo add anyscale https://anyscale.github.io/helm-charts
helm repo update

# Get the managed identity principal ID
ANYSCALE_MI_PRINCIPAL_ID=$(az identity show \
--name anyscale-mi \
--resource-group $RESOURCE_GROUP \
--query principalId \
--output tsv)

yq -i '.global.cloudDeploymentId = env(ANYSCALE_CLOUD_ID)' custom_values.yaml

# print the content of custom_values.yaml to verify the cloudDeploymentId is set
cat custom_values.yaml
# wait for user confirmation before proceeding
read -p "Please verify the custom_values.yaml and press Enter to continue..."


# make sure to update the custom_values.yaml with the cloudDeploymentId before running this command
helm upgrade anyscale-operator anyscale/anyscale-operator \
  --set-string global.cloudDeploymentId=${ANYSCALE_CLOUD_ID} \
  --set-string global.cloudProvider=azure \
  --set-string global.auth.audience=api://086bc555-6989-4362-ba30-fded273e432b/.default \
  --set-string workloads.serviceAccount.name=anyscale-operator \
  --set-string global.auth.anyscaleCliToken=${ANYSCALE_CLI_TOKEN} \
  --set-string global.auth.iamIdentity=${ANYSCALE_MI_PRINCIPAL_ID} \
  --namespace $ANYSCALE_NAMESPACE \
  -f anyscale-operator-custom_values.yaml \
  --create-namespace \
  --wait \
  -i

# Get the managed identity client id
# Patch the service account to include the managed identity client id
# Patch the service account to set the workload identity enabled flag
MI_CLIENT_ID=$(az identity show -g $RESOURCE_GROUP -n anyscale-mi -o tsv --query clientId)
kubectl patch sa anyscale-operator -n $ANYSCALE_NAMESPACE --type='json' -p="[{"op": "add", "path": "/metadata/annotations/azure.workload.identity~1client-id", "value": "$MI_CLIENT_ID"}]"
kubectl patch sa anyscale-operator -n $ANYSCALE_NAMESPACE --type='json' -p='[{"op": "add", "path": "/metadata/labels/azure.workload.identity~1use", "value": "true"}]'
kubectl delete pods -n anyscale-operator -l app=anyscale-operator

# Steps to update the anyscale API key in the future:
# 1. Create new anyscale API key in the Anyscale console
# 2. Update the secrets anyscale-cli-token in the anyscale-operator namespace, with the Base64 encode value of the new API key on "ANYSCALE_CLI_TOKEN"
# 3. Run command: "kubectl rollout restart deployment anyscale-operator -n anyscale-operator"
