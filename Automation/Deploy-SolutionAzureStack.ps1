[CmdletBinding()]
Param(
      [Parameter(Mandatory=$true)][System.String]$rg,
      [Parameter(Mandatory=$true)][System.String]$presharedkey,
      [Parameter(Mandatory=$true)][System.String]$storageAccountName,
      [Parameter(Mandatory=$true)][System.String]$targetStorageContainer)

#region Adds Environment and Logs into Tenant Subscription
Add-AzureRMEnvironment -Name AzureStackAdmin -ArmEndpoint "https://management.local.azurestack.external"
Login-AzureRmAccount -EnvironmentName "AzureStackAdmin"
#endregion

#region Sets file location Variables for Json files
$azureStackTemplateLocation = (Get-Item .\Hybrid-AzureStack\azuredeploy.json).FullName
$azureStackParamLocation = (Get-Item .\Hybrid-AzureStack\azurestackdeploy.parameters.json).FullName
$azureTemplateLocation = (Get-Item .\Hybrid-Azure\azuredeploy.json).FullName
$azureParamLocation = (Get-Item .\Hybrid-Azure\azuredeploy.parameters.json).FullName
#endregion

#region Creates Resource Group if exists it skips
$newAzureResourceGroup = Get-AzureRmResourceGroup | Where-Object ResourceGroupName -EQ $rg
if (!$newAzureResourceGroup) {
        
    #Write-Host "Creating resource group $RG in $location region" 
    New-AzureRmResourceGroup -Name $rg -Location local | Out-Null
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

#region Creates Storage Account if one exists skips to next step
$azureStorageAcc = Get-AzureRmStorageAccount | Where-Object StorageAccountName -EQ $storageAccountName.ToLower()
if ($azureStorageAcc) {
    Read-Host "Storage Account $storageAccountName Already exists moving to next step......Press Any Key to Continue" 
}
else
{
    while(!((Get-AzureRmStorageAccountNameAvailability -Name $storageAccountName).NameAvailable)) {
        Write-Warning -Message "'${storageAccountName}' is not available, please choose another name"
        $storageAccountName.ToLower() = Read-Host -Prompt "Enter a Storage Account Name"
    }
    Write-Host "Creating Storage Account '$storageAccountName'" 
    New-AzureRmStorageAccount -ResourceGroupName $rg -Name $storageAccountName -Location local -Type Standard_LRS | Out-Null
    while (!$azureStorageAcc) {
        $azureStorageAcc = Get-AzureRmStorageAccount | Where-Object StorageAccountName -EQ $storageAccountName
        Start-Sleep -Seconds 1
    }
} 
#endregion

#region Creates Storage Container if one exists skips to the next step
$targetStore = Get-AzureRmStorageAccount -ResourceGroupName $rg -Name $storageAccountName
$newAzureStorageContainer = Get-AzureStorageContainer -Context $targetStore.Context | Where-Object Name -EQ $targetStorageContainer.ToLower()
if (!$newAzureStorageContainer) {
    Write-Host "Creating Storage Container $targetStorageContainer"  
    New-AzureStorageContainer -Name $targetStorageContainer -Context $targetStore.Context -Permission Container | Out-Null

        $newAzureStorageContainer = $null

while (!$newAzureStorageContainer) {
    $newAzureStorageContainer = Get-AzureStorageContainer -Name $targetStorageContainer -Context $targetStore.Context
    Start-Sleep -Seconds 1
    }    
}

else {
Read-Host "Storage Container $targetStorageContainer Already exists moving to next step......Press Any Key to Continue"  
}
#endregion

#region Uploads files to storage container
$Folder = ".\northwind"
Foreach ($File in (dir $Folder -File))
{ 
Set-AzureStorageBlobContent -Container $newAzureStorageContainer.Name -File $file.FullName -Blob $file.Name -Context $newAzureStorageContainer.Context
}
#endregion

#region Imports json files
$json = (Get-Content "$azureTemplateLocation" -Raw) | ConvertFrom-Json
$json2 = (Get-Content "$azureParamLocation" -Raw) | ConvertFrom-Json
$json3 = (Get-Content "$azureStackParamLocation" -Raw) | ConvertFrom-Json
#endregion

#region updates base url parameter to new value of created container
$json3.parameters.baseUrl.value = $newAzureStorageContainer.CloudBlobContainer.Uri.AbsoluteUri 
$json3 | ConvertTo-Json | Out-File .\Hybrid-AzureStack\azurestackdeploy.parameters.json
#endregion

#region refreshing files as we made changes
$json = (Get-Content "$azureTemplateLocation" -Raw) | ConvertFrom-Json
$json2 = (Get-Content "$azureParamLocation" -Raw) | ConvertFrom-Json
$json3 = (Get-Content "$azureStackParamLocation" -Raw) | ConvertFrom-Json
#endregion

#region Deploys template to Azure
$Deploysettings = @{
    Name = 'AzureStack-S2S-Deploy'
    ResourceGroupName= $rg 
    TemplateFile = $azureStackTemplateLocation
    TemplateParameterFile = $azureStackParamLocation
    Verbose = $true
}
New-AzureRmResourceGroupDeployment @Deploysettings
#endregion

#region Gets Values for CSV file
$vm = Get-AzureRmVM -ResourceGroupName $rg -Name $json3.parameters.vmName1.value
$nic = Get-AzureRmNetworkInterface -ResourceGroupName $rg -Name $(Split-Path -Leaf $vm.NetworkProfile.NetworkInterfaces[0].Id)
$sqlIPAdress = $nic.IpConfigurations | Select-Object PrivateIpAddress
$localIP = Get-AzureRmVirtualNetwork -ResourceGroupName $rg
#endregion

#region Writes variables to file
New-Object -TypeName PSCustomObject -Property @{
sa = $json3.parameters.adminUsername.value 
saPWD = $json3.parameters.adminPassword.value
SQLIP = $sqlIPAdress.PrivateIpAddress
} | Export-Csv -Path test.csv -NoTypeInformation

Write-Host "Deployment complete" -ForegroundColor Green
Write-Host "Make sure Local Network GatewayIP on both Azure and Azure Stack are configured once done press any key to continue" -ForegroundColor Yellow
Read-Host
#endregion

#region Post deployment - Connect VPN AzureStack to Azure:
$gw = Get-AzureRmVirtualNetworkGateway -Name Az-Virt-Gateway -ResourceGroupName $rg
$ls = Get-AzureRmLocalNetworkGateway -Name Az-to-AzS-LocalGateway -ResourceGroupName $rg
New-AzureRMVirtualNetworkGatewayConnection -Name AzureStack-Azure -ResourceGroupName $rg -Location local -VirtualNetworkGateway1 $gw -LocalNetworkGateway2 $ls -ConnectionType IPsec -RoutingWeight 10 -SharedKey $presharedkey
#endregion