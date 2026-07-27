###############################################################################
# Tests: DevOpsFunctions.ps1 — environment provisioning
#
# Run all tests:
#   powershell -NoProfile -File .\tasks\shared\tests\Invoke-Tests.ps1
#
# Run only these:
#   powershell -NoProfile -File .\tasks\shared\tests\Invoke-Tests.ps1 -Filter 'DevOpsFunctions'
#
# Requires Pester 5+
###############################################################################
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    . "$PSScriptRoot\..\private\SharedFunctions.ps1"
    . "$PSScriptRoot\..\private\DevOpsFunctions.ps1"
}

# =============================================================================
Describe 'Resolve-DevOpsIdentityId' {

    BeforeAll {
        Mock Write-Message    { }
        Mock APIReturnedError { return "mocked API error: $intendedAction" }
    }

    It 'returns the identity id and display name when found' {
        Mock Invoke-ApiEndpoint {
            return [PSCustomObject]@{
                responseObject = [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[{"id":"identity-guid-1","providerDisplayName":"Alice Example"}]}' }
                isException    = $false
            }
        }
        $result = Resolve-DevOpsIdentityId -Identifier 'alice@contoso.com'
        $result.Id          | Should -Be 'identity-guid-1'
        $result.DisplayName | Should -Be 'Alice Example'
    }

    It 'uses the vssps.dev.azure.com host for the standard Azure DevOps Services base URL' {
        Mock Invoke-ApiEndpoint {
            return [PSCustomObject]@{
                responseObject = [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[{"id":"x","providerDisplayName":"x"}]}' }
                isException    = $false
            }
        }
        $context = New-AzdoConfig -AzdoBaseUrl 'https://dev.azure.com' -OrganizationName 'contoso'
        Resolve-DevOpsIdentityId -Identifier 'alice@contoso.com' -Context $context | Out-Null
        Should -Invoke Invoke-ApiEndpoint -ParameterFilter { $baseUrl -eq 'https://vssps.dev.azure.com' }
    }

    It 'returns $null and warns when no identity matches' {
        Mock Invoke-ApiEndpoint {
            return [PSCustomObject]@{
                responseObject = [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}' }
                isException    = $false
            }
        }
        $result = Resolve-DevOpsIdentityId -Identifier 'ghost@contoso.com'
        $result | Should -BeNullOrEmpty
        Should -Invoke Write-Message -ParameterFilter { $msgType -eq 'Warning' }
    }
}

# =============================================================================
Describe 'Get-DevOpsEnvironmentRoleAssignments' {

    BeforeAll {
        Mock Write-Message    { }
        Mock APIReturnedError { return "mocked API error: $intendedAction" }
    }

    It 'returns the parsed assignments on success' {
        Mock Invoke-ApiEndpoint {
            return [PSCustomObject]@{
                responseObject = [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[{"role":{"name":"Administrator"},"identity":{"id":"a"}}]}' }
                isException    = $false
            }
        }
        $result = Get-DevOpsEnvironmentRoleAssignments -ResourceId 'proj-guid_1'
        $result.Count | Should -Be 1
        $result[0].identity.id | Should -Be 'a'
    }

    It 'includes the organization name in the Security Roles URL (regression: endpoint must not be host-relative)' {
        Mock Invoke-ApiEndpoint {
            return [PSCustomObject]@{
                responseObject = [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}' }
                isException    = $false
            }
        }
        $context = New-AzdoConfig -AzdoBaseUrl 'https://dev.azure.com' -OrganizationName 'contoso'
        Get-DevOpsEnvironmentRoleAssignments -ResourceId 'proj-guid_1' -Context $context | Out-Null
        Should -Invoke Invoke-ApiEndpoint -ParameterFilter { $endPoint -like '/contoso/_apis/securityroles/*' }
    }

    Context '404 - environment has never had an explicit role assignment set' {
        BeforeEach {
            Mock Invoke-ApiEndpoint {
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 404; Message = 'Not Found'; Body = '' }
                    isException    = $true
                }
            }
        }

        It 'returns an empty array instead of throwing' {
            { Get-DevOpsEnvironmentRoleAssignments -ResourceId 'proj-guid_1' } | Should -Not -Throw
            (Get-DevOpsEnvironmentRoleAssignments -ResourceId 'proj-guid_1').Count | Should -Be 0
        }

        It 'logs a Warning rather than silently swallowing the 404' {
            Get-DevOpsEnvironmentRoleAssignments -ResourceId 'proj-guid_1' | Out-Null
            Should -Invoke Write-Message -ParameterFilter { $msgType -eq 'Warning' }
        }
    }

    Context 'any other error status' {
        BeforeEach {
            Mock Invoke-ApiEndpoint {
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 500; Message = 'boom'; Body = '' }
                    isException    = $true
                }
            }
        }

        It 'still throws' {
            { Get-DevOpsEnvironmentRoleAssignments -ResourceId 'proj-guid_1' } | Should -Throw
        }
    }
}

# =============================================================================
Describe 'Set-DevOpsEnvironmentAdministrators' {

    BeforeAll {
        Mock Write-Message    { }
        Mock APIReturnedError { return "mocked API error: $intendedAction" }
        Mock Get-DevOpsProjectId { return 'project-guid-1' }
    }

    Context 'no co-administrators provided' {
        It 'returns immediately without calling the API' {
            Mock Invoke-ApiEndpoint { }
            Set-DevOpsEnvironmentAdministrators -EnvironmentId 42 -CoAdministrators '' -Context $null
            Should -Invoke Invoke-ApiEndpoint -Times 0
        }
    }

    Context 'co-administrator cannot be resolved to an Azure DevOps identity' {
        BeforeEach {
            Mock Resolve-DevOpsIdentityId { return $null }
        }

        It 'warns and leaves Administrators unchanged rather than throwing' {
            { Set-DevOpsEnvironmentAdministrators -EnvironmentId 42 -CoAdministrators 'ghost@contoso.com' -Context $null } |
                Should -Not -Throw
            Should -Invoke Write-Message -ParameterFilter { $msgType -eq 'Warning' }
        }
    }

    Context 'co-administrator is not yet an Administrator' {
        BeforeEach {
            Mock Resolve-DevOpsIdentityId {
                return [PSCustomObject]@{ Id = 'coadmin-guid-1'; DisplayName = 'Co Admin' }
            }
            Mock Get-DevOpsEnvironmentRoleAssignments { return @() }
            Mock Invoke-ApiEndpoint {
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 200; Content = '{}' }
                    isException    = $false
                }
            }
        }

        It 'adds the co-administrator' {
            Set-DevOpsEnvironmentAdministrators -EnvironmentId 42 -CoAdministrators 'coadmin@contoso.com' -Context $null
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter { $method -eq 'PUT' } -Times 1
        }

        It 'never calls DELETE (additive only)' {
            Set-DevOpsEnvironmentAdministrators -EnvironmentId 42 -CoAdministrators 'coadmin@contoso.com' -Context $null
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter { $method -eq 'DELETE' } -Times 0
        }

        It 'includes the organization name in the Security Roles URL (regression: endpoint must not be host-relative)' {
            $context = New-AzdoConfig -AzdoBaseUrl 'https://dev.azure.com' -OrganizationName 'contoso' -ProjectName 'proj'
            Set-DevOpsEnvironmentAdministrators -EnvironmentId 42 -CoAdministrators 'coadmin@contoso.com' -Context $context
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter { $method -eq 'PUT' -and $endPoint -like '/contoso/_apis/securityroles/*' } -Times 1
        }
    }

    Context 'co-administrator is already an Administrator, and an unrelated existing Administrator is present' {
        BeforeEach {
            Mock Resolve-DevOpsIdentityId {
                return [PSCustomObject]@{ Id = 'coadmin-guid-1'; DisplayName = 'Co Admin' }
            }
            Mock Get-DevOpsEnvironmentRoleAssignments {
                return @(
                    [PSCustomObject]@{ role = [PSCustomObject]@{ name = 'Administrator' }; identity = [PSCustomObject]@{ id = 'coadmin-guid-1'; displayName = 'Co Admin' } },
                    [PSCustomObject]@{ role = [PSCustomObject]@{ name = 'Administrator' }; identity = [PSCustomObject]@{ id = 'creator-guid-1'; displayName = 'Creator' } }
                )
            }
            Mock Invoke-ApiEndpoint {
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 200; Content = '{}' }
                    isException    = $false
                }
            }
        }

        It 'does not re-add the co-administrator' {
            Set-DevOpsEnvironmentAdministrators -EnvironmentId 42 -CoAdministrators 'coadmin@contoso.com' -Context $null
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter { $method -eq 'PUT' } -Times 0
        }

        It 'never touches the unrelated existing administrator (e.g. the environment creator)' {
            Set-DevOpsEnvironmentAdministrators -EnvironmentId 42 -CoAdministrators 'coadmin@contoso.com' -Context $null
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter { $method -eq 'DELETE' } -Times 0
        }
    }
}

# =============================================================================
Describe 'Set-DevOpsEnvironmentApprover' {

    BeforeAll {
        Mock Write-Message    { }
        Mock APIReturnedError { return "mocked API error: $intendedAction" }
    }

    Context 'no approver UPN provided' {
        It 'returns immediately without calling the API' {
            Mock Invoke-ApiEndpoint { }
            Set-DevOpsEnvironmentApprover -EnvironmentId 42 -ApproverUpn '' -Context $null
            Should -Invoke Invoke-ApiEndpoint -Times 0
        }
    }

    Context 'an Approval check already exists' {
        BeforeEach {
            Mock Invoke-ApiEndpoint {
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[{"type":{"name":"Approval"}}]}' }
                    isException    = $false
                }
            }
        }

        It 'does not create a duplicate check' {
            Set-DevOpsEnvironmentApprover -EnvironmentId 42 -ApproverUpn 'approver@contoso.com' -Context $null
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter { $method -eq 'POST' } -Times 0
        }
    }

    Context 'no Approval check exists yet' {
        BeforeEach {
            Mock Resolve-DevOpsIdentityId {
                return [PSCustomObject]@{ Id = 'approver-guid-1'; DisplayName = 'Approver' }
            }
            Mock Invoke-ApiEndpoint {
                if ($method -eq 'POST') {
                    return [PSCustomObject]@{
                        responseObject = [PSCustomObject]@{ StatusCode = 200; Content = '{}' }
                        isException    = $false
                    }
                }
                # GET existing checks — none configured
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}' }
                    isException    = $false
                }
            }
        }

        It 'creates a new Approval check for the resolved approver' {
            Set-DevOpsEnvironmentApprover -EnvironmentId 42 -ApproverUpn 'approver@contoso.com' -Context $null
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter { $method -eq 'POST' } -Times 1
        }

        It 'throws when the approver cannot be resolved' {
            Mock Resolve-DevOpsIdentityId { return $null }
            { Set-DevOpsEnvironmentApprover -EnvironmentId 42 -ApproverUpn 'ghost@contoso.com' -Context $null } |
                Should -Throw
        }
    }
}
