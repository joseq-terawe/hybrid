[CmdletBinding()]
Param(
      [Parameter(Mandatory=$true)][System.String]$rg,
      [Parameter(Mandatory=$true)][System.String]$location,
      [Parameter(Mandatory=$true)][System.String]$presharedkey)

#region Logs into Azure Stack
az login
#endregion

#region Sets file location Variables for Json files
$azureStackTemplateLocation = (Get-Item .\Hybrid-AzureStack\azuredeploy.json).FullName
$azureStackParamLocation = (Get-Item .\Hybrid-AzureStack\azurestackdeploy.parameters.json).FullName
$azureTemplateLocation = (Get-Item .\Hybrid-Azure\azuredeploy.json).FullName
$azureParamLocation = (Get-Item .\Hybrid-Azure\azuredeploy.parameters.json).FullName
#endregion

#region creates Resource Group
az group create --name $rg --location $location
#endregion

#region Imports json files
$json = (Get-Content "$azureTemplateLocation" -Raw) | ConvertFrom-Json
$json2 = (Get-Content "$azureParamLocation" -Raw) | ConvertFrom-Json
$json3 = (Get-Content "$azureStackParamLocation" -Raw) | ConvertFrom-Json
#endregion

#region Change to deploy directory
cd .\Hybrid-Azure
#endregion

#region deploys Template
az group deployment create -g $rg --name Azure-S2S-Deploy --template-file .\azuredeploy.json --parameters .\azuredeploy.parameters.json
#endregion

#region Change to root directory
cd ..
#endregion

#region Gives Values for Local Network Gateway
$pip = az network public-ip list | ConvertFrom-Json
Write-Host "Deployment complete, Do not forget to change values in you Local Network Gateway" -ForegroundColor Green
Write-Host "Press Any Key To Continue"
Read-Host 
cls
Write-Host
Write-Host "In the Azure Stack Portal for your Local Network GatewayIP Address enter this IP: $($pip[0].ipAddress) " -ForegroundColor Green
Write-Host "Please Enter the Correct IP's for your Local Network Gateway from Portal once done press any key to continue" -ForegroundColor Yellow
Read-Host
#endregion

#region Sets Variables for Webapp URI Connection String
$webApp = az webapp list | ConvertFrom-Json
#endregion

#region Adds Database Connection string to WebApp Appsettings in Azure Portal
$SQLServerName = $json3.parameters.vmName1.value
$config = Import-Csv -Path test.csv
$sa = $config.sa
$saPWD = $config.saPWD
$SQLIP = $config.SQLIP

$webbApp = az webapp list | ConvertFrom-Json
az webapp config connection-string set -g $rg -n $webbApp[0].Name -t SQLServer --settings SQLServer="Data Source=${SQLIP},1433;Initial Catalog=NorthwindDb;User ID=$sa;Password=$saPWD;Asynchronous Processing=True"
#endregion

#region Updates Appsettings file with new connection string value
$connectString = az webapp config connection-string list -g $rg -n $webbApp[0].Name | ConvertFrom-Json
$appCheck = az resource list --namespace microsoft.insights --resource-type components | ConvertFrom-Json
$appKeyResult = az resource show --ids $appCheck[0].id --query properties.InstrumentationKey
$appsetingsFile = (Get-Item .\appsettings.json).FullName
$ConnectObject = (Get-Content "$appsetingsFile" -Raw) | ConvertFrom-Json
$appkey = $appKeyResult -replace '"', ""
$ConnectObject.ConnectionStrings.DefaultConnection = $connectString[0].value.value
$ConnectObject.ApplicationInsights.InstrumentationKey = $appkey
$ConnectObject | ConvertTo-Json | Out-File .\appsettings.json
#endregion

#region Creates Connection
az network vpn-connection create --name Connection -g $rg --vnet-gateway1 Gateway -l $location --shared-key $presharedkey --local-gateway2 LocalGateway
#endregion