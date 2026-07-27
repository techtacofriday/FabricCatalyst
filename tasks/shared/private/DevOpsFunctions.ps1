###############################################################################
# Script Name:  DevOpsFunctions.ps1
# Description:  Azure DevOps environment provisioning (create, co-administrators,
#               approval checks) plus pipeline-run helpers.
# Author:       Hector Lopez (Manager @Intelligent Platforms)
# Contact:      svenchio@techtacofriday.com
# Blog:         https://www.techtacofriday.com/
###############################################################################

function New-DevOpsEnvironment {
    <#
      .SYNOPSIS
      Creates an Azure DevOps Environment in the current project if it doesn't already exist.

      .DESCRIPTION
      - Checks if an environment with the given name exists (by exact name).
      - If it exists, returns its id (no-op).
      - If it doesn't exist, creates it and returns the new id.

      .PARAMETER environmentName
      Name of the Azure DevOps Environment.

      .PARAMETER description
      Optional description for the environment.

      .PARAMETER Context
      Optional AzdoConfig (from New-AzdoConfig). Falls back to $script: variables when omitted.

      .OUTPUTS
      [int] Environment Id on success.
    #>
    param(
        [parameter(Mandatory = $true)]  [string] $environmentName,
        [parameter(Mandatory = $false)] [string] $description = "",
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )

    if ([string]::IsNullOrWhiteSpace($environmentName)) {
        throw "Environment name is required."
    }

    $azdoBaseUrl      = if ($null -ne $Context) { $Context.AzdoBaseUrl }      else { $script:azdoBaseUrl }
    $organizationName = if ($null -ne $Context) { $Context.OrganizationName } else { $script:organizationName }
    $projectName      = if ($null -ne $Context) { $Context.ProjectName }      else { $script:projectName }

    # ------------------------------------------------------------
    # Check if environment already exists (by name)
    # GET .../distributedtask/environments?name={name}
    # ------------------------------------------------------------
    $encodedName = [System.Uri]::EscapeDataString($environmentName)
    $getEndpoint = "/$organizationName/$projectName/_apis/distributedtask/environments?name=$encodedName&api-version=7.1"

    $getResponse = Invoke-ApiEndpoint -useRequestHeader "DevOps" -baseUrl $azdoBaseUrl -endPoint $getEndpoint -Context $Context
    if ($getResponse.isException -eq $false) {
        $payload = $getResponse.responseObject.Content | ConvertFrom-Json
        $existing = $payload.value | Where-Object { $_.name -eq $environmentName } | Select-Object -First 1
        if ($null -ne $existing) {
            Write-Message "Info" "Environment '$environmentName' already exists (id=$($existing.id))."
            return [int]$existing.id
        }
    }
    else {
        throw (APIReturnedError -apiCallResponse $getResponse -intendedAction "checking for existing environment '$environmentName'")
    }

    # ------------------------------------------------------------
    # Create environment
    # POST .../distributedtask/environments
    # Body: { "name": "...", "description": "..." }
    # ------------------------------------------------------------
    $body = @{ name = $environmentName }
    if (-not [string]::IsNullOrWhiteSpace($description)) {
        $body.description = $description
    }
    $jsonBody = $body | ConvertTo-Json -Depth 10

    $createEndpoint = "/$organizationName/$projectName/_apis/distributedtask/environments?api-version=7.1"
    $createResponse = Invoke-ApiEndpoint -useRequestHeader "DevOps" -baseUrl $azdoBaseUrl -endPoint $createEndpoint -method "POST" -body $jsonBody -Context $Context

    if ($createResponse.isException -eq $false) {
        $created = $createResponse.responseObject.Content | ConvertFrom-Json
        Write-Message "Info" "Created environment '$environmentName' (id=$($created.id))."
        return [int]$created.id
    }
    else {
        throw (APIReturnedError -apiCallResponse $createResponse -intendedAction "creating environment '$environmentName'")
    }
}

function Get-DevOpsProjectId {
    <#
      .SYNOPSIS
      Resolves an Azure DevOps project name to its project id (GUID).
      Needed because the Security Roles resource id for an environment is
      "{projectId}_{environmentId}", not the project name.
    #>
    param(
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )

    $azdoBaseUrl      = if ($null -ne $Context) { $Context.AzdoBaseUrl }      else { $script:azdoBaseUrl }
    $organizationName = if ($null -ne $Context) { $Context.OrganizationName } else { $script:organizationName }
    $projectName      = if ($null -ne $Context) { $Context.ProjectName }      else { $script:projectName }

    $encodedProject = [System.Uri]::EscapeDataString($projectName)
    $endPoint = "/$organizationName/_apis/projects/$($encodedProject)?api-version=7.1"
    $response = Invoke-ApiEndpoint -useRequestHeader "DevOps" -baseUrl $azdoBaseUrl -endPoint $endPoint -Context $Context

    if ($response.isException -eq $false) {
        $project = $response.responseObject.Content | ConvertFrom-Json
        return [string]$project.id
    }
    else {
        throw (APIReturnedError -apiCallResponse $response -intendedAction "resolving project id for '$projectName'")
    }
}

function Resolve-DevOpsIdentityId {
    <#
      .SYNOPSIS
      Resolves a UPN or group display name to its Azure DevOps identity id (the
      "Storage Key"/VSID GUID used by both the Security Roles and Checks APIs).

      .DESCRIPTION
      Uses the VSSPS Identities API, which lives on a different host
      (vssps.dev.azure.com) than the rest of the Azure DevOps REST surface.
      On Azure DevOps Server (on-prem), there is no separate vssps host, so
      the configured AzdoBaseUrl is reused as-is in that case.

      .OUTPUTS
      [PSCustomObject]@{ Id; DisplayName } or $null if not found.
    #>
    param(
        [parameter(Mandatory = $true)]  [string] $Identifier,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )

    $azdoBaseUrl      = if ($null -ne $Context) { $Context.AzdoBaseUrl }      else { $script:azdoBaseUrl }
    $organizationName = if ($null -ne $Context) { $Context.OrganizationName } else { $script:organizationName }

    # vssps.dev.azure.com only exists for Azure DevOps Services; on-prem Server
    # exposes the Identities API on the same host as everything else.
    $identitiesBaseUrl = if ($azdoBaseUrl -match '^https://dev\.azure\.com/?$') { "https://vssps.dev.azure.com" } else { $azdoBaseUrl }

    $encodedIdentifier = [System.Uri]::EscapeDataString($Identifier)
    $endPoint = "/$organizationName/_apis/identities?searchFilter=General&filterValue=$encodedIdentifier&queryMembership=None&api-version=7.1"
    $response = Invoke-ApiEndpoint -useRequestHeader "DevOps" -baseUrl $identitiesBaseUrl -endPoint $endPoint -Context $Context

    if ($response.isException -eq $false) {
        $payload = $response.responseObject.Content | ConvertFrom-Json
        $identity = $payload.value | Select-Object -First 1
        if ($null -eq $identity) {
            Write-Message "Warning" "Could not resolve '$Identifier' to an Azure DevOps identity."
            return $null
        }
        return [PSCustomObject]@{
            Id          = [string]$identity.id
            DisplayName = if ($identity.providerDisplayName) { $identity.providerDisplayName } else { $Identifier }
        }
    }
    else {
        throw (APIReturnedError -apiCallResponse $response -intendedAction "resolving identity '$Identifier'")
    }
}

function Get-DevOpsEnvironmentRoleAssignments {
    <#
      .SYNOPSIS
      Lists the current Security Role assignments (Administrator/User/Reader)
      for an Azure DevOps Environment.

      .PARAMETER ResourceId
      "{projectId}_{environmentId}" — see Get-DevOpsProjectId.
    #>
    param(
        [parameter(Mandatory = $true)]  [string] $ResourceId,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )

    $azdoBaseUrl      = if ($null -ne $Context) { $Context.AzdoBaseUrl }      else { $script:azdoBaseUrl }
    $organizationName = if ($null -ne $Context) { $Context.OrganizationName } else { $script:organizationName }

    # scopeId is not documented by Microsoft; "distributedtask.environmentreferencerole"
    # is the value used consistently across community tooling for environment security roles.
    $endPoint = "/$organizationName/_apis/securityroles/scopes/distributedtask.environmentreferencerole/roleassignments/resources/$($ResourceId)?api-version=7.1-preview.1"
    $response = Invoke-ApiEndpoint -useRequestHeader "DevOps" -baseUrl $azdoBaseUrl -endPoint $endPoint -Context $Context

    if ($response.isException -eq $false) {
        $payload = $response.responseObject.Content | ConvertFrom-Json
        # Unary comma prevents PowerShell from unwrapping a single-assignment result back to
        # a bare object across the return boundary (Count would silently read $null otherwise).
        return , @(if ($payload.value) { $payload.value } else { @($payload) })
    }
    elseif ($response.responseObject.StatusCode -eq 404) {
        # Not documented by Microsoft either way (the List Role Assignments reference only
        # shows a 200 response). Observed in practice for an environment that has never had
        # an explicit Security Role assignment set - only the implicit creator-as-Administrator
        # access exists. Treated as "no assignments yet" rather than a hard failure.
        Write-Message "Warning" "No existing role assignments found for resource '$ResourceId' (404); treating as none."
        return @()
    }
    else {
        throw (APIReturnedError -apiCallResponse $response -intendedAction "listing role assignments for resource '$ResourceId'")
    }
}

function Set-DevOpsEnvironmentAdministrators {
    <#
      .SYNOPSIS
      Grants Administrator on an Azure DevOps Environment to a set of
      co-administrator UPNs/groups.

      .DESCRIPTION
      Additive only: never removes an existing Administrator. Azure DevOps
      already grants Administrator to whichever identity creates the
      environment (that's the exact gap this task exists to close - creators
      get access automatically, co-admins don't), so there is nothing to
      preserve here; resolving "who is currently running this task" to an
      Azure DevOps identity is unreliable for Service Principals (Get-AzContext
      returns the AAD Application/Client id, but Azure DevOps identities key
      off the Service Principal Object id - a different, undocumented-to-derive
      GUID) and isn't needed once removal is off the table.

      .PARAMETER EnvironmentId
      Numeric id returned by New-DevOpsEnvironment.

      .PARAMETER CoAdministrators
      Semicolon-separated list of UPNs/group names to grant Administrator on
      the environment. Empty/whitespace is a no-op.
    #>
    param(
        [parameter(Mandatory = $true)]  [int]    $EnvironmentId,
        [parameter(Mandatory = $false)] [string] $CoAdministrators = "",
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )

    $desiredUpns = Resolve-NormalizedUpnList -upnList $CoAdministrators
    if ($desiredUpns.Count -eq 0) {
        Write-Message "Info" "No co-administrators provided; leaving environment Administrators unchanged."
        return
    }

    $azdoBaseUrl      = if ($null -ne $Context) { $Context.AzdoBaseUrl }      else { $script:azdoBaseUrl }
    $organizationName = if ($null -ne $Context) { $Context.OrganizationName } else { $script:organizationName }

    $projectId  = Get-DevOpsProjectId -Context $Context
    $resourceId = "$($projectId)_$($EnvironmentId)"

    $resolvedByUpn = @{}
    $failed = @()
    foreach ($upn in $desiredUpns) {
        $identity = Resolve-DevOpsIdentityId -Identifier $upn -Context $Context
        if ($null -ne $identity -and -not [string]::IsNullOrWhiteSpace($identity.Id)) {
            $resolvedByUpn[$upn] = $identity
        }
        else {
            $failed += $upn
        }
    }
    if ($failed.Count -gt 0) {
        Write-Message "Warning" "Could not resolve the following co-administrators: $($failed -join ', ')"
    }
    if ($resolvedByUpn.Count -eq 0) {
        Write-Message "Warning" "No co-administrators could be resolved; leaving environment Administrators unchanged."
        return
    }

    $existingAssignments = Get-DevOpsEnvironmentRoleAssignments -ResourceId $resourceId -Context $Context
    $existingAdminIds = @($existingAssignments | Where-Object { $_.role.name -eq 'Administrator' } | ForEach-Object { $_.identity.id })

    $added = 0
    foreach ($identity in $resolvedByUpn.Values) {
        if ($existingAdminIds -contains $identity.Id) {
            Write-Message "Info" "'$($identity.DisplayName)' is already an Administrator on environment (id=$EnvironmentId)."
            continue
        }

        $assignment = @{ roleName = "Administrator"; userId = $identity.Id }
        $jsonBody = ConvertTo-Json -InputObject @($assignment) -Depth 6

        $endPoint = "/$organizationName/_apis/securityroles/scopes/distributedtask.environmentreferencerole/roleassignments/resources/$($resourceId)?api-version=7.1-preview.1"
        $addResponse = Invoke-ApiEndpoint -useRequestHeader "DevOps" -baseUrl $azdoBaseUrl -endPoint $endPoint -method "PUT" -body $jsonBody -Context $Context

        if ($addResponse.isException -eq $false) {
            Write-Message "Info" "Added '$($identity.DisplayName)' as Administrator on environment (id=$EnvironmentId)."
            $added++
        }
        else {
            throw (APIReturnedError -apiCallResponse $addResponse -intendedAction "adding Administrator role assignment for '$($identity.DisplayName)'")
        }
    }

    Write-Message "Info" ("Administrator sync complete for environment (id={0}): Added={1}" -f $EnvironmentId, $added)
}

function Set-DevOpsEnvironmentApprover {
    <#
      .SYNOPSIS
      Configures a single manual-approval Check on an Azure DevOps Environment.
      No-op if the environment already has an Approval check configured.

      .PARAMETER ApproverUpn
      UPN or group name required to approve. Empty/whitespace skips configuration.
    #>
    param(
        [parameter(Mandatory = $true)]  [int]    $EnvironmentId,
        [parameter(Mandatory = $false)] [string] $ApproverUpn = "",
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )

    if ([string]::IsNullOrWhiteSpace($ApproverUpn)) {
        Write-Message "Info" "No approver UPN provided; skipping approval check configuration."
        return
    }

    $azdoBaseUrl      = if ($null -ne $Context) { $Context.AzdoBaseUrl }      else { $script:azdoBaseUrl }
    $organizationName = if ($null -ne $Context) { $Context.OrganizationName } else { $script:organizationName }
    $projectName      = if ($null -ne $Context) { $Context.ProjectName }      else { $script:projectName }

    $listEndpoint = "/$organizationName/$projectName/_apis/pipelines/checks/configurations?resourceType=environment&resourceId=$EnvironmentId&api-version=7.1-preview.1"
    $queryResponse = Invoke-ApiEndpoint -useRequestHeader "DevOps" -baseUrl $azdoBaseUrl -endPoint $listEndpoint -Context $Context

    if ($queryResponse.isException -eq $false) {
        $payload = $queryResponse.responseObject.Content | ConvertFrom-Json
        $existingChecks = @($payload.value)
        $existingApproval = $existingChecks | Where-Object { $_.type.name -eq 'Approval' } | Select-Object -First 1
        if ($null -ne $existingApproval) {
            Write-Message "Info" "Environment (id=$EnvironmentId) already has an Approval check configured; leaving it unchanged."
            return
        }
    }
    else {
        throw (APIReturnedError -apiCallResponse $queryResponse -intendedAction "listing existing checks for environment (id=$EnvironmentId)")
    }

    $approverIdentity = Resolve-DevOpsIdentityId -Identifier $ApproverUpn -Context $Context
    if ($null -eq $approverIdentity -or [string]::IsNullOrWhiteSpace($approverIdentity.Id)) {
        throw "Could not resolve approver '$ApproverUpn' to an Azure DevOps identity."
    }

    $checkBody = @{
        type     = @{ name = "Approval" }
        settings = @{
            approvers            = @(@{ id = $approverIdentity.Id })
            executionOrder       = "anyOrder"
            minRequiredApprovers = 1
            instructions         = ""
        }
        resource = @{ type = "environment"; id = "$EnvironmentId" }
    } | ConvertTo-Json -Depth 8

    $createEndpoint = "/$organizationName/$projectName/_apis/pipelines/checks/configurations?api-version=7.1-preview.1"
    $createResponse = Invoke-ApiEndpoint -useRequestHeader "DevOps" -baseUrl $azdoBaseUrl -endPoint $createEndpoint -method "POST" -body $checkBody -Context $Context

    if ($createResponse.isException -eq $false) {
        Write-Message "Info" "Configured '$($approverIdentity.DisplayName)' as approver on environment (id=$EnvironmentId)."
    }
    else {
        throw (APIReturnedError -apiCallResponse $createResponse -intendedAction "configuring approval check for environment (id=$EnvironmentId)")
    }
}


function ResolvePipelineId {
    <#
      .SYNOPSIS
      Resolve a pipeline ID from a name or return the numeric ID if already provided.
    #>
    param(
        [parameter(Mandatory = $true)] [string] $PipelineNameOrId
    )
    try {
        # If it's already numeric, return as int
        if ([int]::TryParse($PipelineNameOrId, [ref]([int]0))) {
            return [int]$PipelineNameOrId
        }

        $endPoint = "/$($script:organizationName)/$($script:projectName)/_apis/pipelines?api-version=7.1-preview.1"
        $listResponse = Invoke-ApiEndpoint -useRequestHeader "DevOps" -baseUrl $script:azdoBaseUrl -endPoint $endPoint
        if ($listResponse.responseObject.StatusCode -eq 200) {
            $pipelines = ($listResponse.responseObject.Content | ConvertFrom-Json).value
            $match = $pipelines | Where-Object { $_.name -eq $PipelineNameOrId } | Select-Object -First 1
            if ($null -eq $match) {
                $available = ($pipelines | Select-Object -ExpandProperty name) -join ', '
                Write-Message "Error" "Pipeline '$PipelineNameOrId' not found. Available pipelines: $available"
                return $null
            }
            return [int]$match.id
        }
        else {
            $errorMessage = APIReturnedError -apiCallResponse $listResponse -intendedAction "listing pipelines"
            Write-Message "Error" $errorMessage
            return $null
        }
    }
    catch {
        $errorResponse = Get-ErrorResponse($_)
        Write-Message "Error" "$($errorResponse). Function ResolvePipelineId failed."
        return $null
    }
}

function BuildRunPipelineJsonBody {
    <#
      .SYNOPSIS
      Build JSON body for /pipelines/{id}/runs including branch, variables, and templateParameters.
      .PARAMETER Branch
      Branch name without refs/heads/ (e.g., 'main').
      .PARAMETER Variables
      Hashtable of runtime variables (string values), e.g. @{ dataProduct='default'; someFlag='true' }
      .PARAMETER TemplateParameters
      Hashtable representing YAML template parameters, e.g. @{ layerArray = @('dev','uat','prod') }
    #>
    param(
        [parameter(Mandatory = $true)] [string]     $Branch,
        [parameter(Mandatory = $false)] [hashtable] $Variables = @{},
        [parameter(Mandatory = $false)] [hashtable] $TemplateParameters = @{}
    )
    try {
        # Shape variables payload as { "var": { "value": "..." }, ... }
        $varsPayload = @{}
        foreach ($k in $Variables.Keys) {
            $varsPayload[$k] = @{ value = [string]$Variables[$k] }
        }

        $body = [ordered]@{
            resources = @{
                repositories = @{
                    self = @{
                        refName = "refs/heads/$Branch"
                    }
                }
            }
            variables = $varsPayload
        }

        if ($TemplateParameters.Keys.Count -gt 0) {
            $body.templateParameters = $TemplateParameters
        }

        return ($body | ConvertTo-Json -Depth 50)
    }
    catch {
        $errorResponse = Get-ErrorResponse($_)
        Write-Message "Error" "$($errorResponse). Function BuildRunPipelineJsonBody failed."
        return $null
    }
}

function QueuePipelineRun {
    <#
      .SYNOPSIS
      Queue an Azure DevOps pipeline run via REST API with variables and template parameters.
      .PARAMETER PipelineNameOrId
      Pipeline display name or numeric ID.
      .PARAMETER Branch
      Branch name without refs/heads/ (e.g. 'main').
      .PARAMETER Variables
      Hashtable of runtime variables to pass to the run.
      .PARAMETER TemplateParameters
      Hashtable of YAML template parameters to pass to the run.
      .OUTPUTS
      Returns the queued run id (int) on success; $null otherwise.
    #>
    param(
        [parameter(Mandatory = $true)] [string]     $PipelineNameOrId,
        [parameter(Mandatory = $true)] [string]     $Branch,
        [parameter(Mandatory = $false)] [hashtable] $Variables = @{},
        [parameter(Mandatory = $false)] [hashtable] $TemplateParameters = @{}
    )
    try {
        $pipelineId = ResolvePipelineId -PipelineNameOrId $PipelineNameOrId
        if ($null -eq $pipelineId) { return $null }

        $jsonBody = BuildRunPipelineJsonBody -Branch $Branch -Variables $Variables -TemplateParameters $TemplateParameters
        if ([string]::IsNullOrWhiteSpace($jsonBody)) {
            Write-Message "Error" "Request body for queueing pipeline is empty."
            return $null
        }

        $endPoint = "/$($script:organizationName)/$($script:projectName)/_apis/pipelines/$($pipelineId)/runs?api-version=7.1-preview.1"
        $queueResponse = Invoke-ApiEndpoint -useRequestHeader "DevOps" -baseUrl $script:azdoBaseUrl -endPoint $endPoint -method "POST" -body $jsonBody

        $statusCode = $queueResponse.responseObject.StatusCode
        if ($statusCode -in 200,201,202) {
            $content = $queueResponse.responseObject.Content | ConvertFrom-Json
            $runId = [int]$content.id
            Write-Message "Info" "Pipeline (id=$pipelineId) was queued on branch '$Branch'. RunId=$runId"
            return $runId
        }
        else {
            $errorMessage = APIReturnedError -apiCallResponse $queueResponse -intendedAction "queueing pipeline run"
            Write-Message "Error" $errorMessage
            return $null
        }
    }
    catch {
        $errorResponse = Get-ErrorResponse($_)
        Write-Message "Error" "$($errorResponse). Function QueuePipelineRun failed."
        return $null
    }
}

function GetPipelineRun {
    <#
      .SYNOPSIS
      Get details of a pipeline run via REST API.
      .OUTPUTS
      Returns the parsed JSON object of the run on success; $null otherwise.
    #>
    param(
        [parameter(Mandatory = $true)] [int] $RunId
    )
    try {
        $endPoint = "/$($script:organizationName)/$($script:projectName)/_apis/pipelines/runs/$($RunId)?api-version=7.1-preview.1"
        $runResponse = Invoke-ApiEndpoint -useRequestHeader "DevOps" -baseUrl $script:azdoBaseUrl -endPoint $endPoint
        if ($runResponse.responseObject.StatusCode -eq 200) {
            return ($runResponse.responseObject.Content | ConvertFrom-Json)
        }
        else {
            $errorMessage = APIReturnedError -apiCallResponse $runResponse -intendedAction "retrieving pipeline run"
            Write-Message "Error" $errorMessage
            return $null
        }
    }
    catch {
        $errorResponse = Get-ErrorResponse($_)
        Write-Message "Error" "$($errorResponse). Function GetPipelineRun failed."
        return $null
    }
}

function WaitPipelineRun {
    <#
      .SYNOPSIS
      Poll a pipeline run until completion (succeeded/failed/canceled/skipped) or timeout.
      .PARAMETER PollSeconds
      Interval between polls (seconds).
      .PARAMETER TimeoutMinutes
      Max time to wait before failing.
      .OUTPUTS
      Returns the final run object on success; $null on timeout or failure to retrieve.
    #>
    param(
        [parameter(Mandatory = $true)] [int] $RunId,
        [parameter(Mandatory = $false)] [int] $PollSeconds = 10,
        [parameter(Mandatory = $false)] [int] $TimeoutMinutes = 120
    )
    try {
        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        do {
            $run = GetPipelineRun -RunId $RunId
            if ($null -eq $run) { return $null }

            $state  = $run.state   # inProgress|completed|cancelling
            $result = $run.result  # succeeded|failed|canceled|skipped (when completed)
            Write-Message "Info" "Run $RunId -> state=$state result=$result"

            if ($state -eq 'completed') {
                return $run
            }
            Start-Sleep -Seconds $PollSeconds
        } while ((Get-Date) -lt $deadline)

        Write-Message "Error" "Timeout waiting for run $RunId to complete."
        return $null
    }
    catch {
        $errorResponse = Get-ErrorResponse($_)
        Write-Message "Error" "$($errorResponse). Function WaitPipelineRun failed."
        return $null
    }
}

function ExecutePipeline {
    <#
      .SYNOPSIS
      High-level helper: queue pipeline and (optionally) wait for completion.
      .PARAMETER PipelineNameOrId
      Pipeline display name or numeric ID.
      .PARAMETER Branch
      Branch name without refs/heads/ (e.g. 'main').
      .PARAMETER Variables
      Hashtable of runtime variables to pass to the run.
      .PARAMETER TemplateParameters
      Hashtable of YAML template parameters to pass to the run.
      .PARAMETER Wait
      Switch to wait for pipeline completion and validate success.
      .OUTPUTS
      When -Wait is specified: returns the final run object (and throws if not succeeded).
      When -Wait is not specified: returns the queued run id (int).
    #>
    param(
        [parameter(Mandatory = $true)] [string]     $PipelineNameOrId,
        [parameter(Mandatory = $true)] [string]     $Branch,
        [parameter(Mandatory = $false)] [hashtable] $Variables = @{},
        [parameter(Mandatory = $false)] [hashtable] $TemplateParameters = @{},
        [switch] $Wait,
        [int] $PollSeconds = 10,
        [int] $TimeoutMinutes = 120
    )
    try {
        $runId = QueuePipelineRun -PipelineNameOrId $PipelineNameOrId -Branch $Branch -Variables $Variables -TemplateParameters $TemplateParameters
        if ($null -eq $runId) { return $null }

        if ($Wait.IsPresent) {
            $final = WaitPipelineRun -RunId $runId -PollSeconds $PollSeconds -TimeoutMinutes $TimeoutMinutes
            if ($null -eq $final) { return $null }
            if ($final.result -ne 'succeeded') {
                throw "Pipeline run $runId did not succeed. state=$($final.state) result=$($final.result)"
            }
            Write-Message "Info" "Pipeline run $runId succeeded."
            return $final
        }
        else {
            return $runId
        }
    }
    catch {
        $errorResponse = Get-ErrorResponse($_)
        Write-Message "Error" "$($errorResponse). Function ExecutePipeline failed."
        return $null
    }
}
