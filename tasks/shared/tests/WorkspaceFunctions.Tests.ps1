###############################################################################
# Tests: WorkspaceFunctions.ps1 — Add-WorkspaceUsers
#
# Run all tests:
#   powershell -NoProfile -File .\tasks\shared\tests\Invoke-Tests.ps1
#
# Run only these:
#   powershell -NoProfile -File .\tasks\shared\tests\Invoke-Tests.ps1 -Filter 'Add-WorkspaceUsers'
#
# Requires Pester 5+
###############################################################################
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    . "$PSScriptRoot\..\private\SharedFunctions.ps1"
    . "$PSScriptRoot\..\private\WorkspaceFunctions.ps1"
}

# =============================================================================
Describe 'Add-WorkspaceUsers' {

    BeforeAll {
        Mock Write-Message   { }
        Mock APIReturnedError { return "mocked API error: $intendedAction" }
    }

    Context 'no UPN list provided' {
        It 'returns immediately without calling the API' {
            Mock Invoke-ApiEndpoint { }
            Add-WorkspaceUsers -workspaceId 'ws-111' -upnList '' -workspaceRole 'Viewer'
            Should -Invoke Invoke-ApiEndpoint -Times 0
        }

        It 'emits an Info message when list is empty' {
            Mock Invoke-ApiEndpoint { }
            Add-WorkspaceUsers -workspaceId 'ws-111' -upnList '' -workspaceRole 'Viewer'
            Should -Invoke Write-Message -ParameterFilter { $msgType -eq 'Info' }
        }
    }

    Context 'UPN provided, no existing assignments for that role (regression: ExistingIds must not be $null)' {
        # This is the exact scenario that caused "Cannot bind argument to parameter
        # 'ExistingIds' because it is null" when the workspace had no Viewer
        # assignments yet and Select-Object -Unique collapsed @() to $null.

        BeforeEach {
            Mock Resolve-UpnToId {
                return @{ Id = 'group-guid-111'; Type = 'Group' }
            }
            Mock Invoke-ApiEndpoint {
                if ($method -eq 'POST') {
                    return [PSCustomObject]@{
                        responseObject = [PSCustomObject]@{ StatusCode = 200; Content = '{}' }
                        isException    = $false
                    }
                }
                # GET role assignments — role has never been assigned, list is empty
                $content = '{"value":[]}'
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 200; Content = $content }
                    isException    = $false
                }
            }
        }

        It 'does not throw when the role has zero existing assignments' {
            { Add-WorkspaceUsers -workspaceId 'ws-111' -upnList 'sg-viewers@contoso.com' -workspaceRole 'Viewer' } |
                Should -Not -Throw
        }

        It 'calls POST to add the resolved principal' {
            Add-WorkspaceUsers -workspaceId 'ws-111' -upnList 'sg-viewers@contoso.com' -workspaceRole 'Viewer'
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter { $method -eq 'POST' } -Times 1
        }

        It 'emits a sync-complete Info message' {
            Add-WorkspaceUsers -workspaceId 'ws-111' -upnList 'sg-viewers@contoso.com' -workspaceRole 'Viewer'
            Should -Invoke Write-Message -ParameterFilter {
                $msgType -eq 'Info' -and $msgText -like "*Sync complete*"
            }
        }
    }

    Context 'UPN provided, existing assignments present for that role' {
        BeforeEach {
            Mock Resolve-UpnToId {
                return @{ Id = 'user-guid-abc'; Type = 'User' }
            }
            Mock Invoke-ApiEndpoint {
                if ($method -eq 'POST') {
                    return [PSCustomObject]@{
                        responseObject = [PSCustomObject]@{ StatusCode = 200; Content = '{}' }
                        isException    = $false
                    }
                }
                # GET role assignments — alice already has Member
                $content = @'
{"value":[{"id":"ra-existing-1","role":"Member","principal":{"id":"user-guid-abc","displayName":"Alice","type":"User","userDetails":{"userPrincipalName":"alice@contoso.com"},"servicePrincipalDetails":{"aadAppId":null}}}]}
'@
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 200; Content = $content }
                    isException    = $false
                }
            }
        }

        It 'does not add a principal that is already assigned' {
            Add-WorkspaceUsers -workspaceId 'ws-111' -upnList 'alice@contoso.com' -workspaceRole 'Member'
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter { $method -eq 'POST' } -Times 0
        }

        It 'reports zero adds in the sync-complete message' {
            Add-WorkspaceUsers -workspaceId 'ws-111' -upnList 'alice@contoso.com' -workspaceRole 'Member'
            Should -Invoke Write-Message -ParameterFilter {
                $msgType -eq 'Info' -and $msgText -like "*Added=0*"
            }
        }
    }

    Context 'UPN provided, stale assignment present (principal no longer in target list)' {
        BeforeEach {
            Mock Resolve-UpnToId {
                return @{ Id = 'user-guid-new'; Type = 'User' }
            }
            Mock Invoke-ApiEndpoint {
                if ($method -eq 'POST') {
                    return [PSCustomObject]@{
                        responseObject = [PSCustomObject]@{ StatusCode = 200; Content = '{}' }
                        isException    = $false
                    }
                }
                if ($method -eq 'DELETE') {
                    return [PSCustomObject]@{
                        responseObject = [PSCustomObject]@{ StatusCode = 200; Content = '{}' }
                        isException    = $false
                    }
                }
                # GET role assignments — old user is stale Contributor
                $content = @'
{"value":[{"id":"ra-stale-99","role":"Contributor","principal":{"id":"user-guid-old","displayName":"OldUser","type":"User","userDetails":{"userPrincipalName":"old@contoso.com"},"servicePrincipalDetails":{"aadAppId":null}}}]}
'@
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 200; Content = $content }
                    isException    = $false
                }
            }
        }

        It 'calls DELETE for the stale assignment' {
            Add-WorkspaceUsers -workspaceId 'ws-111' -upnList 'new@contoso.com' -workspaceRole 'Contributor'
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter { $method -eq 'DELETE' } -Times 1
        }

        It 'calls POST to add the new principal' {
            Add-WorkspaceUsers -workspaceId 'ws-111' -upnList 'new@contoso.com' -workspaceRole 'Contributor'
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter { $method -eq 'POST' } -Times 1
        }
    }
}
