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
Describe 'Set-DevOpsEnvironmentAdministrators' {

    BeforeAll {
        Mock Write-Message    { }
        Mock APIReturnedError { return "mocked API error: $intendedAction" }
        Mock Get-DevOpsProjectId { return 'project-guid-1' }
    }

    Context 'caller is not yet an Administrator and no co-administrators are provided' {
        BeforeEach {
            Mock Resolve-DevOpsIdentityId {
                return [PSCustomObject]@{ Id = 'caller-guid-1'; DisplayName = 'Caller' }
            }
            Mock Get-DevOpsEnvironmentRoleAssignments { return @() }
            Mock Invoke-ApiEndpoint {
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 200; Content = '{}' }
                    isException    = $false
                }
            }
        }

        It 'adds the caller as Administrator' {
            Set-DevOpsEnvironmentAdministrators -EnvironmentId 42 -CallerIdentifier 'caller@contoso.com' -CoAdministrators '' -Context $null
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter { $method -eq 'PUT' } -Times 1
        }
    }

    Context 'caller cannot be resolved to an Azure DevOps identity' {
        BeforeEach {
            Mock Resolve-DevOpsIdentityId { return $null }
        }

        It 'throws rather than silently skipping the sync' {
            { Set-DevOpsEnvironmentAdministrators -EnvironmentId 42 -CallerIdentifier 'ghost@contoso.com' -CoAdministrators '' -Context $null } |
                Should -Throw
        }
    }

    Context 'caller is already an Administrator and is omitted from the co-administrators list (regression: caller must never be removed)' {
        BeforeEach {
            Mock Resolve-DevOpsIdentityId {
                return [PSCustomObject]@{ Id = 'caller-guid-1'; DisplayName = 'Caller' }
            }
            Mock Get-DevOpsEnvironmentRoleAssignments {
                return @(
                    [PSCustomObject]@{ role = [PSCustomObject]@{ name = 'Administrator' }; identity = [PSCustomObject]@{ id = 'caller-guid-1'; displayName = 'Caller' } }
                )
            }
            Mock Invoke-ApiEndpoint {
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 200; Content = '{}' }
                    isException    = $false
                }
            }
        }

        It 'does not remove the caller' {
            Set-DevOpsEnvironmentAdministrators -EnvironmentId 42 -CallerIdentifier 'caller@contoso.com' -CoAdministrators '' -Context $null
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter { $method -eq 'DELETE' } -Times 0
        }

        It 'does not re-add the caller (already present)' {
            Set-DevOpsEnvironmentAdministrators -EnvironmentId 42 -CallerIdentifier 'caller@contoso.com' -CoAdministrators '' -Context $null
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter { $method -eq 'PUT' } -Times 0
        }
    }

    Context 'a co-administrator is added and a stale Administrator (not the caller) is removed' {
        BeforeEach {
            Mock Resolve-DevOpsIdentityId {
                if ($Identifier -eq 'caller@contoso.com') {
                    return [PSCustomObject]@{ Id = 'caller-guid-1'; DisplayName = 'Caller' }
                }
                return [PSCustomObject]@{ Id = 'coadmin-guid-1'; DisplayName = 'Co Admin' }
            }
            Mock Get-DevOpsEnvironmentRoleAssignments {
                return @(
                    [PSCustomObject]@{ role = [PSCustomObject]@{ name = 'Administrator' }; identity = [PSCustomObject]@{ id = 'caller-guid-1'; displayName = 'Caller' } },
                    [PSCustomObject]@{ role = [PSCustomObject]@{ name = 'Administrator' }; identity = [PSCustomObject]@{ id = 'stale-guid-1'; displayName = 'Stale Admin' } }
                )
            }
            Mock Invoke-ApiEndpoint {
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 200; Content = '{}' }
                    isException    = $false
                }
            }
        }

        It 'adds the co-administrator' {
            Set-DevOpsEnvironmentAdministrators -EnvironmentId 42 -CallerIdentifier 'caller@contoso.com' -CoAdministrators 'coadmin@contoso.com' -Context $null
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter { $method -eq 'PUT' } -Times 1
        }

        It 'removes the stale administrator' {
            Set-DevOpsEnvironmentAdministrators -EnvironmentId 42 -CallerIdentifier 'caller@contoso.com' -CoAdministrators 'coadmin@contoso.com' -Context $null
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter { $method -eq 'DELETE' -and $endPoint -like '*/stale-guid-1*' } -Times 1
        }

        It 'never removes the caller even though a removal happens' {
            Set-DevOpsEnvironmentAdministrators -EnvironmentId 42 -CallerIdentifier 'caller@contoso.com' -CoAdministrators 'coadmin@contoso.com' -Context $null
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter { $method -eq 'DELETE' -and $endPoint -like '*caller-guid-1*' } -Times 0
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
