###############################################################################
# Script Name:  PipelineFunctions.ps1
# Description:  Temporal description
# Author:       Hector Lopez (Manager @Intelligent Platforms)
# Contact:      svenchio@techtacofriday.com
# Blog:         https://www.techtacofriday.com/
###############################################################################

function New-DeploymentPipeline {
    param (
        [parameter(Mandatory = $true)] [String]  $pipelineName,
        [parameter(Mandatory = $true)] [String]  $pipelineDescription,
        [parameter(Mandatory = $true)] [array]   $stages
    )

    $endPoint = "/deploymentPipelines" #https://learn.microsoft.com/en-us/rest/api/fabric/core/deployment-pipelines/list-deployment-pipelines
    $listDeploymentPipelinesResponse = Invoke-ApiEndpoint -endPoint $endPoint    
    if ($listDeploymentPipelinesResponse.responseObject.StatusCode -eq 200) {
        $deploymentPipeline = ($listDeploymentPipelinesResponse.responseObject.Content | ConvertFrom-Json).value | Where-Object {$_.displayName -eq $pipelineName}
        if ($null -eq $deploymentPipeline) {
            Write-Message "Action" "Creating new pipeline $($pipelineName) with $($stages.Count) stage(s)."
            $requestBody = @{
                displayName = $pipelineName
                description = $pipelineDescription
                stages      = @($stages)
            } | ConvertTo-Json -Depth 4
            $createDeploymentPipelineResponse = Invoke-ApiEndpoint -endPoint $endPoint -method "POST" -body $requestBody #https://learn.microsoft.com/en-us/rest/api/fabric/core/deployment-pipelines/create-deployment-pipeline            
            if ($createDeploymentPipelineResponse.responseObject.StatusCode -eq 201) {
                $deploymentPipeline = $createDeploymentPipelineResponse.responseObject.Content | ConvertFrom-Json
                Write-Message "Info" "Pipeline $pipelineName ($($deploymentPipeline.id)) was created."
                return $deploymentPipeline.id
            }
            else {
                throw (APIReturnedError -apiCallResponse $createDeploymentPipelineResponse -intendedAction "create a deployment pipeline")
            }
        }
        else {
            Write-Message "Info" "Pipeline $pipelineName ($($deploymentPipeline.id)) was found."
            return $deploymentPipeline.id
        }
    }
    else {
        throw (APIReturnedError -apiCallResponse $listDeploymentPipelinesResponse -intendedAction "list deployment pipelines")
    }
}

function Add-PipelineUsers {
    param (
        [parameter(Mandatory = $true)]  [String]             $deploymentPipelineId,
        [parameter(Mandatory = $true)]  [AllowEmptyString()] [String] $upnList,
        [parameter(Mandatory = $true)]  [String]             $deploymentPipelineAccessRight,
        [parameter(Mandatory = $false)] [bool]   $strictMode = $false
    )
    if ([string]::IsNullOrWhiteSpace($upnList)) { return }
    $upnArray = Resolve-NormalizedUpnList -upnList $upnList
    $failed = @()
    foreach ($upn in $upnArray) {
        $userOrGroup = Resolve-UpnToId -upn $upn -returnUpn $true
        if ($null -ne $userOrGroup) {
            $requestBody = @{
                identifier    = $userOrGroup.Id
                principalType = $userOrGroup.Type
                accessRight   = $deploymentPipelineAccessRight #Note. Currently only the value Admin is allowed, but more Access right will be added according to MSFT
            } | ConvertTo-Json -Depth 4
            $endPoint = "/pipelines/$($deploymentPipelineId)/users" #https://learn.microsoft.com/en-us/rest/api/power-bi/pipelines/update-pipeline-user
            $pipilineAccessRightAssignmentResponse = Invoke-ApiEndpoint -baseUrl $script:powerbiBaseUrl -endPoint $endPoint -method "POST" -body $requestBody
            if ($pipilineAccessRightAssignmentResponse.responseObject.StatusCode -eq 200) {
                Write-Message "Info" "Added UPN $($upn) as $($deploymentPipelineAccessRight) of the deployment pipeline."
            }
            else {
                if (@(401, 409) -contains $pipilineAccessRightAssignmentResponse.responseObject.StatusCode) {
                    Write-Message "Info" "User with UPN $($upn) is already assigned."
                }
                else {
                    throw (APIReturnedError -apiCallResponse $pipilineAccessRightAssignmentResponse -intendedAction "assign user to piepline")
                }
            }
        } else {
            $failed += $upn
        }
    }
    if ($failed.Count -gt 0) {
        $message = "Could not resolve the following UPNs for pipeline role '$($deploymentPipelineAccessRight)': $($failed -join ', ')"
        if ($strictMode) { throw $message }
        else             { Write-Message "Warning" $message }
    }
}

function Publish-PipelineStage {
    param (
        [parameter(Mandatory = $true)] [String] $deploymentPipelineId,
        [parameter(Mandatory = $true)] [int] $environmentCnt
    )
    for ($index = 0; $index -lt $environmentCnt - 1; $index++) {
        Publish-PipelineStageByOrder -deploymentPipelineId $deploymentPipelineId -stageOrder $index
    }
}

function Set-PipelineStageWorkspace {
    param (
        [parameter(Mandatory = $true)] [String] $deploymentPipelineId,
        [parameter(Mandatory = $true)] [int] $orderIndex,
        [parameter(Mandatory = $true)] [String] $workspaceId
    )

    $endPoint = "/deploymentPipelines/$($deploymentPipelineId)/stages" #https://learn.microsoft.com/en-us/rest/api/fabric/core/deployment-pipelines/list-deployment-pipeline-stages
    $deploymentPipelineStagesResponse = Invoke-ApiEndpoint -endPoint $endPoint
    if ($deploymentPipelineStagesResponse.responseObject.StatusCode -eq 200) {
        $deploymentPipelineStage = ($deploymentPipelineStagesResponse.responseObject.Content | ConvertFrom-Json).value | Where-Object {($_.order -eq $orderIndex)}
        if($null -ne $deploymentPipelineStage) {
            $workspaceAssignedToStage = $deploymentPipelineStage.workspaceId
            if ([string]::IsNullOrWhiteSpace($workspaceAssignedToStage)) {
                $requestBody = @{
                    workspaceId = $workspaceId
                } | ConvertTo-Json -Depth 4
                $endPoint = "/deploymentPipelines/$($deploymentPipelineId)/stages/$($deploymentPipelineStage.id)/assignWorkspace" #https://learn.microsoft.com/en-us/rest/api/fabric/core/deployment-pipelines/assign-workspace-to-stage
                $assignWorkspaceResponse = Invoke-ApiEndpoint -endPoint $endPoint -method "POST" -body $requestBody
                if ($assignWorkspaceResponse.responseObject.StatusCode -eq 200) {
                    Write-Message "Info" "Workspace successfully assigned."
                }
                else {
                    throw (APIReturnedError -apiCallResponse $assignWorkspaceResponse -intendedAction "assign workspace to deployment pipeline stage")
                }
            }
            else {
                Write-Message "Info" "Stage (order $($orderIndex)) already has workspace '$($workspaceAssignedToStage)' assigned - skipping."
            }
        }
        else {
            throw "Pipeline stage index $($orderIndex) was not found."
        }
    }
    else {
        throw (APIReturnedError -apiCallResponse $deploymentPipelineStagesResponse -intendedAction "list deployment pipeline stages")
    }
}

function Get-DeploymentPipeline {
    param (
        [parameter(Mandatory = $true)] [String] $deploymentPipelineName
    )
    $endPoint = "/deploymentPipelines" #https://learn.microsoft.com/en-us/rest/api/fabric/core/deployment-pipelines/list-deployment-pipelines
    $deploymentPipelinesResponse = Invoke-ApiEndpoint -endPoint $endPoint
    if ($deploymentPipelinesResponse.responseObject.StatusCode -eq 200) {
        return ($deploymentPipelinesResponse.responseObject.Content | ConvertFrom-Json).value | Where-Object {$_.displayName -eq $deploymentPipelineName}
    }
    else {
        throw (APIReturnedError -apiCallResponse $deploymentPipelinesResponse -intendedAction "get deployment pipeline by name")
    }
}

function Get-PipelineStages {
    param (
        [parameter(Mandatory = $true)] [String] $deploymentPipelineId
    )
    $endPoint = "/deploymentPipelines/$($deploymentPipelineId)/stages" #https://learn.microsoft.com/en-us/rest/api/fabric/core/deployment-pipelines/list-deployment-pipeline-stages
    $response = Invoke-ApiEndpoint -endPoint $endPoint
    if ($response.responseObject.StatusCode -eq 200) {
        return ($response.responseObject.Content | ConvertFrom-Json).value | Sort-Object order
    }
    else {
        throw (APIReturnedError -apiCallResponse $response -intendedAction "list deployment pipeline stages")
    }
}

function Get-PipelineStageItems {
    param (
        [parameter(Mandatory = $true)] [String] $deploymentPipelineId,
        [parameter(Mandatory = $true)] [String] $stageId
    )
    $endPoint = "/deploymentPipelines/$($deploymentPipelineId)/stages/$($stageId)/items" #https://learn.microsoft.com/en-us/rest/api/fabric/core/deployment-pipelines/list-deployment-pipeline-stage-items
    $response = Invoke-ApiEndpoint -endPoint $endPoint
    if ($response.responseObject.StatusCode -eq 200) {
        return ($response.responseObject.Content | ConvertFrom-Json).value
    }
    else {
        throw (APIReturnedError -apiCallResponse $response -intendedAction "list deployment pipeline stage items")
    }
}

function Publish-PipelineStageByOrder {
    param (
        [parameter(Mandatory = $true)] [String] $deploymentPipelineId,
        [parameter(Mandatory = $true)] [int] $stageOrder
    )

    $endPoint = "/deploymentPipelines/$($deploymentPipelineId)/stages" #https://learn.microsoft.com/en-us/rest/api/fabric/core/deployment-pipelines/list-deployment-pipeline-stages
    $deploymentPipelineStagesResponse = Invoke-ApiEndpoint -endPoint $endPoint
    if ($deploymentPipelineStagesResponse.responseObject.StatusCode -eq 200) {
        $sourceStageId = ($deploymentPipelineStagesResponse.responseObject.Content | ConvertFrom-Json).value | Where-Object {$_.order -eq $stageOrder}
        $targetStageId = ($deploymentPipelineStagesResponse.responseObject.Content | ConvertFrom-Json).value | Where-Object {$_.order -eq ($stageOrder+1)}
        $sourceItems = Get-PipelineStageItems -deploymentPipelineId $deploymentPipelineId -stageId $sourceStageId.id
        $targetItems = Get-PipelineStageItems -deploymentPipelineId $deploymentPipelineId -stageId $targetStageId.id
        if (($null -eq $sourceItems -or @($sourceItems).Count -eq 0) -and
            ($null -eq $targetItems -or @($targetItems).Count -eq 0)) {
            Write-Message "Warning" "Stage $($stageOrder) and stage $($stageOrder + 1) both have no items - skipping deployment."
            return
        }
        $requestBody = @{
            sourceStageId = $sourceStageId.id
            targetStageId = $targetStageId.id
            note = "Deploy"
        } | ConvertTo-Json -Depth 4
            
        $endPoint = "/deploymentPipelines/$($deploymentPipelineId)/deploy" #https://learn.microsoft.com/en-us/rest/api/fabric/core/deployment-pipelines/deploy-stage-content
        #This endPoint supports long running operations (LRO).
        $deploymentPipelineStageResponse = Invoke-ApiEndpoint -endPoint $endPoint -method "POST" -body $requestBody
        if ($deploymentPipelineStageResponse.isException) {
            throw (APIReturnedError -apiCallResponse $deploymentPipelineStageResponse -intendedAction "deploy stage content")
        }
        elseif ($deploymentPipelineStageResponse.isException -eq $false -and $deploymentPipelineStageResponse.responseObject.StatusCode -eq 202) {
            $operationId  = [string]($deploymentPipelineStageResponse.responseObject.Headers.'x-ms-operation-id' | Select-Object -First 1)
            $retryInterval = [int]($deploymentPipelineStageResponse.responseObject.Headers.'Retry-After' | Select-Object -First 1)
            Write-Message "Info" "Request accepted (operation id $($operationId)), deployment in progress."
            Wait-FabricLRO -operationId $operationId -retryInterval $retryInterval | Out-Null
            Write-Message "Info" "Stage $($stageOrder) > $($stageOrder+1) has been deployed successfully"
        }
        else {
            Write-Message "Info" "Stage $($stageOrder) > $($stageOrder+1) has been deployed successfully"
        }
    }
    else {
        throw (APIReturnedError -apiCallResponse $deploymentPipelineStagesResponse -intendedAction "list deployment pipeline stages")
    }
}