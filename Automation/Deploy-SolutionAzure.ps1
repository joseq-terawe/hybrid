[CmdletBinding()]
Param(
      [Parameter(Mandatory=$true)][System.String]$rg,
      [Parameter(Mandatory=$true)][System.String]$location,
      [Parameter(Mandatory=$true)][System.String]$presharedkey)

#region Use Credentials for Azure public cloud
Login-AzureRmAccount
#endregion

#region Creates Resource Group if exists it skips
$newAzureResourceGroup = Get-AzureRmResourceGroup | Where-Object ResourceGroupName -EQ $rg
if (!$newAzureResourceGroup) {
        
    #Write-Host "Creating resource group $RG in $location region" 
    New-AzureRmResourceGroup -Name $rg -Location $location | Out-Null
    $newAzureResourceGroup = $null
    while (!$newAzureResourceGroup) {
        $newAzureResourceGroup = Get-AzureRmResourceGroup -Name $rg
        Start-Sleep -Seconds 1
    }
}

else {
Write-Host "Resource Group $rg Already exists moving to next step......"  
}
#endregion

#region Sets file location Variables for Json files
$azureStackTemplateLocation = (Get-Item .\Hybrid-AzureStack\azuredeploy.json).FullName
$azureStackParamLocation = (Get-Item .\Hybrid-AzureStack\azurestackdeploy.parameters.json).FullName
$azureTemplateLocation = (Get-Item .\Hybrid-Azure\azuredeploy.json).FullName
$azureParamLocation = (Get-Item .\Hybrid-Azure\azuredeploy.parameters.json).FullName
#endregion

#region Deploys template to Azure
$Deploysettings = @{
    Name = 'Azure-S2S-Deploy'
    ResourceGroupName= $rg 
    TemplateFile = $azureTemplateLocation
    TemplateParameterFile = $azureParamLocation
    Verbose = $true
}
New-AzureRmResourceGroupDeployment @Deploysettings
#endregion

#region Gets values from Json Files 
$json = (Get-Content "$azureParamLocation" -Raw) | ConvertFrom-Json
$json2 = (Get-Content "$azureTemplateLocation" -Raw) | ConvertFrom-Json
$json3 = (Get-Content "$azureStackParamLocation" -Raw) | ConvertFrom-Json
#endregion

#region Gives Values for Local Network Gateway
$GatewayIP = Get-AzureRmPublicIpAddress -Name $json2.variables.GatewayNamePublicIP -ResourceGroupName $rg
$localIP = Get-AzureRmVirtualNetwork -ResourceGroupName $rg

Write-Host
Write-Host "In the Azure Stack Portal for your Local Network GatewayIP Address enter this IP: $($GatewayIP.IpAddress) " -ForegroundColor Green
Write-Host "Please Enter the Correct IP's for your Local Network Gateway from Portal once done press any key to continue" -ForegroundColor Yellow
Read-Host
#endregion

#region Sets Variables for Webapp URI Connection String
$webApp = Get-AzureRmWebApp -Name $json.parameters.siteName.value -ResourceGroupName $rg
#endregion

#region Adds Database Connection string to WebApp Appsettings in Azure Portal
$SQLServerName = $json3.parameters.vmName1.value
$config = Import-Csv -Path test.csv
$sa = $config.sa
$saPWD = $config.saPWD
$SQLIP = $config.SQLIP
$webapp.SiteConfig.ConnectionStrings.Add((New-Object Microsoft.Azure.Management.WebSites.Models.ConnStringInfo -ArgumentList SQLServer, ${SQLServerName}, “Data Source=${SQLIP},1433;Initial Catalog=NorthwindDb;User ID=$sa;Password=$saPWD;Asynchronous Processing=True”))
$webApp | Set-AzureRmWebApp
#endregion

#region Creates Credential and connects to Azure Web App
$creds = Invoke-AzureRmResourceAction -ResourceGroupName $rg -ResourceType Microsoft.Web/sites/config -ResourceName "$($webApp.Name)/publishingcredentials" -Action list -ApiVersion 2015-08-01 -Force
$username = $creds.Properties.PublishingUserName
$password = $creds.Properties.PublishingPassword
# Note that the $username here should look like `SomeUserName`, and **not** `SomeSite\SomeUserName`
$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $username, $password)))
$userAgent = "powershell/1.0"
#endregion

#region uses Webbapp URL and adds .scm to build string for use when creating the apiUrl  
$split = $webApp.DefaultHostName
[regex]$pattern = '\.'
$NewAppUri = "https://$($pattern.replace($split, '.scm.', 1))"
#endregion

#region Deletes old appsettings.json file
$Headers = @{
    'Authorization' = ('Basic {0}' -f $base64AuthInfo)
    'If-Match'      = '*'
}
$filePath = "$NewAppUri/api/vfs/site/wwwroot/appsettings.json"
Invoke-RestMethod -Uri $filePath -Headers $Headers -UserAgent $userAgent -Method Delete 
#endregion

#region Updates Appsettings file with new connection string value
$appsetingsFile = (Get-Item .\appsettings.json).FullName
$ConnectObject = (Get-Content "$appsetingsFile" -Raw) | ConvertFrom-Json
$appkey = Get-AzureRmApplicationInsights -ResourceGroupName $rg
$ConnectObject.ConnectionStrings.DefaultConnection = $webApp.SiteConfig.ConnectionStrings.ConnectionString
$ConnectObject.ApplicationInsights.InstrumentationKey = $appkey.InstrumentationKey
$ConnectObject | ConvertTo-Json | Out-File .\appsettings.json
#endregion

#region Uploads new appsettings.json file
$apiUrl = "$NewAppUri/api/vfs/site/wwwroot/appsettings.json"
$filePath = ".\appsettings.json"
Invoke-RestMethod -Uri $apiUrl -Headers @{Authorization=("Basic {0}" -f $base64AuthInfo)} -UserAgent $userAgent -Method PUT -InFile $filePath -ContentType "multipart/form-data"
#endregion

#region Post deployment - Connect VPN Azure to Azure Stack:
$gw = Get-AzureRmVirtualNetworkGateway -Name Gateway -ResourceGroupName $rg
$ls = Get-AzureRmLocalNetworkGateway -Name LocalGateway -ResourceGroupName $rg
New-AzureRMVirtualNetworkGatewayConnection -Name Azure-AzureStack -ResourceGroupName $rg -Location $location -VirtualNetworkGateway1 $gw -LocalNetworkGateway2 $ls -ConnectionType IPsec -RoutingWeight 10 -SharedKey $presharedkey
#endregion