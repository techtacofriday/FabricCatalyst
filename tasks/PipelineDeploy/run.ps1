[CmdletBinding()]
param()

#region Read inputs forwarded by index.js via FC_* env vars
$workspacePrefix        = $env:FC_WORKSPACEPREFIX
$environmentList        = $env:FC_ENVIRONMENTLIST
$deploymentPipelinePrefix = $env:FC_DEPLOYMENTPIPELINEPREFIX
$pipelineAdminsList     = $env:FC_PIPELINEADMINSLIST
$enableDiagnostics      = $env:FC_ENABLEDIAGNOSTICS
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

#region Invoke pipeline deployment
Write-Host "##[section]Starting FabricCatalyst Pipeline Deployment - pipeline: $deploymentPipelinePrefix"

$params = @{
    workspacePrefix        = $workspacePrefix
    environmentList        = $environmentList
    deploymentPipelinePrefix = $deploymentPipelinePrefix
    enableDiagnostics      = $enableDiagnostics
}

if (![string]::IsNullOrWhiteSpace($pipelineAdminsList)) { $params.pipelineAdminsList = $pipelineAdminsList }

try {
    & "$PSScriptRoot\public\PipelineDeployMainFunction.ps1" @params
} catch {
    Write-Host "##[error]$_"
    Write-Host "##vso[task.complete result=Failed;]Pipeline deployment failed."
    exit 1
}
#endregion
