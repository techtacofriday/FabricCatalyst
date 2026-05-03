[CmdletBinding()]
param()

#region Read inputs forwarded by index.js via FC_* env vars
$deploymentPipelineName = $env:FC_DEPLOYMENTPIPELINENAME
$targetStageName        = $env:FC_TARGETSTAGENAME
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

#region Invoke stage promotion
Write-Host "##[section]Starting FabricCatalyst Promote Stage - pipeline: $deploymentPipelineName, target stage: $targetStageName"

$params = @{
    deploymentPipelineName = $deploymentPipelineName
    targetStageName        = $targetStageName
    enableDiagnostics      = $enableDiagnostics
}

try {
    & "$PSScriptRoot\public\PromoteStageMainFunction.ps1" @params
} catch {
    Write-Host "##[error]$_"
    Write-Host "##vso[task.complete result=Failed;]Stage promotion failed."
    exit 1
}
#endregion
