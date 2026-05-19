[CmdletBinding()]
param()

#region Read inputs forwarded by index.js via FC_* env vars
$workspacePrefix          = $env:FC_WORKSPACEPREFIX
$capacityName             = $env:FC_CAPACITYNAME
$environmentList          = $env:FC_ENVIRONMENTLIST
$fabricGitConnectionName  = $env:FC_FABRICGITCONNECTIONNAME
$organizationName         = $env:FC_ORGANIZATIONNAME
$projectName              = $env:FC_PROJECTNAME
$repositoryName           = $env:FC_REPOSITORYNAME
$sourceBranchName         = $env:FC_SOURCEBRANCHNAME
$gitProviderType          = if ($env:FC_GITPROVIDERTYPE) { $env:FC_GITPROVIDERTYPE } else { 'AzureDevOps' }
$externalGitPat           = $env:FC_EXTERNALGITPAT
$itemsGitFolder           = $env:FC_ITEMSGITFOLDER
$deploymentDirectoryPath  = $env:FC_DEPLOYMENTDIRECTORYPATH
$domainName               = $env:FC_DOMAINNAME
$subDomainName            = $env:FC_SUBDOMAINNAME
$workspaceAdminsList         = $env:FC_WORKSPACEADMINSLIST
$workspaceContributorsList   = $env:FC_WORKSPACECONTRIBUTORSLIST
$workspaceMembersList        = $env:FC_WORKSPACEMEMBERSLIST
$workspaceViewersList        = $env:FC_WORKSPACEVIEWERSLIST
$fabricItemsLocation      = if ($env:FC_FABRICITEMSLOCATION){ $env:FC_FABRICITEMSLOCATION } else { 'LocalDirectory' }
$useEmptyBranch           = $env:FC_USEEMPTYBRANCH
$customizeDeployment      = $env:FC_CUSTOMIZEDEPLOYMENT
$enableDiagnostics        = $env:FC_ENABLEDIAGNOSTICS
#endregion

#region Azure authentication
$scheme   = $env:FC_AUTH_SCHEME
$tenantId = $env:FC_TENANT_ID
$clientId = $env:FC_CLIENT_ID

Write-Host "##[section]Connecting to Azure (tenant: $tenantId, scheme: $scheme)"

if ($scheme -eq 'ServicePrincipal') {
    $secSecret  = ConvertTo-SecureString $env:FC_CLIENT_KEY -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($clientId, $secSecret)
    Connect-AzAccount -ServicePrincipal -Credential $credential -Tenant $tenantId | Out-Null
}
elseif ($scheme -eq 'WorkloadIdentityFederation') {
    $oidcUri  = "$($env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI)$($env:SYSTEM_TEAMPROJECTID)/_apis/distributedtask/hubs/build/plans/$($env:SYSTEM_PLANID)/jobs/$($env:SYSTEM_JOBID)/oidctoken?serviceConnectionId=$($env:FC_SERVICE_CONNECTION_ID)&api-version=7.1-preview.1"
    $oidcResp = Invoke-RestMethod -Uri $oidcUri -Method Post -ContentType 'application/json' -Body '{}' `
                    -Headers @{ Authorization = "Bearer $env:SYSTEM_ACCESSTOKEN" }
    Connect-AzAccount -ServicePrincipal -ApplicationId $clientId -FederatedToken $oidcResp.oidcToken -Tenant $tenantId | Out-Null
}
else {
    throw "Unsupported authentication scheme: '$scheme'. Supported: ServicePrincipal, WorkloadIdentityFederation."
}
#endregion

#region Invoke deployment
Write-Host "##[section]Starting FabricCatalyst Auto Deployment - workspace prefix: $workspacePrefix"

# Required parameters always passed
$params = @{
    fabricGitConnectionName  = $fabricGitConnectionName
    workspacePrefix          = $workspacePrefix
    capacityName             = $capacityName
    organizationName         = $organizationName
    projectName              = $projectName
    repositoryName           = $repositoryName
    sourceBranchName         = $sourceBranchName
    gitProviderType          = $gitProviderType
    externalGitPat           = $externalGitPat
    useEmptyBranch           = $useEmptyBranch
    itemsGitFolder           = $itemsGitFolder
    environmentList          = $environmentList
    deploymentDirectoryPath  = $deploymentDirectoryPath
    fabricItemsLocation      = $fabricItemsLocation
    customizeDeployment      = $customizeDeployment
    workspaceAdminsList      = $workspaceAdminsList
    enableDiagnostics        = $enableDiagnostics
}

# Optional parameters: only pass when non-empty so script defaults take effect
if (![string]::IsNullOrWhiteSpace($domainName))                { $params.domainName                = $domainName }
if (![string]::IsNullOrWhiteSpace($subDomainName))             { $params.subDomainName             = $subDomainName }
if (![string]::IsNullOrWhiteSpace($workspaceContributorsList)) { $params.workspaceContributorsList = $workspaceContributorsList }
if (![string]::IsNullOrWhiteSpace($workspaceMembersList))      { $params.workspaceMembersList      = $workspaceMembersList }
if (![string]::IsNullOrWhiteSpace($workspaceViewersList))      { $params.workspaceViewersList      = $workspaceViewersList }

try {
    & "$PSScriptRoot\public\AutoMainFunction.ps1" @params
} catch {
    Write-Host "##[error]$_"
    Write-Host "##vso[task.complete result=Failed;]Deployment failed."
    exit 1
}
#endregion
