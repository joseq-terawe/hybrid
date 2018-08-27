[CmdletBinding()]
Param(
      [Parameter(Mandatory=$true)][System.String]$rg,
      [Parameter(Mandatory=$true)][System.String]$presharedkey,
      [Parameter(Mandatory=$true)][System.String]$storageAccountName,
      [Parameter(Mandatory=$true)][System.String]$storageAccountContainerName,
      [Parameter(Mandatory=$true)][System.String]$certFolderName,
      [Parameter(Mandatory=$true)][System.String]$aliasURL)

#region Sets Current Directory
$WorkingDir = Convert-Path .
#endregion

#region Creates cert
md -Name $certFolderName -Path $HOME\Desktop

$label = "AzureStackSelfSignedRootCert"
Write-Host "Getting certificate from the current user trusted store with subject CN=$label"

$root = Get-ChildItem Cert:\CurrentUser\Root | Where-Object Subject -eq "CN=$label" | select -First 1
if (-not $root)
{
    Log-Error "Certificate with subject CN=$label not found"
    return
}

Write-Host "Exporting certificate"
Export-Certificate -Type CERT -FilePath "$HOME\Desktop\$certFolderName\root.cer" -Cert $root

Write-Host "Converting certificate to PEM format"
cd $HOME\Desktop\$certFolderName
certutil -encode root.cer root.pem
#endregion

#region Imports and binds Cert to SDK
$fileLocation = "$HOME\Desktop\$certFolderName"
$pemFile = "$fileLocation\root.pem"
$root = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
$root.Import($pemFile)

Write-Host "Extracting needed information from the cert file"
$md5Hash    = (Get-FileHash -Path $pemFile -Algorithm MD5).Hash.ToLower()
$sha1Hash   = (Get-FileHash -Path $pemFile -Algorithm SHA1).Hash.ToLower()
$sha256Hash = (Get-FileHash -Path $pemFile -Algorithm SHA256).Hash.ToLower()

$issuerEntry  = [string]::Format("# Issuer: {0}", $root.Issuer)
$subjectEntry = [string]::Format("# Subject: {0}", $root.Subject)
$labelEntry   = [string]::Format("# Label: {0}", $root.Subject.Split('=')[-1])
$serialEntry  = [string]::Format("# Serial: {0}", $root.GetSerialNumberString().ToLower())
$md5Entry     = [string]::Format("# MD5 Fingerprint: {0}", $md5Hash)
$sha1Entry    = [string]::Format("# SHA1 Finterprint: {0}", $sha1Hash)
$sha256Entry  = [string]::Format("# SHA256 Fingerprint: {0}", $sha256Hash)
$certText = (Get-Content -Path $pemFile -Raw).ToString().Replace("`r`n","`n")

$rootCertEntry = "`n" + $issuerEntry + "`n" + $subjectEntry + "`n" + $labelEntry + "`n" + `
$serialEntry + "`n" + $md5Entry + "`n" + $sha1Entry + "`n" + $sha256Entry + "`n" + $certText

Write-Host "Adding the certificate content to Python Cert store"
Add-Content "${env:ProgramFiles(x86)}\Microsoft SDKs\Azure\CLI2\Lib\site-packages\certifi\cacert.pem" $rootCertEntry

Write-Host "Python Cert store was updated for allowing the azure stack CA root certificate"
#endregion

#region Changes Back to Hybrid Azure Directory
cd $WorkingDir
#endregion

#region Adds user environment
az cloud register -n AzureStackUser --endpoint-resource-manager "https://management.local.azurestack.external" --suffix-storage-endpoint "local.azurestack.external" --suffix-keyvault-dns ".vault.local.azurestack.external" --endpoint-vm-image-alias-doc "$aliasURL"
#endregion

#region Sets user subscription
az cloud set -n AzureStackUser
#endregion

#region Loads latest profile
az cloud update --profile 2017-03-09-profile
#endregion

#region Logs into Azure Stack
$creds = Get-Credential -Message "Please Enter Your Azure Stack Credentials"
$creds.UserName
$tenant = $creds.UserName.Split('@')[1]
az login -u $creds.UserName --tenant $tenant -p $creds.Password
#endregion

#region Sets file location Variables for Json files
$azureStackTemplateLocation = (Get-Item .\Hybrid-AzureStack\azuredeploy.json).FullName
$azureStackParamLocation = (Get-Item .\Hybrid-AzureStack\azurestackdeploy.parameters.json).FullName
$azureTemplateLocation = (Get-Item .\Hybrid-Azure\azuredeploy.json).FullName
$azureParamLocation = (Get-Item .\Hybrid-Azure\azuredeploy.parameters.json).FullName
#endregion

#region Creates Resource Group, Storage Account, Container and Uploads Northwind files to Blob
$location = "local"

#creates Resource Group
az group create --name $rg --location $location

#creates Storage Account
az storage account create --name $storageAccountName --resource-group $rg --location $location --sku Standard_LRS

$keys = az storage account keys list --account-name $storageAccountName --resource-group $rg | ConvertFrom-Json

#creates Container
az storage container create --name $storageAccountContainerName --public-access container --account-name $storageAccountName --account-key $keys[0].value

#region Uploads files to storage container
$Folder = ".\northwind"
Foreach ($File in (dir $Folder -File))
{ 
az storage blob upload --container-name $storageAccountContainerName --file $file.fullName --name $file.Name --account-name $storageAccountName --account-key $keys[0].value
}
#endregion
#endregion

#region Sets variable for storage account url
$storageAccountInfo =  az storage account show -g $rg -n $storageAccountName | ConvertFrom-Json
$storageAccountURL = ($storageAccountInfo.primaryEndpoints.blob) + ("$storageAccountContainerName")
#endregion

#region Imports json files
$json = (Get-Content "$azureTemplateLocation" -Raw) | ConvertFrom-Json
$json2 = (Get-Content "$azureParamLocation" -Raw) | ConvertFrom-Json
$json3 = (Get-Content "$azureStackParamLocation" -Raw) | ConvertFrom-Json
#endregion

#region Updates base url parameter to new value of created container
$json3.parameters.baseUrl.value = $storageAccountURL
$json3 | ConvertTo-Json | Out-File .\Hybrid-AzureStack\azurestackdeploy.parameters.json
#endregion

#region Refreshing files as we made changes
$json = (Get-Content "$azureTemplateLocation" -Raw) | ConvertFrom-Json
$json2 = (Get-Content "$azureParamLocation" -Raw) | ConvertFrom-Json
$json3 = (Get-Content "$azureStackParamLocation" -Raw) | ConvertFrom-Json
#endregion

#region Change to deploy directory
cd .\Hybrid-AzureStack
#endregion

#region Deploys Template
az group deployment create -g $rg --name Azure-S2S-Deploy --template-file .\azuredeploy.json --parameters .\azurestackdeploy.parameters.json
#endregion

#region Gets Value of Internal IP Address of SQL VM
$nic = az network nic list | ConvertFrom-Json
$nicIP = $nic[0].ipConfigurations
#endregion

#region Change to root directory
cd ..
#endregion

#region Writes variables to file
New-Object -TypeName PSCustomObject -Property @{
sa = $json3.parameters.adminUsername.value 
saPWD = $json3.parameters.adminPassword.value
SQLIP = $nicIP[0].privateIpAddress
} | Export-Csv -Path test.csv -NoTypeInformation
#endregion

Write-Host "Deployment complete" -ForegroundColor Green
Write-Host "Do not forget to change values in you Local Network Gateway Before Continuing!!" -ForegroundColor Red
Read-Host

az network vpn-connection create --name Connection -g $rg --vnet-gateway1 Az-Virt-Gateway -l local --shared-key $presharedkey --local-gateway2 Az-to-AzS-LocalGateway