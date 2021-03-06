<#
.SYNOPSIS
Adds the required application registrations and user profiles to an AAD tenant
.DESCRIPTION
#>
param
(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [ValidateLength(5,12)]
    [ValidateScript({
        if ("$_" -cmatch "(^([a-z]|\d)+$)") {
            return $true
        }
        else {
			throw "Environment name must be lowercase and numbers"
            return $false
        }
    })]
    [string]$EnvironmentName,

    [Parameter(Mandatory = $false)]
    [string]$ReplyUrl = "healthkitonfhir://callback",

    [Parameter(Mandatory = $false)]
    [ValidateSet('Australia East','East US','East US 2','West US 2','North Central US','South Central US','Southeast Asia','North Europe','West Europe','UK West','UK South')]
    [string]$EnvironmentLocation = "North Central US",

    [Parameter(Mandatory = $false )]
    [String]$WebAppSuffix = "azurewebsites.net",

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = $EnvironmentName,

    [parameter(Mandatory = $false)]
    [string]$KeyVaultName = "$EnvironmentName-ts",

    [parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [SecureString]$AdminPassword
)

Set-StrictMode -Version Latest

# Get current AzureAd context
try {
    $tenantInfo = Get-AzureADCurrentSessionInfo -ErrorAction Stop
} 
catch {
    throw "Please log in to Azure AD with Connect-AzureAD cmdlet before proceeding"
}

# Get current Az context
try {
    $azContext = Get-AzContext
} 
catch {
    throw "Please log in to Azure RM with Login-AzAccount cmdlet before proceeding"
}

# Ensure that we have the FhirServer PS Module loaded
if (Get-Module -Name FhirServer) {
    Write-Host "FhirServer PS module is loaded"
} else {
    Write-Host "Cloning FHIR Server repo to get access to FhirServer PS module."
    if (!(Test-Path -Path ".\fhir-server")) {
        git clone --quiet https://github.com/Microsoft/fhir-server | Out-Null
    }
    Import-Module .\fhir-server\samples\scripts\PowerShell\FhirServer\FhirServer.psd1
}

$keyVault = Get-AzKeyVault -VaultName $KeyVaultName

if (!$keyVault) {
    Write-Host "Creating keyvault with the name $KeyVaultName"
    $resourceGroup = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    if (!$resourceGroup) {
        New-AzResourceGroup -Name $ResourceGroupName -Location $EnvironmentLocation | Out-Null
    }
    New-AzKeyVault -VaultName $KeyVaultName -ResourceGroupName $ResourceGroupName -Location $EnvironmentLocation | Out-Null
}

if ($azContext.Account.Type -eq "User") {
    Write-Host "Current context is user: $($azContext.Account.Id)"

    $currentUser = Get-AzADUser -UserPrincipalName $azContext.Account.Id

    #If this is guest account, we will try a search instead
    if (!$currentUser) {
        # External user accounts have UserPrincipalNames of the form:
        # myuser_outlook.com#EXT#@mytenant.onmicrosoft.com for a user with username myuser@outlook.com
        $tmpUserName = $azContext.Account.Id.Replace("@", "_")
        $currentUser = Get-AzureADUser -Filter "startswith(UserPrincipalName, '${tmpUserName}')"
        $currentObjectId = $currentUser.ObjectId
    } else {
        $currentObjectId = $currentUser.Id
    }

    if (!$currentObjectId) {
        throw "Failed to find objectId for signed in user"
    }
}
elseif ($azContext.Account.Type -eq "ServicePrincipal") {
    Write-Host "Current context is service principal: $($azContext.Account.Id)"
    $currentObjectId = (Get-AzADServicePrincipal -ServicePrincipalName $azContext.Account.Id).Id
}
else {
    Write-Host "Current context is account of type '$($azContext.Account.Type)' with id of '$($azContext.Account.Id)"
    throw "Running as an unsupported account type. Please use either a 'User' or 'Service Principal' to run this command"
}

if ($currentObjectId) {
    Write-Host "Adding permission to keyvault for $currentObjectId"
    Set-AzKeyVaultAccessPolicy -VaultName $KeyVaultName -ObjectId $currentObjectId -PermissionsToSecrets Get, Set, List
}

Write-Host "Ensuring API application exists"

$fhirServiceUrl = "https://${EnvironmentName}.azurehealthcareapis.com"

$application = Get-AzureAdApplication -Filter "identifierUris/any(uri:uri eq '$fhirServiceUrl')"

if (!$application) {
    New-FhirServerApiApplicationRegistration -FhirServiceAudience $fhirServiceUrl -AppRoles "admin"
    
    # Change to use applicationId returned
    $application = Get-AzureAdApplication -Filter "identifierUris/any(uri:uri eq '$fhirServiceUrl')"
}

$UserNamePrefix = "${EnvironmentName}-"
$userId = "${UserNamePrefix}admin"
$domain = $tenantInfo.TenantDomain
$userUpn = "${userId}@${domain}"

# See if the user exists
Write-Host "Checking if UserPrincipalName exists"
$aadUser = Get-AzureADUser -Filter "userPrincipalName eq '$userUpn'"
if ($aadUser)
{
    Write-Host "AAD user found, will update."
}
else 
{
    Write-Host "Creating AAD user."
}

$passwordSecureString = $AdminPassword
$password = (New-Object PSCredential "user",$passwordSecureString).GetNetworkCredential().Password

if ($aadUser) {
    Set-AzureADUserPassword -ObjectId $aadUser.ObjectId -Password $passwordSecureString -EnforceChangePasswordPolicy $false -ForceChangePasswordNextLogin $false
}
else {
    $PasswordProfile = New-Object -TypeName Microsoft.Open.AzureAD.Model.PasswordProfile
    $PasswordProfile.Password = $password
    $PasswordProfile.EnforceChangePasswordPolicy = $false
    $PasswordProfile.ForceChangePasswordNextLogin = $false

    $aadUser = New-AzureADUser -DisplayName $userId -PasswordProfile $PasswordProfile -UserPrincipalName $userUpn -AccountEnabled $true -MailNickName $userId
}

$upnSecureString = ConvertTo-SecureString $userUpn -AsPlainText -Force
Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name "$userId-upn" -SecretValue $upnSecureString | Out-Null   
Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name "$userId-password" -SecretValue $passwordSecureString | Out-Null   
Set-FhirServerUserAppRoleAssignments -ApiAppId $application.AppId -UserPrincipalName $userUpn -AppRoles "admin"

# Create service client
$serviceClientAppName = "${EnvironmentName}-service-client"
$serviceClient = Get-AzureAdApplication -Filter "DisplayName eq '$serviceClientAppName'"
if (!$serviceClient) {
    $serviceClient = New-FhirServerClientApplicationRegistration -ApiAppId $application.AppId -DisplayName $serviceClientAppName
    $secretSecureString = ConvertTo-SecureString $serviceClient.AppSecret -AsPlainText -Force
} else {
    Get-AzureADApplicationPasswordCredential -ObjectId $serviceClient.ObjectId | Remove-AzureADApplicationPasswordCredential -ObjectId $serviceClient.ObjectId
    $newPassword = New-AzureADApplicationPasswordCredential -ObjectId $serviceClient.ObjectId
    $secretSecureString = ConvertTo-SecureString $newPassword.Value -AsPlainText -Force
}

Set-FhirServerClientAppRoleAssignments -AppId $serviceClient.AppId -ApiAppId $application.AppId -AppRoles admin

$secretServiceClientId = ConvertTo-SecureString $serviceClient.AppId -AsPlainText -Force
Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name "$serviceClientAppName-id" -SecretValue $secretServiceClientId| Out-Null
Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name "$serviceClientAppName-secret" -SecretValue $secretSecureString | Out-Null

# Create public (SMART on FHIR) client
$publicClientAppName = "${EnvironmentName}-public-client"
$publicClient = Get-AzureAdApplication -Filter "DisplayName eq '$publicClientAppName'"
if (!$publicClient) {
    $publicClient = New-FhirServerClientApplicationRegistration -ApiAppId $application.AppId -DisplayName $publicClientAppName -PublicClient:$true
    $secretPublicClientId = ConvertTo-SecureString $publicClient.AppId -AsPlainText -Force
    Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name "$publicClientAppName-id" -SecretValue $secretPublicClientId| Out-Null
} 

Set-FhirServerClientAppRoleAssignments -AppId $publicClient.AppId -ApiAppId $application.AppId -AppRoles admin
New-FhirServerSmartClientReplyUrl -AppId $publicClient.AppId -FhirServerUrl $fhirServiceUrl -ReplyUrl $ReplyUrl
New-FhirServerSmartClientReplyUrl -AppId $publicClient.AppId -FhirServerUrl $fhirServiceUrl -ReplyUrl "${ReplyUrl}/"
