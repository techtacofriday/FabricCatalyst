###############################################################################
# Tests: PipelineFunctions.ps1
#
# Run all tests:
#   powershell -NoProfile -File .\tasks\shared\tests\Invoke-Tests.ps1
#
# Run only these:
#   powershell -NoProfile -File .\tasks\shared\tests\Invoke-Tests.ps1 -Filter 'New-DeploymentPipeline'
#
# Requires Pester 5+
###############################################################################
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    . "$PSScriptRoot\..\private\SharedFunctions.ps1"
    . "$PSScriptRoot\..\private\PipelineFunctions.ps1"
}

# =============================================================================
Describe 'New-DeploymentPipeline' {

    BeforeAll {
        Mock Write-Message   { }
        Mock APIReturnedError { return "mocked API error: $intendedAction" }
    }

    BeforeEach {
        $testStages = @(
            [PSCustomObject]@{ displayName = 'dev'; isPublic = $false }
            [PSCustomObject]@{ displayName = 'uat'; isPublic = $false }
        )
    }

    Context 'pipeline already exists' {
        BeforeEach {
            Mock Invoke-ApiEndpoint {
                $content = '{"value":[{"id":"pipe-existing-111","displayName":"pl_MyPipeline"}]}'
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 200; Content = $content }
                    isException    = $false
                }
            }
        }

        It 'returns the existing pipeline ID without making a POST call' {
            $result = New-DeploymentPipeline -pipelineName 'pl_MyPipeline' -pipelineDescription 'desc' -stages $testStages
            $result | Should -Be 'pipe-existing-111'
            Should -Invoke Invoke-ApiEndpoint -Exactly 1
        }
    }

    Context 'pipeline does not exist - create succeeds' {
        BeforeEach {
            Mock Invoke-ApiEndpoint {
                if ($method -eq 'POST') {
                    $content = '{"id":"pipe-new-abc","displayName":"pl_NewPipeline"}'
                    return [PSCustomObject]@{
                        responseObject = [PSCustomObject]@{ StatusCode = 201; Content = $content }
                        isException    = $false
                    }
                }
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}' }
                    isException    = $false
                }
            }
        }

        It 'calls POST to /deploymentPipelines when pipeline is not found' {
            New-DeploymentPipeline -pipelineName 'pl_NewPipeline' -pipelineDescription 'desc' -stages $testStages
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter { $method -eq 'POST' } -Exactly 1
        }

        It 'includes displayName in the POST body' {
            New-DeploymentPipeline -pipelineName 'pl_NewPipeline' -pipelineDescription 'desc' -stages $testStages
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter {
                $method -eq 'POST' -and ($body | ConvertFrom-Json).displayName -eq 'pl_NewPipeline'
            }
        }

        It 'includes the stages array in the POST body' {
            New-DeploymentPipeline -pipelineName 'pl_NewPipeline' -pipelineDescription 'desc' -stages $testStages
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter {
                $method -eq 'POST' -and ($body | ConvertFrom-Json).stages.Count -eq 2
            }
        }

        It 'preserves stage displayNames in the POST body' {
            New-DeploymentPipeline -pipelineName 'pl_NewPipeline' -pipelineDescription 'desc' -stages $testStages
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter {
                $method -eq 'POST' -and ($body | ConvertFrom-Json).stages[0].displayName -eq 'dev'
            }
        }

        It 'returns the new pipeline ID from the 201 response' {
            $result = New-DeploymentPipeline -pipelineName 'pl_NewPipeline' -pipelineDescription 'desc' -stages $testStages
            $result | Should -Be 'pipe-new-abc'
        }
    }

    Context 'create fails (400)' {
        BeforeEach {
            Mock Invoke-ApiEndpoint {
                if ($method -eq 'POST') {
                    return [PSCustomObject]@{
                        responseObject = [PSCustomObject]@{ StatusCode = 400; Content = '{"errorCode":"InvalidInput","message":"Error validating parameters"}' }
                        isException    = $false
                    }
                }
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}' }
                    isException    = $false
                }
            }
        }

        It 'throws when the create call returns 400' {
            { New-DeploymentPipeline -pipelineName 'pl_Conflict' -pipelineDescription 'desc' -stages $testStages } |
                Should -Throw
        }
    }

    Context 'list call fails' {
        BeforeEach {
            Mock Invoke-ApiEndpoint {
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 500; Content = '{}' }
                    isException    = $false
                }
            }
        }

        It 'throws when the list pipelines call returns a non-200 status' {
            { New-DeploymentPipeline -pipelineName 'pl_Any' -pipelineDescription 'desc' -stages $testStages } |
                Should -Throw
        }
    }
}

# =============================================================================
Describe 'Set-PipelineStageWorkspace' {

    BeforeAll {
        Mock Write-Message   { }
        Mock APIReturnedError { return "mocked API error: $intendedAction" }
    }

    Context 'stage found and workspace not yet assigned' {
        BeforeEach {
            Mock Invoke-ApiEndpoint {
                if ($endPoint -like '*/stages' ) {
                    $content = '{"value":[{"id":"stage-aaa","order":0,"workspaceId":null},{"id":"stage-bbb","order":1,"workspaceId":null}]}'
                    return [PSCustomObject]@{
                        responseObject = [PSCustomObject]@{ StatusCode = 200; Content = $content }
                        isException    = $false
                    }
                }
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 200; Content = '{}' }
                    isException    = $false
                }
            }
        }

        It 'uses the stage id (not order) in the assignWorkspace endpoint URL' {
            Set-PipelineStageWorkspace -deploymentPipelineId 'pipe-001' -orderIndex 0 -workspaceId 'ws-111'
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter {
                $endPoint -like '*/stages/stage-aaa/assignWorkspace'
            }
        }

        It 'sends the workspaceId in the POST body' {
            Set-PipelineStageWorkspace -deploymentPipelineId 'pipe-001' -orderIndex 0 -workspaceId 'ws-111'
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter {
                $method -eq 'POST' -and ($body | ConvertFrom-Json).workspaceId -eq 'ws-111'
            }
        }

        It 'assigns the correct stage when orderIndex is 1' {
            Set-PipelineStageWorkspace -deploymentPipelineId 'pipe-001' -orderIndex 1 -workspaceId 'ws-222'
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter {
                $endPoint -like '*/stages/stage-bbb/assignWorkspace'
            }
        }
    }

    Context 'stage already has a workspace assigned' {
        BeforeEach {
            Mock Invoke-ApiEndpoint {
                $content = '{"value":[{"id":"stage-aaa","order":0,"workspaceId":"ws-already-assigned"}]}'
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 200; Content = $content }
                    isException    = $false
                }
            }
        }

        It 'skips the assign call when workspace is already assigned' {
            Set-PipelineStageWorkspace -deploymentPipelineId 'pipe-001' -orderIndex 0 -workspaceId 'ws-new'
            Should -Invoke Invoke-ApiEndpoint -Exactly 1
        }
    }

    Context 'stage not found' {
        BeforeEach {
            Mock Invoke-ApiEndpoint {
                $content = '{"value":[{"id":"stage-aaa","order":0,"workspaceId":null}]}'
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 200; Content = $content }
                    isException    = $false
                }
            }
        }

        It 'throws when orderIndex has no matching stage' {
            { Set-PipelineStageWorkspace -deploymentPipelineId 'pipe-001' -orderIndex 99 -workspaceId 'ws-111' } |
                Should -Throw -ExpectedMessage '*99*not found*'
        }
    }

    Context 'list stages call fails' {
        BeforeEach {
            Mock Invoke-ApiEndpoint {
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 500; Content = '{}' }
                    isException    = $false
                }
            }
        }

        It 'throws when list stages returns a non-200 status' {
            { Set-PipelineStageWorkspace -deploymentPipelineId 'pipe-001' -orderIndex 0 -workspaceId 'ws-111' } |
                Should -Throw
        }
    }
}

# =============================================================================
Describe 'Get-DeploymentPipeline' {

    BeforeAll {
        Mock Write-Message   { }
        Mock APIReturnedError { return "mocked API error: $intendedAction" }
    }

    Context 'pipeline found' {
        BeforeEach {
            Mock Invoke-ApiEndpoint {
                $content = '{"value":[{"id":"pipe-xyz","displayName":"pl_Target"},{"id":"pipe-other","displayName":"pl_Other"}]}'
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 200; Content = $content }
                    isException    = $false
                }
            }
        }

        It 'returns the pipeline object whose displayName matches' {
            $result = Get-DeploymentPipeline -deploymentPipelineName 'pl_Target'
            $result.id | Should -Be 'pipe-xyz'
        }

        It 'does not return pipelines whose displayName does not match' {
            $result = Get-DeploymentPipeline -deploymentPipelineName 'pl_Target'
            @($result) | Should -HaveCount 1
        }
    }

    Context 'pipeline not found' {
        BeforeEach {
            Mock Invoke-ApiEndpoint {
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}' }
                    isException    = $false
                }
            }
        }

        It 'returns null when no pipeline matches the name' {
            $result = Get-DeploymentPipeline -deploymentPipelineName 'pl_DoesNotExist'
            $result | Should -BeNullOrEmpty
        }
    }

    Context 'list call fails' {
        BeforeEach {
            Mock Invoke-ApiEndpoint {
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 403; Content = '{}' }
                    isException    = $false
                }
            }
        }

        It 'throws when the list call returns a non-200 status' {
            { Get-DeploymentPipeline -deploymentPipelineName 'pl_Any' } | Should -Throw
        }
    }
}

# =============================================================================
Describe 'Get-PipelineStages' {

    BeforeAll {
        Mock Write-Message   { }
        Mock APIReturnedError { return "mocked API error: $intendedAction" }
    }

    Context 'stages returned successfully' {
        BeforeEach {
            Mock Invoke-ApiEndpoint {
                $content = '{"value":[{"id":"stage-s2","order":2,"displayName":"prod"},{"id":"stage-s0","order":0,"displayName":"dev"},{"id":"stage-s1","order":1,"displayName":"uat"}]}'
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 200; Content = $content }
                    isException    = $false
                }
            }
        }

        It 'returns all stages' {
            $result = Get-PipelineStages -deploymentPipelineId 'pipe-001'
            @($result) | Should -HaveCount 3
        }

        It 'sorts stages by order ascending' {
            $result = Get-PipelineStages -deploymentPipelineId 'pipe-001'
            $result[0].order | Should -Be 0
            $result[1].order | Should -Be 1
            $result[2].order | Should -Be 2
        }

        It 'preserves displayName on each stage' {
            $result = Get-PipelineStages -deploymentPipelineId 'pipe-001'
            $result[0].displayName | Should -Be 'dev'
            $result[2].displayName | Should -Be 'prod'
        }

        It 'calls the correct stages endpoint' {
            Get-PipelineStages -deploymentPipelineId 'pipe-001'
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter {
                $endPoint -like '*/pipe-001/stages'
            }
        }
    }

    Context 'API call fails' {
        BeforeEach {
            Mock Invoke-ApiEndpoint {
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 403; Content = '{}' }
                    isException    = $false
                }
            }
        }

        It 'throws when the list stages call returns a non-200 status' {
            { Get-PipelineStages -deploymentPipelineId 'pipe-001' } | Should -Throw
        }
    }
}

# =============================================================================
Describe 'Get-PipelineStageItems' {

    BeforeAll {
        Mock Write-Message   { }
        Mock APIReturnedError { return "mocked API error: $intendedAction" }
    }

    Context 'items returned successfully' {
        BeforeEach {
            Mock Invoke-ApiEndpoint {
                $content = '{"value":[{"id":"item-001","type":"Notebook","displayName":"MyNotebook"},{"id":"item-002","type":"Lakehouse","displayName":"MyLakehouse"}]}'
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 200; Content = $content }
                    isException    = $false
                }
            }
        }

        It 'returns all items' {
            $result = Get-PipelineStageItems -deploymentPipelineId 'pipe-001' -stageId 'stage-aaa'
            @($result) | Should -HaveCount 2
        }

        It 'calls the correct stage items endpoint' {
            Get-PipelineStageItems -deploymentPipelineId 'pipe-001' -stageId 'stage-aaa'
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter {
                $endPoint -like '*/pipe-001/stages/stage-aaa/items'
            }
        }
    }

    Context 'stage has no items' {
        BeforeEach {
            Mock Invoke-ApiEndpoint {
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}' }
                    isException    = $false
                }
            }
        }

        It 'returns an empty collection when the stage has no items' {
            $result = Get-PipelineStageItems -deploymentPipelineId 'pipe-001' -stageId 'stage-aaa'
            @($result) | Should -HaveCount 0
        }
    }

    Context 'API call fails' {
        BeforeEach {
            Mock Invoke-ApiEndpoint {
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 403; Content = '{}' }
                    isException    = $false
                }
            }
        }

        It 'throws when the list items call returns a non-200 status' {
            { Get-PipelineStageItems -deploymentPipelineId 'pipe-001' -stageId 'stage-aaa' } | Should -Throw
        }
    }
}

# =============================================================================
Describe 'Publish-PipelineStageByOrder' {

    BeforeAll {
        Mock Write-Message          { }
        Mock Wait-FabricLRO         { }
        Mock APIReturnedError        { return "mocked API error: $intendedAction" }
        Mock Get-PipelineStageItems  { return @([PSCustomObject]@{ id = 'item-001'; type = 'Notebook' }) }
    }

    BeforeEach {
        $stagesContent = '{"value":[{"id":"stage-s0","order":0},{"id":"stage-s1","order":1},{"id":"stage-s2","order":2}]}'
        Mock Invoke-ApiEndpoint {
            if ($endPoint -like '*/stages') {
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 200; Content = $stagesContent }
                    isException    = $false
                }
            }
            return [PSCustomObject]@{
                responseObject = [PSCustomObject]@{ StatusCode = 200; Content = '{}' }
                isException    = $false
            }
        }
    }

    Context 'deploy endpoint and body' {
        It 'calls the /deploy endpoint with the correct source and target stage IDs' {
            Publish-PipelineStageByOrder -deploymentPipelineId 'pipe-001' -stageOrder 0
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter {
                $endPoint -like '*/pipe-001/deploy' -and
                ($body | ConvertFrom-Json).sourceStageId -eq 'stage-s0' -and
                ($body | ConvertFrom-Json).targetStageId -eq 'stage-s1'
            }
        }

        It 'uses the next stage as target when deploying from stage 1' {
            Publish-PipelineStageByOrder -deploymentPipelineId 'pipe-001' -stageOrder 1
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter {
                $endPoint -like '*/pipe-001/deploy' -and
                ($body | ConvertFrom-Json).sourceStageId -eq 'stage-s1' -and
                ($body | ConvertFrom-Json).targetStageId -eq 'stage-s2'
            }
        }
    }

    Context 'LRO (202 response)' {
        BeforeEach {
            Mock Invoke-ApiEndpoint {
                if ($endPoint -like '*/stages') {
                    return [PSCustomObject]@{
                        responseObject = [PSCustomObject]@{ StatusCode = 200; Content = $stagesContent }
                        isException    = $false
                    }
                }
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{
                        StatusCode = 202
                        Content    = '{}'
                        Headers    = @{ 'x-ms-operation-id' = 'op-lro-abc'; 'Retry-After' = '5' }
                    }
                    isException    = $false
                }
            }
        }

        It 'calls Wait-FabricLRO with the operation ID from the 202 response' {
            Publish-PipelineStageByOrder -deploymentPipelineId 'pipe-001' -stageOrder 0
            Should -Invoke Wait-FabricLRO -ParameterFilter { $operationId -eq 'op-lro-abc' }
        }
    }

    Context 'API exception response' {
        BeforeEach {
            Mock Invoke-ApiEndpoint {
                if ($endPoint -like '*/stages') {
                    return [PSCustomObject]@{
                        responseObject = [PSCustomObject]@{ StatusCode = 200; Content = $stagesContent }
                        isException    = $false
                    }
                }
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 500; Content = '{}' }
                    isException    = $true
                }
            }
        }

        It 'throws when isException is true on the deploy response' {
            { Publish-PipelineStageByOrder -deploymentPipelineId 'pipe-001' -stageOrder 0 } |
                Should -Throw
        }
    }

    Context 'both stages have no items' {
        BeforeEach {
            Mock Get-PipelineStageItems { return @() }
        }

        It 'does not call the deploy endpoint when both stages are empty' {
            Publish-PipelineStageByOrder -deploymentPipelineId 'pipe-001' -stageOrder 0
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter { $endPoint -like '*/deploy' } -Exactly 0
        }

        It 'emits a warning message when both stages are empty' {
            Publish-PipelineStageByOrder -deploymentPipelineId 'pipe-001' -stageOrder 0
            Should -Invoke Write-Message -ParameterFilter { $msgType -eq 'Warning' }
        }
    }

    Context 'source is empty but target still has items' {
        BeforeEach {
            Mock Get-PipelineStageItems {
                if ($stageId -eq 'stage-s0') { return @() }
                return @([PSCustomObject]@{ id = 'item-001'; type = 'Notebook' })
            }
        }

        It 'still calls the deploy endpoint when source is empty but target has items' {
            Publish-PipelineStageByOrder -deploymentPipelineId 'pipe-001' -stageOrder 0
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter { $endPoint -like '*/deploy' } -Exactly 1
        }
    }
}

# =============================================================================
Describe 'Add-PipelineUsers' {

    BeforeAll {
        Mock Write-Message   { }
        Mock APIReturnedError { return "mocked API error: $intendedAction" }
        Mock Resolve-UpnToId { return [PSCustomObject]@{ Id = 'user-guid-111'; Type = 'User' } }
    }

    BeforeEach {
        Mock Invoke-ApiEndpoint {
            return [PSCustomObject]@{
                responseObject = [PSCustomObject]@{ StatusCode = 200; Content = '{}' }
                isException    = $false
            }
        }
    }

    Context 'empty UPN list' {
        It 'returns without making any API call when upnList is empty' {
            Add-PipelineUsers -deploymentPipelineId 'pipe-001' -upnList '' -deploymentPipelineAccessRight 'Admin'
            Should -Invoke Invoke-ApiEndpoint -Exactly 0
        }

        It 'returns without making any API call when upnList is whitespace' {
            Add-PipelineUsers -deploymentPipelineId 'pipe-001' -upnList '   ' -deploymentPipelineAccessRight 'Admin'
            Should -Invoke Invoke-ApiEndpoint -Exactly 0
        }
    }

    Context 'user successfully resolved and added' {
        It 'calls the pipeline users endpoint for each resolved UPN' {
            Add-PipelineUsers -deploymentPipelineId 'pipe-001' -upnList 'user@contoso.com' -deploymentPipelineAccessRight 'Admin'
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter {
                $endPoint -like '*/pipe-001/users' -and $method -eq 'POST'
            } -Exactly 1
        }

        It 'includes the resolved user ID and access right in the POST body' {
            Add-PipelineUsers -deploymentPipelineId 'pipe-001' -upnList 'user@contoso.com' -deploymentPipelineAccessRight 'Admin'
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter {
                $method -eq 'POST' -and
                ($body | ConvertFrom-Json).identifier  -eq 'user-guid-111' -and
                ($body | ConvertFrom-Json).accessRight -eq 'Admin'
            }
        }

        It 'makes one API call per UPN when multiple UPNs are provided' {
            Add-PipelineUsers -deploymentPipelineId 'pipe-001' -upnList 'a@x.com;b@x.com' -deploymentPipelineAccessRight 'Admin'
            Should -Invoke Invoke-ApiEndpoint -Exactly 2
        }
    }

    Context 'user already assigned (409)' {
        BeforeEach {
            Mock Invoke-ApiEndpoint {
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 409; Content = '{}' }
                    isException    = $false
                }
            }
        }

        It 'does not throw when the API returns 409' {
            { Add-PipelineUsers -deploymentPipelineId 'pipe-001' -upnList 'user@contoso.com' -deploymentPipelineAccessRight 'Admin' } |
                Should -Not -Throw
        }
    }

    Context 'UPN resolution fails' {
        BeforeEach {
            Mock Resolve-UpnToId { return $null }
        }

        It 'does not throw in default mode when a UPN cannot be resolved' {
            { Add-PipelineUsers -deploymentPipelineId 'pipe-001' -upnList 'ghost@contoso.com' -deploymentPipelineAccessRight 'Admin' } |
                Should -Not -Throw
        }

        It 'throws in strictMode when a UPN cannot be resolved' {
            { Add-PipelineUsers -deploymentPipelineId 'pipe-001' -upnList 'ghost@contoso.com' -deploymentPipelineAccessRight 'Admin' -strictMode $true } |
                Should -Throw -ExpectedMessage '*ghost@contoso.com*'
        }
    }
}
