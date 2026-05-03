###############################################################################
# Tests: Invoke-ApiEndpoint — response-shaping logic and Invoke-FabricApiRequest seam
#
# These tests NEVER call Invoke-WebRequest. Invoke-FabricApiRequest is mocked
# to return canned responses so the logic inside Invoke-ApiEndpoint can be verified
# in isolation.
###############################################################################
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    . "$PSScriptRoot\..\private\SharedFunctions.ps1"

    # Populate the script-scoped variables that Invoke-ApiEndpoint reads
    $script:fabricBaseUrl       = 'https://api.fabric.microsoft.com'
    $script:azdoBaseUrl         = 'https://dev.azure.com'
    $script:graphBaseUrl        = 'https://graph.microsoft.com/v1.0'
    $script:fabricRequestHeader = @{ Authorization = 'Bearer fabric-token' }
    $script:devopsRequestHeader = @{ Authorization = 'Bearer devops-token' }
    $script:graphRequestHeader  = @{ Authorization = 'Bearer graph-token' }
    $script:enableDiagnostics   = 'False'
    $script:developerView       = $false

    # Silence all Write-Message calls so test output stays clean
    Mock Write-Message { }

    # ---------------------------------------------------------------------------
    # Helper: build the PSCustomObject that Invoke-FabricApiRequest would normally
    # return from Invoke-WebRequest.  Mirrors the properties Invoke-ApiEndpoint reads:
    # .StatusCode, .Content, .Headers
    # ---------------------------------------------------------------------------
    function New-MockHttpResponse {
        param(
            [int]    $StatusCode = 200,
            [string] $Content    = '{}',
            [hashtable] $Headers = @{}
        )
        return [PSCustomObject]@{
            StatusCode = $StatusCode
            Content    = $Content
            Headers    = $Headers
        }
    }
}

# =============================================================================
Describe 'Invoke-ApiEndpoint — response shaping' {

    Context '200 success — plain JSON body' {
        BeforeEach {
            Mock Invoke-FabricApiRequest {
                New-MockHttpResponse -StatusCode 200 -Content '{"id":"ws-123","displayName":"MyWorkspace"}'
            }
        }

        It 'returns isException = false' {
            $result = Invoke-ApiEndpoint -endPoint '/workspaces'
            $result.isException | Should -Be $false
        }

        It 'exposes StatusCode on responseObject' {
            $result = Invoke-ApiEndpoint -endPoint '/workspaces'
            $result.responseObject.StatusCode | Should -Be 200
        }

        It 'exposes the raw Content string on responseObject' {
            $result = Invoke-ApiEndpoint -endPoint '/workspaces'
            $result.responseObject.Content | Should -Match '"id":"ws-123"'
        }

        It 'exposes Headers on responseObject' {
            Mock Invoke-FabricApiRequest {
                New-MockHttpResponse -StatusCode 200 -Content '{}' -Headers @{ 'Content-Type' = 'application/json' }
            }
            $result = Invoke-ApiEndpoint -endPoint '/workspaces'
            $result.responseObject.Headers['Content-Type'] | Should -Be 'application/json'
        }
    }

    Context '201 created — POST response' {
        BeforeEach {
            Mock Invoke-FabricApiRequest {
                New-MockHttpResponse -StatusCode 201 -Content '{"id":"item-456"}'
            }
        }

        It 'returns isException = false for 201' {
            $result = Invoke-ApiEndpoint -endPoint '/workspaces' -method 'POST' -body '{}'
            $result.isException | Should -Be $false
        }

        It 'exposes StatusCode 201 on responseObject' {
            $result = Invoke-ApiEndpoint -endPoint '/workspaces' -method 'POST' -body '{}'
            $result.responseObject.StatusCode | Should -Be 201
        }
    }

    Context '202 LRO — operation-id and retry headers preserved' {
        BeforeEach {
            Mock Invoke-FabricApiRequest {
                New-MockHttpResponse -StatusCode 202 -Content '{}' -Headers @{
                    'x-ms-operation-id' = 'op-abc-123'
                    'Retry-After'       = '5'
                }
            }
        }

        It 'returns isException = false for 202' {
            $result = Invoke-ApiEndpoint -endPoint '/workspaces' -method 'POST' -body '{}'
            $result.isException | Should -Be $false
        }

        It 'passes the operation-id header through to the caller' {
            $result = Invoke-ApiEndpoint -endPoint '/workspaces' -method 'POST' -body '{}'
            $result.responseObject.Headers['x-ms-operation-id'] | Should -Be 'op-abc-123'
        }

        It 'passes the Retry-After header through to the caller' {
            $result = Invoke-ApiEndpoint -endPoint '/workspaces' -method 'POST' -body '{}'
            $result.responseObject.Headers['Retry-After'] | Should -Be '5'
        }
    }

    Context 'API-level error — errorCode present in response body' {
        BeforeEach {
            Mock Invoke-FabricApiRequest {
                New-MockHttpResponse -StatusCode 400 `
                    -Content '{"errorCode":"InvalidRequest","message":"Workspace name is invalid."}'
            }
        }

        It 'returns isException = true' {
            $result = Invoke-ApiEndpoint -endPoint '/workspaces' -method 'POST' -body '{}'
            $result.isException | Should -Be $true
        }

        It 'surfaces the error message on responseObject' {
            $result = Invoke-ApiEndpoint -endPoint '/workspaces' -method 'POST' -body '{}'
            $result.responseObject.Message | Should -Be 'Workspace name is invalid.'
        }

        It 'surfaces the errorCode on responseObject' {
            $result = Invoke-ApiEndpoint -endPoint '/workspaces' -method 'POST' -body '{}'
            $result.responseObject.ErrorCode | Should -Be 'InvalidRequest'
        }

        It 'preserves the original StatusCode on responseObject' {
            $result = Invoke-ApiEndpoint -endPoint '/workspaces' -method 'POST' -body '{}'
            $result.responseObject.StatusCode | Should -Be 400
        }
    }

    Context 'Non-HTTP exception — Invoke-FabricApiRequest throws' {
        BeforeEach {
            Mock Invoke-FabricApiRequest { throw 'Connection refused by host' }
        }

        It 'returns isException = true instead of propagating the throw' {
            $result = Invoke-ApiEndpoint -endPoint '/workspaces'
            $result.isException | Should -Be $true
        }

        It 'sets StatusCode to Unknown' {
            $result = Invoke-ApiEndpoint -endPoint '/workspaces'
            $result.responseObject.StatusCode | Should -Be 'Unknown'
        }

        It 'sets ErrorCode to non-HTTP exception' {
            $result = Invoke-ApiEndpoint -endPoint '/workspaces'
            $result.responseObject.ErrorCode | Should -Be 'non-HTTP exception'
        }

        It 'captures the exception message' {
            $result = Invoke-ApiEndpoint -endPoint '/workspaces'
            $result.responseObject.Message | Should -Match 'Connection refused'
        }
    }
}

# =============================================================================
Describe 'Invoke-ApiEndpoint — URI construction' {

    BeforeAll {
        Mock Invoke-FabricApiRequest { New-MockHttpResponse }
    }

    It 'injects the default API version (v1) between base URL and endpoint' {
        Invoke-ApiEndpoint -endPoint '/workspaces' | Out-Null
        Should -Invoke Invoke-FabricApiRequest -Times 1 -ParameterFilter {
            $Uri -eq 'https://api.fabric.microsoft.com/v1/workspaces'
        }
    }

    It 'uses the supplied FabricApiVersion when specified' {
        Invoke-ApiEndpoint -endPoint '/workspaces' -FabricApiVersion 'v2' | Out-Null
        Should -Invoke Invoke-FabricApiRequest -Times 1 -ParameterFilter {
            $Uri -eq 'https://api.fabric.microsoft.com/v2/workspaces'
        }
    }

    It 'uses the supplied baseUrl as-is without injecting the API version' {
        Invoke-ApiEndpoint -baseUrl 'https://dev.azure.com' -endPoint '/my-org/my-proj/_apis/pipelines' | Out-Null
        Should -Invoke Invoke-FabricApiRequest -Times 1 -ParameterFilter {
            $Uri -eq 'https://dev.azure.com/my-org/my-proj/_apis/pipelines'
        }
    }
}

# =============================================================================
Describe 'Invoke-ApiEndpoint — request header routing' {

    BeforeAll {
        Mock Invoke-FabricApiRequest { New-MockHttpResponse }
    }

    It 'passes fabricRequestHeader when useRequestHeader = Fabric (default)' {
        Invoke-ApiEndpoint -endPoint '/workspaces' | Out-Null
        Should -Invoke Invoke-FabricApiRequest -Times 1 -ParameterFilter {
            $Headers.Authorization -eq 'Bearer fabric-token'
        }
    }

    It 'passes devopsRequestHeader when useRequestHeader = DevOps' {
        Invoke-ApiEndpoint -useRequestHeader 'DevOps' -baseUrl 'https://dev.azure.com' -endPoint '/org/proj/_apis/pipelines' | Out-Null
        Should -Invoke Invoke-FabricApiRequest -Times 1 -ParameterFilter {
            $Headers.Authorization -eq 'Bearer devops-token'
        }
    }

    It 'passes graphRequestHeader when useRequestHeader = Graph' {
        Invoke-ApiEndpoint -useRequestHeader 'Graph' -baseUrl 'https://graph.microsoft.com/v1.0' -endPoint '/users/me' | Out-Null
        Should -Invoke Invoke-FabricApiRequest -Times 1 -ParameterFilter {
            $Headers.Authorization -eq 'Bearer graph-token'
        }
    }
}

# =============================================================================
Describe 'Invoke-ApiEndpoint — HTTP method forwarding' {

    BeforeAll {
        Mock Invoke-FabricApiRequest { New-MockHttpResponse }
    }

    It 'forwards GET method' {
        Invoke-ApiEndpoint -endPoint '/workspaces' -method 'GET' | Out-Null
        Should -Invoke Invoke-FabricApiRequest -Times 1 -ParameterFilter { $Method -eq 'GET' }
    }

    It 'forwards POST method' {
        Invoke-ApiEndpoint -endPoint '/workspaces' -method 'POST' -body '{"name":"ws"}' | Out-Null
        Should -Invoke Invoke-FabricApiRequest -Times 1 -ParameterFilter { $Method -eq 'POST' }
    }

    It 'forwards DELETE method' {
        Invoke-ApiEndpoint -endPoint '/workspaces/ws-123' -method 'DELETE' | Out-Null
        Should -Invoke Invoke-FabricApiRequest -Times 1 -ParameterFilter { $Method -eq 'DELETE' }
    }

    It 'forwards the request body to Invoke-FabricApiRequest' {
        $payload = '{"displayName":"My Workspace"}'
        Invoke-ApiEndpoint -endPoint '/workspaces' -method 'POST' -body $payload | Out-Null
        Should -Invoke Invoke-FabricApiRequest -Times 1 -ParameterFilter { $Body -eq $payload }
    }
}

# =============================================================================
Describe 'Invoke-FabricApiRequest — GET vs non-GET branching' {
    # Tests the wrapper itself using a mock of the underlying Invoke-WebRequest cmdlet.
    # Uses splatting, so parameter binding matches what the wrapper actually does.
    #
    # Note: -SkipHttpErrorCheck requires PowerShell 7+. The test that verifies it
    # carries a Skip guard so the suite stays green on Windows PowerShell 5.x.

    BeforeAll {
        Mock Invoke-WebRequest {
            [PSCustomObject]@{ StatusCode = 200; Content = '{}'; Headers = @{} }
        }
    }

    It 'calls Invoke-WebRequest without Body on GET' {
        Invoke-FabricApiRequest -Uri 'https://example.com' -Method 'GET' | Out-Null
        Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter { $null -eq $Body }
    }

    It 'calls Invoke-WebRequest with Body on POST' {
        Invoke-FabricApiRequest -Uri 'https://example.com' -Method 'POST' -Body '{"key":"val"}' | Out-Null
        Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter { $Body -eq '{"key":"val"}' }
    }

    It 'passes SkipHttpErrorCheck so non-2xx responses do not throw (PS7+ only)' `
        -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
        Invoke-FabricApiRequest -Uri 'https://example.com' -Method 'GET' | Out-Null
        Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter { $SkipHttpErrorCheck -eq $true }
    }
}

# =============================================================================
Describe 'New-FabricContext — constructor' {

    It 'returns a PSCustomObject' {
        $ctx = New-FabricContext
        $ctx | Should -BeOfType [PSCustomObject]
    }

    It 'defaults FabricBaseUrl to the unversioned host' {
        $ctx = New-FabricContext
        $ctx.FabricBaseUrl | Should -Be 'https://api.fabric.microsoft.com'
    }

    It 'defaults AzdoBaseUrl to dev.azure.com' {
        $ctx = New-FabricContext
        $ctx.AzdoBaseUrl | Should -Be 'https://dev.azure.com'
    }

    It 'defaults GraphBaseUrl to the v1.0 endpoint' {
        $ctx = New-FabricContext
        $ctx.GraphBaseUrl | Should -Be 'https://graph.microsoft.com/v1.0'
    }

    It 'accepts a custom FabricBaseUrl' {
        $ctx = New-FabricContext -FabricBaseUrl 'https://custom.fabric.com'
        $ctx.FabricBaseUrl | Should -Be 'https://custom.fabric.com'
    }

    It 'stores FabricRequestHeader and exposes Authorization' {
        $ctx = New-FabricContext -FabricRequestHeader @{ Authorization = 'Bearer test-token' }
        $ctx.FabricRequestHeader.Authorization | Should -Be 'Bearer test-token'
    }

    It 'stores DevOpsRequestHeader' {
        $ctx = New-FabricContext -DevOpsRequestHeader @{ Authorization = 'Bearer devops-token' }
        $ctx.DevOpsRequestHeader.Authorization | Should -Be 'Bearer devops-token'
    }

    It 'stores GraphRequestHeader' {
        $ctx = New-FabricContext -GraphRequestHeader @{ Authorization = 'Bearer graph-token' }
        $ctx.GraphRequestHeader.Authorization | Should -Be 'Bearer graph-token'
    }

    It 'defaults EnableDiagnostics to False' {
        $ctx = New-FabricContext
        $ctx.EnableDiagnostics | Should -Be 'False'
    }

    It 'defaults DeveloperView to false' {
        $ctx = New-FabricContext
        $ctx.DeveloperView | Should -Be $false
    }
}

# =============================================================================
Describe 'Invoke-ApiEndpoint — Context injection' {

    BeforeAll {
        Mock Invoke-FabricApiRequest { New-MockHttpResponse }
    }

    It 'uses Context.FabricBaseUrl when Context is provided and no baseUrl override' {
        $ctx = New-FabricContext -FabricBaseUrl 'https://ctx.fabric.com'
        Invoke-ApiEndpoint -endPoint '/items' -Context $ctx | Out-Null
        Should -Invoke Invoke-FabricApiRequest -Times 1 -ParameterFilter {
            $Uri -eq 'https://ctx.fabric.com/v1/items'
        }
    }

    It 'uses Context.FabricRequestHeader when Context is provided' {
        $ctx = New-FabricContext -FabricRequestHeader @{ Authorization = 'Bearer ctx-fabric-token' }
        Invoke-ApiEndpoint -endPoint '/items' -Context $ctx | Out-Null
        Should -Invoke Invoke-FabricApiRequest -Times 1 -ParameterFilter {
            $Headers.Authorization -eq 'Bearer ctx-fabric-token'
        }
    }

    It 'uses Context.DevOpsRequestHeader when useRequestHeader = DevOps' {
        $ctx = New-FabricContext -DevOpsRequestHeader @{ Authorization = 'Bearer ctx-devops-token' }
        Invoke-ApiEndpoint -useRequestHeader 'DevOps' -baseUrl 'https://dev.azure.com' `
                        -endPoint '/org/proj/_apis/pipelines' -Context $ctx | Out-Null
        Should -Invoke Invoke-FabricApiRequest -Times 1 -ParameterFilter {
            $Headers.Authorization -eq 'Bearer ctx-devops-token'
        }
    }

    It 'uses Context.GraphRequestHeader when useRequestHeader = Graph' {
        $ctx = New-FabricContext -GraphRequestHeader @{ Authorization = 'Bearer ctx-graph-token' }
        Invoke-ApiEndpoint -useRequestHeader 'Graph' -baseUrl 'https://graph.microsoft.com/v1.0' `
                        -endPoint '/users/me' -Context $ctx | Out-Null
        Should -Invoke Invoke-FabricApiRequest -Times 1 -ParameterFilter {
            $Headers.Authorization -eq 'Bearer ctx-graph-token'
        }
    }

    It 'explicit baseUrl override takes precedence over Context.FabricBaseUrl' {
        $ctx = New-FabricContext -FabricBaseUrl 'https://ctx.fabric.com/v99'
        Invoke-ApiEndpoint -baseUrl 'https://explicit.override.com' -endPoint '/endpoint' -Context $ctx | Out-Null
        Should -Invoke Invoke-FabricApiRequest -Times 1 -ParameterFilter {
            $Uri -eq 'https://explicit.override.com/endpoint'
        }
    }

    It 'falls back to script: variables when no Context is provided' {
        # $script:fabricBaseUrl is set in BeforeAll to 'https://api.fabric.microsoft.com'
        # Invoke-ApiEndpoint injects the default /v1 version, producing the full versioned URI
        Invoke-ApiEndpoint -endPoint '/workspaces' | Out-Null
        Should -Invoke Invoke-FabricApiRequest -Times 1 -ParameterFilter {
            $Uri -eq 'https://api.fabric.microsoft.com/v1/workspaces'
        }
    }
}
