###############################################################################
# Tests: ItemFunctions.ps1 - schedule functions
#
# Run all tests:
#   powershell -NoProfile -File .\tasks\shared\tests\Invoke-Tests.ps1
#
# Run only these:
#   powershell -NoProfile -File .\tasks\shared\tests\Invoke-Tests.ps1 -Filter 'Schedule'
#
# Requires Pester 5+
###############################################################################
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    . "$PSScriptRoot\..\private\SharedFunctions.ps1"
    . "$PSScriptRoot\..\private\ItemFunctions.ps1"
}

# =============================================================================
Describe 'Get-FabricItemSchedules' {

    BeforeAll {
        Mock Write-Message    { }
        Mock APIReturnedError { return "mocked API error: $intendedAction" }
    }

    Context 'schedules exist' {
        BeforeEach {
            Mock Invoke-ApiEndpoint {
                $content = '{"value":[{"id":"sch-1","enabled":false},{"id":"sch-2","enabled":true}]}'
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 200; Content = $content }
                    isException    = $false
                }
            }
        }

        It 'returns every schedule in the value array' {
            $result = Get-FabricItemSchedules -workspaceId 'ws-111' -itemId 'item-111' -jobType 'Execute'
            $result | Should -HaveCount 2
        }

        It 'calls the jobs/{jobType}/schedules endpoint' {
            Get-FabricItemSchedules -workspaceId 'ws-111' -itemId 'item-111' -jobType 'Execute' | Out-Null
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter {
                $endPoint -eq '/workspaces/ws-111/items/item-111/jobs/Execute/schedules'
            }
        }
    }

    Context 'no schedules exist' {
        It 'returns an empty array, not null' {
            Mock Invoke-ApiEndpoint {
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}' }
                    isException    = $false
                }
            }
            $result = @(Get-FabricItemSchedules -workspaceId 'ws-111' -itemId 'item-111' -jobType 'Execute')
            $result | Should -HaveCount 0
        }
    }

    Context 'API failure' {
        It 'throws when the API does not return 200' {
            Mock Invoke-ApiEndpoint {
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 404; Content = '{}' }
                    isException    = $true
                }
            }
            { Get-FabricItemSchedules -workspaceId 'ws-111' -itemId 'item-111' -jobType 'Execute' } | Should -Throw
        }
    }
}

# =============================================================================
Describe 'Get-FabricItemSchedule' {

    BeforeAll {
        Mock Write-Message    { }
        Mock APIReturnedError { return "mocked API error: $intendedAction" }
    }

    It 'returns the parsed schedule object' {
        Mock Invoke-ApiEndpoint {
            $content = '{"id":"sch-1","enabled":true,"configuration":{"type":"Daily","times":["00:30"]}}'
            return [PSCustomObject]@{
                responseObject = [PSCustomObject]@{ StatusCode = 200; Content = $content }
                isException    = $false
            }
        }
        $result = Get-FabricItemSchedule -workspaceId 'ws-111' -itemId 'item-111' -jobType 'Execute' -scheduleId 'sch-1'
        $result.id      | Should -Be 'sch-1'
        $result.enabled | Should -Be $true
    }

    It 'calls the jobs/{jobType}/schedules/{scheduleId} endpoint' {
        Mock Invoke-ApiEndpoint {
            return [PSCustomObject]@{
                responseObject = [PSCustomObject]@{ StatusCode = 200; Content = '{"id":"sch-1","enabled":true}' }
                isException    = $false
            }
        }
        Get-FabricItemSchedule -workspaceId 'ws-111' -itemId 'item-111' -jobType 'Execute' -scheduleId 'sch-1' | Out-Null
        Should -Invoke Invoke-ApiEndpoint -ParameterFilter {
            $endPoint -eq '/workspaces/ws-111/items/item-111/jobs/Execute/schedules/sch-1'
        }
    }
}

# =============================================================================
Describe 'Set-FabricItemScheduleState' {

    BeforeAll {
        Mock Write-Message    { }
        Mock APIReturnedError { return "mocked API error: $intendedAction" }
    }

    Context 'successful update' {
        BeforeEach {
            Mock Invoke-ApiEndpoint {
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 200; Content = '{"id":"sch-1","enabled":true}' }
                    isException    = $false
                }
            }
        }

        It 'PATCHes the schedule endpoint' {
            Set-FabricItemScheduleState -workspaceId 'ws-111' -itemId 'item-111' -jobType 'Execute' `
                -scheduleId 'sch-1' -enabled $true -configuration ([PSCustomObject]@{ type = 'Daily' })
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter {
                $method -eq 'PATCH' -and $endPoint -eq '/workspaces/ws-111/items/item-111/jobs/Execute/schedules/sch-1'
            }
        }

        It 'echoes the configuration and enabled flag back in the body' {
            Set-FabricItemScheduleState -workspaceId 'ws-111' -itemId 'item-111' -jobType 'Execute' `
                -scheduleId 'sch-1' -enabled $true -configuration ([PSCustomObject]@{ type = 'Daily' })
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter {
                ($body | ConvertFrom-Json).enabled -eq $true -and
                ($body | ConvertFrom-Json).configuration.type -eq 'Daily'
            }
        }

        It 'includes executionData in the body only when supplied' {
            Set-FabricItemScheduleState -workspaceId 'ws-111' -itemId 'item-111' -jobType 'Execute' `
                -scheduleId 'sch-1' -enabled $true `
                -configuration ([PSCustomObject]@{ type = 'Daily' }) `
                -executionData ([PSCustomObject]@{ tableName = 'Table1' })
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter {
                ($body | ConvertFrom-Json).executionData.tableName -eq 'Table1'
            }
        }
    }

    Context 'API failure' {
        It 'throws when the API reports an exception' {
            Mock Invoke-ApiEndpoint {
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 400; Content = '{}' }
                    isException    = $true
                }
            }
            {
                Set-FabricItemScheduleState -workspaceId 'ws-111' -itemId 'item-111' -jobType 'Execute' `
                    -scheduleId 'sch-1' -enabled $true -configuration ([PSCustomObject]@{ type = 'Daily' })
            } | Should -Throw
        }
    }
}

# =============================================================================
Describe 'Set-FabricItemSchedulesStatus' {

    BeforeAll {
        Mock Write-Message    { }
        Mock APIReturnedError { return "mocked API error: $intendedAction" }
    }

    Context 'item has no schedules' {
        It 'warns and does not attempt an update' {
            Mock Get-FabricItemSchedules { return @() }
            Mock Get-FabricItemSchedule { }
            Mock Set-FabricItemScheduleState { }

            Set-FabricItemSchedulesStatus -workspaceId 'ws-111' -itemId 'item-111' -itemName 'pl_test' -jobType 'Execute' -enabled $true

            Should -Invoke Write-Message -ParameterFilter { $msgType -eq 'Warning' }
            Should -Invoke Set-FabricItemScheduleState -Times 0
        }
    }

    Context 'schedule already in the desired state' {
        It 'does not call Set-FabricItemScheduleState' {
            Mock Get-FabricItemSchedules { return @([PSCustomObject]@{ id = 'sch-1' }) }
            Mock Get-FabricItemSchedule {
                return [PSCustomObject]@{ id = 'sch-1'; enabled = $true; configuration = [PSCustomObject]@{ type = 'Daily' } }
            }
            Mock Set-FabricItemScheduleState { }

            Set-FabricItemSchedulesStatus -workspaceId 'ws-111' -itemId 'item-111' -itemName 'pl_test' -jobType 'Execute' -enabled $true

            Should -Invoke Set-FabricItemScheduleState -Times 0
        }
    }

    Context 'schedule needs to flip state' {
        It 'calls Set-FabricItemScheduleState with the desired enabled value and existing configuration' {
            Mock Get-FabricItemSchedules { return @([PSCustomObject]@{ id = 'sch-1' }) }
            Mock Get-FabricItemSchedule {
                return [PSCustomObject]@{
                    id            = 'sch-1'
                    enabled       = $false
                    configuration = [PSCustomObject]@{ type = 'Daily'; times = @('00:30') }
                }
            }
            Mock Set-FabricItemScheduleState { }

            Set-FabricItemSchedulesStatus -workspaceId 'ws-111' -itemId 'item-111' -itemName 'pl_test' -jobType 'Execute' -enabled $true

            Should -Invoke Set-FabricItemScheduleState -ParameterFilter {
                $enabled -eq $true -and $scheduleId -eq 'sch-1' -and $configuration.type -eq 'Daily'
            }
        }
    }

    Context 'item has multiple schedules' {
        It 'evaluates every schedule returned' {
            Mock Get-FabricItemSchedules { return @([PSCustomObject]@{ id = 'sch-1' }, [PSCustomObject]@{ id = 'sch-2' }) }
            Mock Get-FabricItemSchedule {
                return [PSCustomObject]@{ id = $scheduleId; enabled = $false; configuration = [PSCustomObject]@{ type = 'Daily' } }
            }
            Mock Set-FabricItemScheduleState { }

            Set-FabricItemSchedulesStatus -workspaceId 'ws-111' -itemId 'item-111' -itemName 'pl_test' -jobType 'Execute' -enabled $true

            Should -Invoke Set-FabricItemScheduleState -Times 2
        }
    }
}
