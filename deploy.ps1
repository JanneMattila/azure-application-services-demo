# Change at least this!
$yourName = "janne"

# Other variables
$aksName = "aks"
$arcName = "aks-arc"
$customLocationName = "$($yourName)west"
$resourceGroup = "rg-k8s-appsvc-demo"
$workspaceName = "aks-workspace"
$location = "westeurope"
$appServiceNamespace = "appservice-ns"
$appServiceExtensionName = "appsvcextension"
$kubeAppServiceEnvironment = "kube-ase-$customLocationName"
$apimExtensionName = "apimextension"
$apimNamespace = "apim-ns"
$eventGridExtensionName = "eventgridextension"
$eventGridNamespace = "eventgrid-ns"

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

# Create Log Analytics workspace
$workspaceId = (az monitor log-analytics workspace create --resource-group $resourceGroup --workspace-name $workspaceName --query id -o tsv)
$workspaceKey = (az monitor log-analytics workspace get-shared-keys --resource-group $resourceGroup --workspace-name $workspaceName --query primarySharedKey -o tsv)
$workspaceId

# Prepare workspace related variables
$workspaceIdBase64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($workspaceId))
$workspaceKeyBase64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($workspaceKey))

# Due to preview limitation: 
# Must support LoadBalancer service type and provide a publicly addressable static IP
# https://docs.microsoft.com/en-us/azure/app-service/overview-arc-integration#public-preview-limitations
# Create AKS
# Note: If you don't have ssh keys present, add this to create one:
# --generate-ssh-keys
az aks create --resource-group $resourceGroup --name $aksName --enable-aad --enable-addons monitoring --workspace-resource-id $workspaceId --node-count 1 --enable-cluster-autoscaler --min-count 1 --max-count 3 --node-vm-size Standard_B2ms --max-pods 150
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
kubectl get deployments -n azure-arc
kubectl get pods -n azure-arc

# Enable custom locations on cluster
az connectedk8s enable-features --name $arcName --resource-group $resourceGroup --features cluster-connect custom-locations

# Get Arc enabled Kubernetes cluster identifier
$connectedClusterId = (az connectedk8s show --name $arcName --resource-group $resourceGroup --query id -o tsv)
$connectedClusterId

# Enable Azure App Service on Azure Arc extension
$appServiceExtensionId = az k8s-extension create -g $resourceGroup --name $appServiceExtensionName --query id -o tsv `
    --cluster-type connectedClusters --cluster-name $arcName `
    --extension-type 'Microsoft.Web.Appservice' --release-train stable --auto-upgrade-minor-version true `
    --scope cluster --release-namespace $appServiceNamespace `
    --configuration-settings "Microsoft.CustomLocation.ServiceAccount=default" `
    --configuration-settings "appsNamespace=$appServiceNamespace" `
    --configuration-settings "clusterName=$kubeAppServiceEnvironment" `
    --configuration-settings "loadBalancerIp=$staticIp" `
    --configuration-settings "keda.enabled=true" `
    --configuration-settings "buildService.storageClassName=default" `
    --configuration-settings "buildService.storageAccessMode=ReadWriteOnce" `
    --configuration-settings "customConfigMap=$appServiceNamespace/kube-environment-config" `
    --configuration-settings "envoy.annotations.service.beta.kubernetes.io/azure-load-balancer-resource-group=$resourceGroup" `
    --configuration-settings "logProcessor.appLogs.destination=log-analytics" `
    --configuration-protected-settings "logProcessor.appLogs.logAnalyticsConfig.customerId=$workspaceIdBase64" `
    --configuration-protected-settings "logProcessor.appLogs.logAnalyticsConfig.sharedKey=$workspaceKeyBase64"

# Verify install state
# az k8s-extension show --name $appServiceExtensionName --cluster-type connectedClusters -c $arcName --resource-group $resourceGroup --query installState -o tsv
# az k8s-extension show --name $appServiceExtensionName --cluster-type connectedClusters -c $arcName --resource-group $resourceGroup
az resource wait --ids $appServiceExtensionId --custom "properties.installState!='Pending'" --api-version "2020-07-01-preview"

# List different resources from cluster
kubectl get all -n $appServiceNamespace
kubectl get pods -n $appServiceNamespace -l !app
kubectl get svc -A

# Create custom location
az customlocation create -n $customLocationName --resource-group $resourceGroup --namespace $appServiceNamespace --host-resource-id $connectedClusterId --cluster-extension-ids $appServiceExtensionId
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

#############################
# Create App Service 1: Echo
#############################
$image = "jannemattila/echo"
$appServiceName = "echofromkube"
$appServicePlanName = "asp"

az appservice plan create --name $appServicePlanName --resource-group $resourceGroup --custom-location $customLocationId --is-linux --per-site-scaling --sku K1
$webAppUri = (az webapp create --name $appServiceName --plan $appServicePlanName --custom-location $customLocationId --resource-group $resourceGroup -i $image --query defaultHostName -o TSV)
$webAppUri
"https://$webAppUri/"

$url = "https://$webAppUri/api/echo"
$data = @{
    firstName = "John"
    lastName  = "Doe"
}
$body = ConvertTo-Json $data
Invoke-RestMethod -Body $body -ContentType "application/json" -Method "POST" -DisableKeepAlive -Uri $url

# Note: Check this url to see the forwarded headers
#       Check also the certificate provider!
"https://$webAppUri/pages/echo"

###############################################
# Create App Service 2: Web app network tester
###############################################
$image2 = "jannemattila/webapp-network-tester"
$appServiceName2 = "networktesterfromkube"
$appServicePlanName2 = "asp2"

az appservice plan create --name $appServicePlanName2 --resource-group $resourceGroup --custom-location $customLocationId --is-linux --per-site-scaling --sku K1
$webAppUri2 = (az webapp create --name $appServiceName2 --plan $appServicePlanName2 --custom-location $customLocationId --resource-group $resourceGroup -i $image2 --query defaultHostName -o TSV)
$webAppUri2
"https://$webAppUri2/"

$url2 = "https://$webAppUri2/api/commands"
$commands = @"
HTTP POST "http://<yourtargetaddress/" "CustomHeader=true"
"@

$body = ConvertTo-Json $data
Invoke-RestMethod -Body $commands -Method "POST" -DisableKeepAlive -Uri $url2

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
    temperature = 33
}
$logicAppBody = ConvertTo-Json $logicAppData
Invoke-RestMethod -Body $logicAppBody -ContentType "application/json" -Method "POST" -DisableKeepAlive -Uri $logicAppUrl

########################
# Create API Management
########################
$apimConfigurationUrl = "https://<yourapim>.management.azure-api.net/subscriptions/<yoursub>/resourceGroups/<yourapimrg>/providers/Microsoft.ApiManagement/service/<yourapim>?api-version=2019-12-01"
$apimAuthKey = "GatewayKey <name>&<token>"

$apimExtensionId = az k8s-extension create -g $resourceGroup --name $apimExtensionName --query id -o tsv `
    --cluster-type connectedClusters --cluster-name $arcName `
    --extension-type Microsoft.ApiManagement.Gateway --release-train preview `
    --scope namespace --target-namespace $apimNamespace `
    --configuration-settings "gateway.endpoint=$apimConfigurationUrl" `
    --configuration-protected-settings "gateway.authKey=$apimAuthKey"

# Verify install state
# az k8s-extension show --name $apimExtensionName --cluster-type connectedClusters -c $arcName --resource-group $resourceGroup --query installState -o tsv
# az k8s-extension show --name $apimExtensionName --cluster-type connectedClusters -c $arcName --resource-group $resourceGroup
az resource wait --ids $apimExtensionId --custom "properties.installState!='Pending'" --api-version "2020-07-01-preview"

####################
# Create Event Grid
####################
# Note: Using *unsecure* http setup!
$eventGridExtensionId = az k8s-extension create -g $resourceGroup --name $eventGridExtensionName --query id -o tsv `
    --cluster-type connectedClusters --cluster-name $arcName `
    --extension-type 'Microsoft.EventGrid' --release-train stable --auto-upgrade-minor-version true `
    --scope cluster --release-namespace $eventGridNamespace `
    --configuration-settings "Microsoft.CustomLocation.ServiceAccount=eventgrid-operator" `
    --configuration-settings "eventgridbroker.service.serviceType=ClusterIP" `
    --configuration-settings "eventgridbroker.service.supportedProtocols[0]=http" `
    --configuration-settings "eventgridbroker.dataStorage.size=1Gi" `
    --configuration-settings "eventgridbroker.dataStorage.storageClassName=azurefile" `
    --configuration-settings "eventgridbroker.diagnostics.metrics.reporterType=prometheus" `
    --configuration-settings "eventgridbroker.resources.limits.memory=1Gi" `
    --configuration-settings "eventgridbroker.resources.requests.memory=200Mi"

# Verify install state
# az k8s-extension show --name $eventGridExtensionId --cluster-type connectedClusters -c $arcName --resource-group $resourceGroup --query installState -o tsv
# az k8s-extension show --name $eventGridExtensionId --cluster-type connectedClusters -c $arcName --resource-group $resourceGroup -o json
az resource wait --ids $eventGridExtensionId --custom "properties.installState!='Pending'" --api-version "2020-07-01-preview"

# Validate Event Grid resources
kubectl get all -n $eventGridNamespace -o wide

# https://docs.microsoft.com/en-us/azure/event-grid/kubernetes/create-topic-subscription

# Wipe out the resources
az group delete --name $resourceGroup -y
