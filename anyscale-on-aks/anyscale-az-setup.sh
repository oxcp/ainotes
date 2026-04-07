#!/bin/bash

source anyscale-az-envvars.sh

# Login to Azure and select the target deployment subscription
az login

# Create the resource group
az group create -g $RESOURCE_GROUP -l $LOCATION

# Create the Vnet along with the initial subet for AKS
az network vnet create \
-g $RESOURCE_GROUP \
-n $VNET_NAME \
--address-prefix 10.140.0.0/16 \
--subnet-name aks \
--subnet-prefix 10.140.0.0/24

# Get a subnet resource ID
AKS_VNET_SUBNET_ID=$(az network vnet subnet show -g $RESOURCE_GROUP --vnet-name $VNET_NAME -n aks -o tsv --query id)

# Create a subnet for the private endpoint
az network vnet subnet create \
-g $RESOURCE_GROUP \
--vnet-name $VNET_NAME \
-n storage-pe-subnet \
--address-prefix 10.140.1.0/24

# Get the storage subnet ID
STORAGE_SUBNET_ID=$(az network vnet subnet show -g $RESOURCE_GROUP --vnet-name $VNET_NAME -n storage-pe-subnet -o tsv --query id)

# Create a storage account
az storage account create \
--name $STORAGE_ACCOUNT_NAME \
--resource-group $RESOURCE_GROUP \
--location $LOCATION \
--sku Standard_LRS

# Create a blob container
az storage container create \
--name anyscale-container \
--auth-mode login \
--account-name $STORAGE_ACCOUNT_NAME

# Create a file share
az storage share create \
--name anyscale-file-share \
--auth-mode login \
--account-name $STORAGE_ACCOUNT_NAME \
--quota 300

# Disable public network access now that the container is created
az storage account update \
-n $STORAGE_ACCOUNT_NAME \
-g $RESOURCE_GROUP \
--public-network-access Disabled

# Create a private DNS zone for blob storage
az network private-dns zone create \
-g $RESOURCE_GROUP \
-n privatelink.blob.core.windows.net

# Link the private DNS zone to the VNet
az network private-dns link vnet create \
-g $RESOURCE_GROUP \
--zone-name privatelink.blob.core.windows.net \
-n storage-dns-link \
--virtual-network $VNET_NAME \
--registration-enabled false

# Create the private endpoint for blob storage
az network private-endpoint create \
-g $RESOURCE_GROUP \
-n ${STORAGE_ACCOUNT_NAME}-pe \
--vnet-name $VNET_NAME \
--subnet storage-pe-subnet \
--private-connection-resource-id $(az storage account show -n $STORAGE_ACCOUNT_NAME -g $RESOURCE_GROUP -o tsv --query id) \
--group-id blob \
--connection-name ${STORAGE_ACCOUNT_NAME}-pe-connection

# Create the private DNS zone group to automatically configure DNS
az network private-endpoint dns-zone-group create \
-g $RESOURCE_GROUP \
--endpoint-name ${STORAGE_ACCOUNT_NAME}-pe \
-n storage-dns-zone-group \
--private-dns-zone privatelink.blob.core.windows.net \
--zone-name blob

# Create the managed identity
az identity create --name anyscale-mi --resource-group $RESOURCE_GROUP --location $LOCATION
# Get identity client ID
#export USER_ASSIGNED_CLIENT_ID=$(az identity show --resource-group $RESOURCE_GROUP --name anyscale-mi --query 'clientId' -o tsv)

# Get the storage account resource ID
STORAGE_ACCOUNT_ID=$(az storage account show \
--name $STORAGE_ACCOUNT_NAME \
--resource-group $RESOURCE_GROUP \
--query id \
--output tsv)

# Get the managed identity principal ID
ANYSCALE_MI_PRINCIPAL_ID=$(az identity show \
--name anyscale-mi \
--resource-group $RESOURCE_GROUP \
--query principalId \
--output tsv)

# Note: If you're moving very fast you may get a "Cannot find user" error.
# Wait a few seconds and run the command again.
# wait for 10 seconds
sleep 10

# Grant Storage Blob Data Contributor role to the managed identity
# the principal id of the managed identity will be later passed to anyscale-operator to access storage account
az role assignment create \
--role "Storage Blob Data Contributor" \
--assignee $ANYSCALE_MI_PRINCIPAL_ID \
--scope $STORAGE_ACCOUNT_ID

############!!!!!!!!!!!!!!!!!############
# Now, you need to check if the role assignment is successful or not.
# You need to make sure the role assignment is successful.
# You can do it on portal manually if necessary
############!!!!!!!!!!!!!!!!!############

#############################
# Create the AKS cluster and the Managed Identity
#############################
. anyscale-aks.sh

#############################
# Register the Anyscale cloud instance and deploy the Anyscale Operator
#############################
. anyscale-connect.sh
