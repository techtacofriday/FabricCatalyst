###############################################################################
# Script Name:  CapacityFunctions.ps1
# Description:  Temporal descriptionThis module list the capacities reachable by the subscription
# Author:       Hector Lopez (Manager @Intelligent Platforms)
# Contact:      svenchio@techtacofriday.com
# Blog:         https://www.techtacofriday.com/
###############################################################################

function CreateDevOpsEnvironment {
    <#
      .SYNOPSIS
      Creates an Azure DevOps Environment in the current project if it doesn't already exist.

      .DESCRIPTION
      - Checks if an environment with the given name exists (by exact name).
      - If it exists, returns its id (no-op).
      - If it doesn't exist, creates it and returns the new id.
      - Uses the following script-scoped context variables (must be set by caller):
          $script:azdoBaseUrl, $script:organizationName, $script:projectName
      - Relies on helper functions you already have:
          CallApiEndpoint, WriteMessage, APIReturnedError, GetErrorResponse

      .PARAMETER environmentName
      Name of the Azure DevOps Environment.

      .PARAMETER description
      Optional description for the environment.

      .OUTPUTS
      [int] Environment Id on success; $null on failure.
    #>
    param(
        [parameter(Mandatory = $true)] [string] $environmentName,
        [parameter(Mandatory = $false)] [string] $description = ""
    )

    try {
        if ([string]::IsNullOrWhiteSpace($environmentName)) {
            $err = "Environment name is required."
            throw $err
        }

        # ------------------------------------------------------------
        # Check if environment already exists (by name)
        # GET .../distributedtask/environments?name={name}
        # ------------------------------------------------------------
        $encodedName = [System.Uri]::EscapeDataString($environmentName)
        $getEndpoint = "/$($script:organizationName)/$($script:projectName)/_apis/distributedtask/environments?name=$encodedName&api-version=7.1-preview.1"

        $getResponse = CallApiEndpoint -useRequestHeader "DevOps" -baseUrl $script:azdoBaseUrl -endPoint $getEndpoint
        if ($getResponse.responseObject.StatusCode -eq 200) {
            $payload = ($getResponse.responseObject.Content | ConvertFrom-Json)
            $existing = $payload.value | Where-Object { $_.name -eq $environmentName } | Select-Object -First 1
            if ($null -ne $existing) {
                WriteMessage "Info" "Environment '$environmentName' already exists (id=$($existing.id))."
                return [int]$existing.id
            }
        }
        else {
            $err = APIReturnedError -apiCallResponse $getResponse -intendedAction "checking for existing environment '$environmentName'"
            throw $err 
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

        $createEndpoint = "/$($script:organizationName)/$($script:projectName)/_apis/distributedtask/environments?api-version=7.1-preview.1"
        $createResponse = CallApiEndpoint -useRequestHeader "DevOps" -baseUrl $script:azdoBaseUrl -endPoint $createEndpoint -method "POST" -body $jsonBody

        if ($createResponse.responseObject.StatusCode -in 200,201) {
            $created = $createResponse.responseObject.Content | ConvertFrom-Json
            WriteMessage "Info" "Created environment '$environmentName' (id=$($created.id))."
            return [int]$created.id
        }
        else {
            $err = APIReturnedError -apiCallResponse $createResponse -intendedAction "creating environment '$environmentName'"
            throw $err 
        }
    }
    catch {
        $errorResponse = GetErrorResponse($_)
        WriteMessage "Error" "$($errorResponse). Function CreateDevOpsEnvironment failed."
        throw
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
        $listResponse = CallApiEndpoint -useRequestHeader "DevOps" -baseUrl $script:azdoBaseUrl -endPoint $endPoint
        if ($listResponse.responseObject.StatusCode -eq 200) {
            $pipelines = ($listResponse.responseObject.Content | ConvertFrom-Json).value
            $match = $pipelines | Where-Object { $_.name -eq $PipelineNameOrId } | Select-Object -First 1
            if ($null -eq $match) {
                $available = ($pipelines | Select-Object -ExpandProperty name) -join ', '
                WriteMessage "Error" "Pipeline '$PipelineNameOrId' not found. Available pipelines: $available"
                return $null
            }
            return [int]$match.id
        }
        else {
            $errorMessage = APIReturnedError -apiCallResponse $listResponse -intendedAction "listing pipelines"
            WriteMessage "Error" $errorMessage
            return $null
        }
    }
    catch {
        $errorResponse = GetErrorResponse($_)
        WriteMessage "Error" "$($errorResponse). Function ResolvePipelineId failed."
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
        $errorResponse = GetErrorResponse($_)
        WriteMessage "Error" "$($errorResponse). Function BuildRunPipelineJsonBody failed."
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
            WriteMessage "Error" "Request body for queueing pipeline is empty."
            return $null
        }

        $endPoint = "/$($script:organizationName)/$($script:projectName)/_apis/pipelines/$($pipelineId)/runs?api-version=7.1-preview.1"
        $queueResponse = CallApiEndpoint -useRequestHeader "DevOps" -baseUrl $script:azdoBaseUrl -endPoint $endPoint -method "POST" -body $jsonBody

        $statusCode = $queueResponse.responseObject.StatusCode
        if ($statusCode -in 200,201,202) {
            $content = $queueResponse.responseObject.Content | ConvertFrom-Json
            $runId = [int]$content.id
            WriteMessage "Info" "Pipeline (id=$pipelineId) was queued on branch '$Branch'. RunId=$runId"
            return $runId
        }
        else {
            $errorMessage = APIReturnedError -apiCallResponse $queueResponse -intendedAction "queueing pipeline run"
            WriteMessage "Error" $errorMessage
            return $null
        }
    }
    catch {
        $errorResponse = GetErrorResponse($_)
        WriteMessage "Error" "$($errorResponse). Function QueuePipelineRun failed."
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
        $runResponse = CallApiEndpoint -useRequestHeader "DevOps" -baseUrl $script:azdoBaseUrl -endPoint $endPoint
        if ($runResponse.responseObject.StatusCode -eq 200) {
            return ($runResponse.responseObject.Content | ConvertFrom-Json)
        }
        else {
            $errorMessage = APIReturnedError -apiCallResponse $runResponse -intendedAction "retrieving pipeline run"
            WriteMessage "Error" $errorMessage
            return $null
        }
    }
    catch {
        $errorResponse = GetErrorResponse($_)
        WriteMessage "Error" "$($errorResponse). Function GetPipelineRun failed."
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
            WriteMessage "Info" "Run $RunId → state=$state result=$result"

            if ($state -eq 'completed') {
                return $run
            }
            Start-Sleep -Seconds $PollSeconds
        } while ((Get-Date) -lt $deadline)

        WriteMessage "Error" "Timeout waiting for run $RunId to complete."
        return $null
    }
    catch {
        $errorResponse = GetErrorResponse($_)
        WriteMessage "Error" "$($errorResponse). Function WaitPipelineRun failed."
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
            WriteMessage "Info" "Pipeline run $runId succeeded."
            return $final
        }
        else {
            return $runId
        }
    }
    catch {
        $errorResponse = GetErrorResponse($_)
        WriteMessage "Error" "$($errorResponse). Function ExecutePipeline failed."
        return $null
    }
}
