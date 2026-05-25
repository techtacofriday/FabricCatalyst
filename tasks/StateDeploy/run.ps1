[CmdletBinding()]
param()

#region Read inputs forwarded by index.js via FC_* env vars
$jsonMapFileName         = $env:FC_JSONMAPFILENAME
$organizationName        = $env:FC_ORGANIZATIONNAME
$projectName             = $env:FC_PROJECTNAME
$repositoryName          = $env:FC_REPOSITORYNAME
$sourceBranchName        = $env:FC_SOURCEBRANCHNAME
$deploymentDirectoryPath = $env:FC_DEPLOYMENTDIRECTORYPATH
$whatIf                  = $env:FC_WHATIF
$remove                  = $env:FC_REMOVE
$enableDiagnostics       = $env:FC_ENABLEDIAGNOSTICS
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

#region Invoke state deployment
Write-Host "##[section]Starting FabricCatalyst State Deploy - state file: $jsonMapFileName (whatIf=$whatIf, remove=$remove)"

$params = @{
    jsonMapFileName          = $jsonMapFileName
    organizationName         = $organizationName
    projectName              = $projectName
    repositoryName           = $repositoryName
    sourceBranchName         = $sourceBranchName
    deploymentDirectoryPath  = $deploymentDirectoryPath
    whatIf                   = $whatIf
    remove                   = $remove
    enableDiagnostics        = $enableDiagnostics
}

try {
    & "$PSScriptRoot\public\StateMainFunction.ps1" @params
} catch {
    Write-Host "##[error]$_"
    Write-Host "##vso[task.complete result=Failed;]State deployment failed."
    exit 1
}
#endregion
