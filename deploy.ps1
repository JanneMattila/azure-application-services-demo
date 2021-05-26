$arcName = "local-arc"
$customLocationName = "jannewest"
$resourceGroup = "rg-k8s-local"
$location = "westeurope"
$extensionInstanceName = "appSvcExtension"

# Login to Azure
az login

# List subscriptions
az account list -o table

# *Explicitly* select your working context
az account set --subscription AzureDev

# Show current context
az account show -o table

# Prepare extensions and providers
# - Install if not previously installed
az extension add --name connectedk8s
az extension add --name k8s-extension
az extension add --name customlocation
# - Update if previously installed
az extension update --name connectedk8s
az extension update --name k8s-extension
az extension update --name customlocation
az provider register --namespace Microsoft.Kubernetes
az provider register --namespace Microsoft.KubernetesConfiguration
az provider register --namespace Microsoft.ExtendedLocation

# Create new resource group
az group create --name $resourceGroup --location $location -o table

# Check that you're in correct Kubernetes context
kubectl config current-context
kubectl get nodes

# Connect local Kubernetes cluster to Arc
az connectedk8s connect --name $arcName --resource-group $resourceGroup

# Verify cluster connection
az connectedk8s list --resource-group $resourceGroup -o table

# View Azure Arc agents in cluster
kubectl get deployments,pods -n azure-arc

# Enable custom locations on cluster
az connectedk8s enable-features --name $arcName --resource-group $resourceGroup --features cluster-connect custom-locations

# Get Arc enabled Kubernetes cluster identifier
$connectedClusterId=(az connectedk8s show --name $arcName --resource-group $resourceGroup --query id -o tsv)
$connectedClusterId

# Enable Azure App Service on Azure Arc extension
$extensionId=(az k8s-extension create --name $extensionInstanceName --extension-type 'Microsoft.Web.Appservice' --cluster-type connectedClusters -c $arcName --resource-group $resourceGroup --scope cluster --release-namespace appservice-ns --configuration-settings "Microsoft.CustomLocation.ServiceAccount=default" --configuration-settings "appsNamespace=appservice-ns" --query id -o tsv)
$extensionId

# Verify install state
az k8s-extension show --name $extensionInstanceName --cluster-type connectedClusters -c $arcName --resource-group $resourceGroup --query installState -o tsv

# Create custom location
az customlocation create -n $customLocationName --resource-group $resourceGroup --namespace arc --host-resource-id $connectedClusterId --cluster-extension-ids $extensionId

# Wipe out the resources
az group delete --name $resourceGroup -y
