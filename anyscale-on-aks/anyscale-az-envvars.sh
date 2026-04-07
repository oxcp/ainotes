#!/bin/bash

# Name of the resource group we will create
RESOURCE_GROUP=anyscale-rg
# Azure Region where we will deploy
LOCATION=westus
# Name of the Virtual Network we'll create
VNET_NAME=anyscale-vnet
# Name of the AKS cluster to be created
CLUSTER_NAME=anyscale-aks
# Name of the Azure Storage Account. Must be globally unique
#STORAGE_ACCOUNT_NAME=anyscale$RANDOM
STORAGE_ACCOUNT_NAME=anyscale28120
# Name of the blob storage container we'll create in the storage account
STORAGE_CONTAINER_NAME=anyscale-container
# Namespace where the Anyscale Operator will be deployed
ANYSCALE_NAMESPACE=anyscale-operator
# Name of the cloud instance we'll use in the Anyscale Portal
# You should make this unique
ANYSCALE_CLOUD_INSTANCE_NAME=anyscale-on-azure
#ANYSCALE_CLOUD_INSTANCE_NAME=anyscale_default_cloud
ANYSCALE_CLI_TOKEN=aph0_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx