$aksName = "aks"
$arcName = "aks-arc"
$customLocationName = "jannewest"
$resourceGroup = "rg-k8s-appsvc-demo"
$location = "westeurope"
$namespace = "appservice-ns"
$extensionInstanceName = "appsvcextension"
$namespace = "appservice-ns"
$kubeAppServiceEnvironment = "kube-ase"

# Login to Azure
az login

# List subscriptions
az account list -o table

# *Explicitly* select your working context
az account set --subscription AzureDev

# Show current context
az account show -o table

# Prepare extensions and providers
az extension add --upgrade --yes --name connectedk8s
az extension add --upgrade --yes --name k8s-extension
az extension add --upgrade --yes --name customlocation
az provider register --namespace Microsoft.Kubernetes
az provider register --namespace Microsoft.KubernetesConfiguration
az provider register --namespace Microsoft.ExtendedLocation

az extension remove --name appservice-kube
az extension add --yes --source "https://aka.ms/appsvc/appservice_kube-latest-py2.py3-none-any.whl"

# Double check the registrations
az provider show -n Microsoft.Kubernetes -o table
az provider show -n Microsoft.KubernetesConfiguration -o table
az provider show -n Microsoft.ExtendedLocation -o table

# Create new resource group
az group create --name $resourceGroup --location $location -o table

# Due to preview limitation: 
# Must support LoadBalancer service type and provide a publicly addressable static IP
# https://docs.microsoft.com/en-us/azure/app-service/overview-arc-integration#public-preview-limitations
# Create AKS 
az aks create --resource-group $resourceGroup --name $aksName --enable-aad --node-count 1 --enable-cluster-autoscaler --min-count 1 --max-count 3 --node-vm-size Standard_B2ms --max-pods 150
$infraResourceGroup = (az aks show --resource-group $resourceGroup --name $aksName --query nodeResourceGroup --output tsv)
$staticIp = (az network public-ip create --resource-group $infraResourceGroup --name MyPublicIP --sku STANDARD --query publicIp.ipAddress --output tsv)
$staticIp
az aks get-credentials --resource-group $resourceGroup --name $aksName --admin --overwrite-existing

# Check that you're in correct Kubernetes context
kubectl config current-context
kubectl get nodes

# Connect local Kubernetes cluster to Arc
az connectedk8s connect --name $arcName --resource-group $resourceGroup

# Verify cluster connection
az connectedk8s list --resource-group $resourceGroup -o table

# View Azure Arc agents in cluster
kubectl get deployments, pods -n azure-arc

# Enable custom locations on cluster
az connectedk8s enable-features --name $arcName --resource-group $resourceGroup --features cluster-connect custom-locations

# Get Arc enabled Kubernetes cluster identifier
$connectedClusterId = (az connectedk8s show --name $arcName --resource-group $resourceGroup --query id -o tsv)
$connectedClusterId

# Enable Azure App Service on Azure Arc extension
$extensionId = az k8s-extension create -g $resourceGroup --name $extensionInstanceName --query id -o tsv `
    --cluster-type connectedClusters -c $arcName `
    --extension-type 'Microsoft.Web.Appservice' --release-train stable --auto-upgrade-minor-version true `
    --scope cluster --release-namespace $namespace `
    --configuration-settings "Microsoft.CustomLocation.ServiceAccount=default" `
    --configuration-settings "appsNamespace=$namespace" `
    --configuration-settings "clusterName=$kubeAppServiceEnvironment" `
    --configuration-settings "loadBalancerIp=$staticIp" `
    --configuration-settings "keda.enabled=true" `
    --configuration-settings "buildService.storageClassName=default" `
    --configuration-settings "buildService.storageAccessMode=ReadWriteOnce" `
    --configuration-settings "customConfigMap=$namespace/kube-environment-config" `
    --configuration-settings "envoy.annotations.service.beta.kubernetes.io/azure-load-balancer-resource-group=$resourceGroup" # `
# --configuration-settings "logProcessor.appLogs.destination=log-analytics" `
# --configuration-protected-settings "logProcessor.appLogs.logAnalyticsConfig.customerId=$logAnalyticsWorkspaceIdEnc" `
# --configuration-protected-settings "logProcessor.appLogs.logAnalyticsConfig.sharedKey=$logAnalyticsKeyEnc"

# Verify install state
# az k8s-extension show --name $extensionInstanceName --cluster-type connectedClusters -c $arcName --resource-group $resourceGroup --query installState -o tsv
# az k8s-extension show --name $extensionInstanceName --cluster-type connectedClusters -c $arcName --resource-group $resourceGroup
az resource wait --ids $extensionId --custom "properties.installState!='Pending'" --api-version "2020-07-01-preview"

# List different resources from cluster
kubectl get all -n $namespace
kubectl get pods -n $namespace -l !app
kubectl get svc -A

# Create custom location
az customlocation create -n $customLocationName --resource-group $resourceGroup --namespace $namespace --host-resource-id $connectedClusterId --cluster-extension-ids $extensionId
$customLocationId = (az customlocation show -n $customLocationName --resource-group $resourceGroup --query id -o tsv)
$customLocationId

# Create App Service Environment
az appservice kube create `
    --resource-group $resourceGroup `
    --name $kubeAppServiceEnvironment `
    --custom-location $customLocationId `
    --static-ip $staticIp

# Validate App Service Environment
az appservice kube show `
    --resource-group $resourceGroup `
    --name $kubeAppServiceEnvironment

####################
# Create App Service
####################
$image = "jannemattila/echo"
$appServiceName = "echofromkube"
$appServicePlanName = "asp"

az appservice plan create --name $appServicePlanName --resource-group $resourceGroup --custom-location $customLocationId --is-linux --per-site-scaling --sku K1
$webAppUri = (az webapp create --name $appServiceName --plan $appServicePlanName --custom-location $customLocationId --resource-group $resourceGroup -i $image --query defaultHostName -o TSV)
$webAppUri

$url = "http://$webAppUri/api/echo"
$data = @{
    firstName = "John"
    lastName  = "Doe"
}
$body = ConvertTo-Json $data
Invoke-RestMethod -Body $body -ContentType "application/json" -Method "POST" -DisableKeepAlive -Uri $url

###################
# Create Logic App
###################
az extension remove --name logicapp
az extension add --yes --source "https://aka.ms/logicapp-latest-py2.py3-none-any.whl"
az logicapp create --resource-group $resourceGroup --name wffromkube --custom-location $customLocationId --storage-account yourstorage

# Use VS Code for deploying the app

# Update url
$logicAppUrl = "https://wffromkube.kube-ase-abcdefg.westeurope.k4apps.io:443/api/TemperatureConverter/triggers/manual/invoke"
$logicAppData = @{
    temperature  = 33
}
$logicAppBody = ConvertTo-Json $logicAppData
Invoke-RestMethod -Body $logicAppBody -ContentType "application/json" -Method "POST" -DisableKeepAlive -Uri $logicAppUrl

# Wipe out the resources
az group delete --name $resourceGroup -y
