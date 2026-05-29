
<#
.SYNOPSIS
    One-shot setup for FabricCatalyst infrastructure.

.DESCRIPTION
    Handles everything Bicep cannot:
      1. Creates (or reuses) the Entra ID App Registration + Service Principal
      2. Ensures the deployer is an owner of the App Registration
      3. Declares Graph Application permissions  (User.Read.All, Group.Read.All)
      4. Grants tenant-wide admin consent for those permissions
      5. Creates (or reuses) the OwnerGroupName and AutomationGroupName security groups;
         sets deployer as member + owner of OwnerGroupName, owner of AutomationGroupName;
         adds the SPN as member of AutomationGroupName
      6. Deploys main.bicep  ->  subscription Reader for the SPN (always);
         resource group + Key Vault + KV role assignments (skipped if -SkipKeyVault)
      7. Creates a client secret; stores it in Key Vault, or prints it to the terminal
         if -SkipKeyVault (caller is responsible for secure storage in that case)

    The script is idempotent: re-running it with the same parameters is safe.
    Requires: Az PowerShell module  (Install-Module Az -Scope CurrentUser)
              Az.KeyVault is only required when -SkipKeyVault is not set.
              An active login with:
                - Application Administrator (or Global Admin) in Entra ID
                - Owner / User Access Administrator on the target subscription
                - Permission to grant admin consent (Cloud App Administrator or above)

    Login before running:
        Connect-AzAccount -TenantId <tenantId>

.PARAMETER TenantId
    Entra ID tenant ID.

.PARAMETER SubscriptionId
    Azure subscription ID where the Key Vault and role assignments will live.

.PARAMETER ResourceGroupName
    Name of the resource group to create. Required unless -SkipKeyVault is set.

.PARAMETER Location
    Azure region (default: norwayeast).

.PARAMETER KeyVaultName
    Globally-unique Key Vault name (3-24 chars, alphanumeric + hyphens).
    Required unless -SkipKeyVault is set.

.PARAMETER SkipKeyVault
    When set, skips resource group and Key Vault creation. The subscription Reader
    role is still assigned. The client secret is printed to the terminal instead of
    stored in a Key Vault — the caller is responsible for secure storage.

.PARAMETER SpnDisplayName
    Display name for the App Registration / Service Principal.

.PARAMETER OwnerGroupName
    Display name of the KV Administrator security group.

.PARAMETER AutomationGroupName
    Display name of the KV Secrets User security group (SPN member).

.PARAMETER TagOwner
    Value written to the Owner resource tag on all provisioned resources.

.PARAMETER TagManagedBy
    Value written to the ManagedBy resource tag on all provisioned resources.

.EXAMPLE
    .\setup-spn.ps1 `
        -TenantId            "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -SubscriptionId      "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ResourceGroupName   "dataproduct-d-rg" `
        -KeyVaultName        "dataproduct-shared-d-kv-ne" `
        -Location            "norwayeast" `
        -SpnDisplayName      "spn-dataproduct-automation" `
        -OwnerGroupName      "sg-dataproduct-owner" `
        -AutomationGroupName "sg-dataproduct-automation" `
        -TagOwner            "user@mycompany.com" `
        -TagManagedBy        "Business domain" 
#>
#Requires -Modules Az.Accounts, Az.Resources

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $TenantId,
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter()]          [string] $ResourceGroupName = '',
    [Parameter()]          [string] $KeyVaultName      = '',
    [Parameter(Mandatory)] [string] $Location,
    [Parameter(Mandatory)] [string] $SpnDisplayName,
    [Parameter(Mandatory)] [string] $OwnerGroupName,
    [Parameter(Mandatory)] [string] $AutomationGroupName,
    [Parameter(Mandatory)] [string] $TagOwner,
    [Parameter(Mandatory)] [string] $TagManagedBy,
    [switch]                        $SkipKeyVault
)

if (-not $SkipKeyVault) {
    if (-not $ResourceGroupName) { throw "'-ResourceGroupName' is required when '-SkipKeyVault' is not set." }
    if (-not $KeyVaultName)      { throw "'-KeyVaultName' is required when '-SkipKeyVault' is not set." }
    if (-not $Location)          { throw "'-Location' is required when '-SkipKeyVault' is not set." }
}

$script:BicepFile            = "$PSScriptRoot/main.bicep"
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#------------------------------------------------------------------
# Helpers
#------------------------------------------------------------------
function Write-Step ([string]$msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok   ([string]$msg) { Write-Host "    OK  $msg" -ForegroundColor Green }
function Write-Skip ([string]$msg) { Write-Host "    --  $msg (already exists, skipping)" -ForegroundColor DarkGray }

function Add-GroupMemberIfMissing ([string]$GroupId, [string]$MemberId, [string]$Label) {
    $members = Get-AzADGroupMember -GroupObjectId $GroupId
    if ($members | Where-Object { $_.Id -eq $MemberId }) {
        Write-Skip "$Label already a member"
    } else {
        Add-AzADGroupMember -TargetGroupObjectId $GroupId -MemberObjectId $MemberId
        Write-Ok "Added $Label as member"
    }
}

function Add-GroupOwnerIfMissing ([string]$GroupId, [string]$OwnerId, [string]$Label) {
    $resp   = Invoke-AzRestMethod -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId/owners"
    $owners = ($resp.Content | ConvertFrom-Json).value
    if ($owners | Where-Object { $_.id -eq $OwnerId }) {
        Write-Skip "$Label already an owner"
    } else {
        $body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$OwnerId" } | ConvertTo-Json -Compress
        $null = Invoke-AzRestMethod -Method POST `
            -Uri     "https://graph.microsoft.com/v1.0/groups/$GroupId/owners/`$ref" `
            -Payload $body
        Write-Ok "Added $Label as owner"
    }
}

function Add-AppOwnerIfMissing ([string]$AppObjectId, [string]$OwnerId, [string]$Label) {
    $resp   = Invoke-AzRestMethod -Method GET -Uri "https://graph.microsoft.com/v1.0/applications/$AppObjectId/owners"
    $owners = ($resp.Content | ConvertFrom-Json).value
    if ($owners | Where-Object { $_.id -eq $OwnerId }) {
        Write-Skip "$Label already an owner of the App Registration"
    } else {
        $body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$OwnerId" } | ConvertTo-Json -Compress
        $null = Invoke-AzRestMethod -Method POST `
            -Uri     "https://graph.microsoft.com/v1.0/applications/$AppObjectId/owners/`$ref" `
            -Payload $body
        Write-Ok "Added $Label as owner of the App Registration"
    }
}

#------------------------------------------------------------------
# 0. Ensure correct subscription context
#------------------------------------------------------------------
Write-Step "Setting active subscription to $SubscriptionId"
$null = Set-AzContext -SubscriptionId $SubscriptionId -TenantId $TenantId
Write-Ok "Subscription set"

# Capture the signed-in identity's object ID so we can add the deployer
# as member + owner of both security groups (steps 5/6).
Write-Step "Resolving deployer identity"
$context     = Get-AzContext
$accountId   = $context.Account.Id
$accountType = $context.Account.Type

switch ($accountType) {
    'User' {
        $deployerObjectId = (Get-AzADUser -UserPrincipalName $accountId).Id
    }
    'ManagedService' {
        # Cloud Shell automatic login — token is user-scoped; /me resolves the actual user object ID
        $meResp = Invoke-AzRestMethod -Method GET -Uri 'https://graph.microsoft.com/v1.0/me'
        $deployerObjectId = ($meResp.Content | ConvertFrom-Json).id
    }
    default {
        # Service principal login (e.g. running inside a pipeline)
        $deployerObjectId = (Get-AzADServicePrincipal -ApplicationId $accountId).Id
    }
}
if (-not $deployerObjectId) { throw "Could not resolve deployer object ID for account '$accountId'." }
Write-Ok "Deployer object ID: $deployerObjectId"

#------------------------------------------------------------------
# 1. App Registration (idempotent)
#------------------------------------------------------------------
Write-Step "Resolving App Registration '$SpnDisplayName'"
$existingApp = Get-AzADApplication -DisplayName $SpnDisplayName | Select-Object -First 1
if ($existingApp) {
    $appId       = $existingApp.AppId
    $appObjectId = $existingApp.Id
    Write-Skip "App Registration appId=$appId"
} else {
    $newApp      = New-AzADApplication -DisplayName $SpnDisplayName
    $appId       = $newApp.AppId
    $appObjectId = $newApp.Id
    Write-Ok "Created App Registration appId=$appId"
}

Write-Step "Ensuring deployer owns App Registration '$SpnDisplayName'"
Add-AppOwnerIfMissing -AppObjectId $appObjectId -OwnerId $deployerObjectId -Label 'deployer'

#------------------------------------------------------------------
# 2. Service Principal (idempotent)
#------------------------------------------------------------------
Write-Step "Resolving Service Principal"
$existingSp = Get-AzADServicePrincipal -ApplicationId $appId
if ($existingSp) {
    $spObjectId = $existingSp.Id
    Write-Skip "Service Principal objectId=$spObjectId"
} else {
    $newSp      = New-AzADServicePrincipal -ApplicationId $appId
    $spObjectId = $newSp.Id
    Write-Ok "Created Service Principal objectId=$spObjectId"
}

#------------------------------------------------------------------
# 3. Declare Graph Application permissions on the App Registration
#
#    Application permissions (not delegated) are the right choice here:
#    the SPN runs as a background daemon with no signed-in user.
#
#    Microsoft Graph  resource app ID: 00000003-0000-0000-c000-000000000000
#      User.Read.All  (AppRole): df021288-bdef-4463-88db-98f22de89214
#      Group.Read.All (AppRole): 5b567255-7703-4780-807c-7be8301ae99b
#------------------------------------------------------------------
Write-Step "Adding Graph Application permissions to the App Registration"

$graphAppId   = '00000003-0000-0000-c000-000000000000'
$userReadAll  = 'df021288-bdef-4463-88db-98f22de89214'
$groupReadAll = '5b567255-7703-4780-807c-7be8301ae99b'

# Read currently declared permissions to make the step idempotent
$existingPerms    = Get-AzADAppPermission -ObjectId $appObjectId
$existingPermIds  = $existingPerms |
    Where-Object { $_.ApiId -eq $graphAppId } |
    Select-Object -ExpandProperty Id

foreach ($permId in @($userReadAll, $groupReadAll)) {
    if ($existingPermIds -contains $permId) {
        Write-Skip "Permission $permId already declared"
        continue
    }
    # Type 'Role' = Application permission (not Delegated)
    Add-AzADAppPermission -ObjectId $appObjectId -ApiId $graphAppId -PermissionId $permId -Type Role
    Write-Ok "Declared permission $permId"
}
Write-Ok "User.Read.All and Group.Read.All declared on App Registration"

#------------------------------------------------------------------
# 4. Grant tenant-wide admin consent for Application permissions
#
#    For Application permissions the consent model is an appRoleAssignment
#    on the Service Principal — NOT an oauth2PermissionGrant (that is for
#    Delegated permissions only).
#
#    Invoke-AzRestMethod calls the Graph API directly because the Az module
#    has no cmdlet for Application-permission admin consent.
#    The POST is idempotent when the same appRoleId is already assigned.
#------------------------------------------------------------------
Write-Step "Granting tenant-wide admin consent (appRoleAssignments)"

# Resolve the Graph service principal in this tenant
$graphSp = Get-AzADServicePrincipal -ApplicationId $graphAppId
if (-not $graphSp) { throw "Could not resolve Microsoft Graph service principal in this tenant." }
$graphSpObjectId = $graphSp.Id

foreach ($permId in @($userReadAll, $groupReadAll)) {

    # Check if the appRoleAssignment already exists
    $checkResponse  = Invoke-AzRestMethod -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$spObjectId/appRoleAssignments"
    $assignments    = ($checkResponse.Content | ConvertFrom-Json).value
    $alreadyGranted = $assignments | Where-Object { $_.appRoleId -eq $permId }

    if ($alreadyGranted) {
        Write-Skip "Admin consent already granted for appRoleId=$permId"
        continue
    }

    $body = @{
        principalId = $spObjectId
        resourceId  = $graphSpObjectId
        appRoleId   = $permId
    } | ConvertTo-Json -Compress

    $response = Invoke-AzRestMethod -Method POST `
        -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$spObjectId/appRoleAssignments" `
        -Payload $body

    if ($response.StatusCode -notin 200, 201) {
        throw "Failed to grant admin consent for appRoleId=$permId. Status: $($response.StatusCode). Body: $($response.Content)"
    }
    Write-Ok "Admin consent granted for appRoleId=$permId"
}

#------------------------------------------------------------------
# 5. Security groups (idempotent)
#
#   $OwnerGroupName      — KV Administrator; deployer is member + owner
#   $AutomationGroupName — KV Secrets User;  SPN is member, deployer is owner
#------------------------------------------------------------------
Write-Step "Resolving security group $OwnerGroupName"
$existingOwnerGrp = Get-AzADGroup -DisplayName $OwnerGroupName | Select-Object -First 1
if ($existingOwnerGrp) {
    $ownerGroupObjectId = $existingOwnerGrp.Id
    Write-Skip "$OwnerGroupName objectId=$ownerGroupObjectId"
} else {
    $newOwnerGrp        = New-AzADGroup -DisplayName $OwnerGroupName -MailNickname $OwnerGroupName
    $ownerGroupObjectId = $newOwnerGrp.Id
    Write-Ok "Created $OwnerGroupName objectId=$ownerGroupObjectId"
}

Write-Step "Configuring $OwnerGroupName membership"
Add-GroupMemberIfMissing -GroupId $ownerGroupObjectId -MemberId $deployerObjectId -Label 'deployer'
Add-GroupOwnerIfMissing  -GroupId $ownerGroupObjectId -OwnerId  $deployerObjectId -Label 'deployer'

Write-Step "Resolving security group $AutomationGroupName"
$existingAutoGrp = Get-AzADGroup -DisplayName $AutomationGroupName | Select-Object -First 1
if ($existingAutoGrp) {
    $automationGroupObjectId = $existingAutoGrp.Id
    Write-Skip "$AutomationGroupName objectId=$automationGroupObjectId"
} else {
    $newAutoGrp              = New-AzADGroup -DisplayName $AutomationGroupName -MailNickname $AutomationGroupName
    $automationGroupObjectId = $newAutoGrp.Id
    Write-Ok "Created $AutomationGroupName objectId=$automationGroupObjectId"
}

Write-Step "Configuring $AutomationGroupName membership"
Add-GroupMemberIfMissing -GroupId $automationGroupObjectId -MemberId $spObjectId      -Label 'SPN'
Add-GroupOwnerIfMissing  -GroupId $automationGroupObjectId -OwnerId  $deployerObjectId -Label 'deployer'

#------------------------------------------------------------------
# 6. Deploy Bicep
#    Always: subscription-level Reader role for the SPN.
#    Unless -SkipKeyVault: resource group, Key Vault, KV role assignments.
#------------------------------------------------------------------
Write-Step "Deploying main.bicep (subscription scope)"

$deploymentName   = "fabriccatalyst-setup-$(Get-Date -Format 'yyyyMMdd-HHmm')"
$deploymentParams = @{
    azTenantId              = $TenantId
    azSubscriptionId        = $SubscriptionId
    azResourceGroupName     = $ResourceGroupName
    azResourceGroupLocation = $Location
    azKeyVaultName          = $KeyVaultName
    spnObjectId             = $spObjectId
    ownerGroupObjectId      = $ownerGroupObjectId
    automationGroupObjectId = $automationGroupObjectId
    tagOwner                = $TagOwner
    tagManagedBy            = $TagManagedBy
    skipKeyVault            = $SkipKeyVault.IsPresent
}

$null = New-AzDeployment `
    -Name                    $deploymentName `
    -Location                $Location `
    -TemplateFile            $script:BicepFile `
    -TemplateParameterObject $deploymentParams

if ($SkipKeyVault) {
    Write-Ok "Subscription Reader assigned; Key Vault skipped"
} else {
    $keyVaultUri = "https://$KeyVaultName.vault.azure.net/"
    Write-Ok "Key Vault provisioned: $keyVaultUri"

    # Role assignments propagate asynchronously in Entra ID.
    # Without a pause, Set-AzKeyVaultSecret fails with a 403 even though
    # the assignment was just created successfully.
    Write-Step "Waiting 30 s for RBAC role assignments to replicate in Entra ID"
    Start-Sleep -Seconds 30
    Write-Ok "Wait complete"
}

#------------------------------------------------------------------
# 7. Client secret — always creates a fresh one (1-year expiry)
#    and stores credentials in Key Vault.
#
#    KV secret names match what SrvPrincipal.yml / pipelines expect:
#      scrt-entraid-automation-srvprincipal-clientid
#      scrt-entraid-automation-srvprincipal-tenantid
#      scrt-entraid-automation-srvprincipal-password
#------------------------------------------------------------------
Write-Step "Creating client secret"

$secretExpiry = (Get-Date).AddYears(1)
$body = @{
    passwordCredential = @{
        displayName = "FabricCatalyst-$(Get-Date -Format 'yyyy-MM-dd')"
        endDateTime = $secretExpiry.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
} | ConvertTo-Json -Compress

$resp = Invoke-AzRestMethod -Method POST `
    -Uri     "https://graph.microsoft.com/v1.0/applications/$appObjectId/addPassword" `
    -Payload $body

if ($resp.StatusCode -notin 200, 201) {
    throw "Failed to create client secret. Status: $($resp.StatusCode). Body: $($resp.Content)"
}

$clientSecret = ($resp.Content | ConvertFrom-Json).secretText
Write-Ok "Client secret created (expires $($secretExpiry.ToString('yyyy-MM-dd')))"

if ($SkipKeyVault) {
    Write-Host "`n================================================================" -ForegroundColor Yellow
    Write-Host "  WARNING: -SkipKeyVault was set. Copy these credentials now." -ForegroundColor Yellow
    Write-Host "  They cannot be retrieved after this session." -ForegroundColor Yellow
    Write-Host "----------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  Client ID    : $appId"
    Write-Host "  Tenant ID    : $TenantId"
    Write-Host "  Client Secret: $clientSecret"
    Write-Host "================================================================`n" -ForegroundColor Yellow
} else {
    Write-Step "Storing credentials in Key Vault '$KeyVaultName'"

    $secrets = @{
        'scrt-entraid-automation-srvprincipal-clientid'  = $appId
        'scrt-entraid-automation-srvprincipal-tenantid'  = $TenantId
        'scrt-entraid-automation-srvprincipal-password'  = $clientSecret
    }

    foreach ($name in $secrets.Keys) {
        $secureValue = ConvertTo-SecureString $secrets[$name] -AsPlainText -Force
        $null = Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $name -SecretValue $secureValue
        Write-Ok "Stored $name"
    }
}

# Scrub the secret from memory
$clientSecret = $null

#------------------------------------------------------------------
# Summary
#------------------------------------------------------------------
Write-Host "`n================================================================" -ForegroundColor Green
Write-Host "  FabricCatalyst infrastructure setup complete." -ForegroundColor Green
Write-Host "----------------------------------------------------------------" -ForegroundColor Green
Write-Host "  App Registration : $appId"
Write-Host "  Service Principal: $spObjectId  ($SpnDisplayName)"
Write-Host "  Security groups  : $OwnerGroupName, $AutomationGroupName"
if ($SkipKeyVault) {
    Write-Host "  Key Vault        : skipped (credentials printed above)"
} else {
    Write-Host "  Key Vault        : $keyVaultUri"
}
Write-Host "  Subscription role: Reader on $SubscriptionId"
Write-Host "  Graph permissions: User.Read.All, Group.Read.All (Application, consented)"
Write-Host "----------------------------------------------------------------" -ForegroundColor Green
Write-Host "  Next steps (manual):" -ForegroundColor Yellow
Write-Host "    1. Add the SPN to your Azure DevOps organization (Basic access)" -ForegroundColor Yellow
Write-Host "    2. Install the FabricCatalyst extension from the ADO Marketplace" -ForegroundColor Yellow
Write-Host "    3. Create an ARM service connection using the SPN credentials" -ForegroundColor Yellow
Write-Host "    4. Complete the Fabric portal steps in docs/prerequisites.md" -ForegroundColor Yellow
Write-Host "================================================================`n" -ForegroundColor Green
