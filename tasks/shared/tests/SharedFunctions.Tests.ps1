###############################################################################
# Tests: SharedFunctions.ps1 — pure helper functions
#
# Run all tests:
#   powershell -NoProfile -Command "Invoke-Pester '.\tasks\shared\tests\SharedFunctions.Tests.ps1' -Output Detailed"
#
# Or use the runner:
#   powershell -NoProfile -File .\tasks\shared\tests\Invoke-Tests.ps1
#
# Requires Pester 5+
###############################################################################
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    # Dot-source the module under test — all functions land in this script's scope.
    # Write-Message "Debug" calls inside Update-JsonValues/Set-PropertyPath are harmless:
    # $enableDiagnostics is undefined here, so [Convert]::ToBoolean($null) = $false.
    . "$PSScriptRoot\..\private\SharedFunctions.ps1"
}

# =============================================================================
Describe 'Resolve-NormalizedUpnList' {

    Context 'empty / blank input' {
        It 'returns an empty array for an empty string' {
            $result = Resolve-NormalizedUpnList -upnList ''
            $result | Should -BeNullOrEmpty
        }
        It 'returns an empty array for a whitespace-only string' {
            $result = Resolve-NormalizedUpnList -upnList '   '
            $result | Should -BeNullOrEmpty
        }
    }

    Context 'single UPN' {
        It 'returns a single-element array' {
            $result = Resolve-NormalizedUpnList -upnList 'User@Contoso.COM'
            @($result) | Should -HaveCount 1
        }
        It 'lowercases the UPN' {
            $result = Resolve-NormalizedUpnList -upnList 'User@Contoso.COM'
            $result | Should -Contain 'user@contoso.com'
        }
    }

    Context 'multiple UPNs' {
        It 'splits on semicolons and returns all entries' {
            $result = Resolve-NormalizedUpnList -upnList 'a@x.com;b@x.com;c@x.com'
            $result | Should -HaveCount 3
        }
        It 'trims leading and trailing whitespace from each entry' {
            $result = Resolve-NormalizedUpnList -upnList '  a@x.com ; b@x.com  '
            $result | Should -Contain 'a@x.com'
            $result | Should -Contain 'b@x.com'
        }
        It 'lowercases all entries' {
            $result = Resolve-NormalizedUpnList -upnList 'Alice@X.COM;BOB@X.COM'
            $result | Should -Contain 'alice@x.com'
            $result | Should -Contain 'bob@x.com'
        }
        It 'deduplicates entries that are identical after normalisation' {
            $result = Resolve-NormalizedUpnList -upnList 'A@x.com;a@x.com;A@X.COM'
            @($result) | Should -HaveCount 1
            $result | Should -Contain 'a@x.com'
        }
        It 'skips empty segments from double or trailing semicolons' {
            $result = Resolve-NormalizedUpnList -upnList 'a@x.com;;b@x.com;'
            $result | Should -HaveCount 2
        }
    }

    Context 'return type' {
        It 'always returns an array (not a single string) even for one UPN' {
            $result = Resolve-NormalizedUpnList -upnList 'only@one.com'
            # Wrap in @() to force array evaluation in PowerShell pipeline
            @($result) | Should -HaveCount 1
        }
    }
}

# =============================================================================
Describe 'Compare-RoleAssignments' {

    Context 'additions only' {
        It 'puts IDs in target but not in existing into ToAdd' {
            $result = Compare-RoleAssignments -TargetIds @('a', 'b') -ExistingIds @('b')
            $result.ToAdd | Should -Contain 'a'
            $result.ToAdd | Should -Not -Contain 'b'
        }
        It 'leaves ToRemove empty when existing is a subset of target' {
            $result = Compare-RoleAssignments -TargetIds @('a', 'b') -ExistingIds @('b')
            $result.ToRemove | Should -BeNullOrEmpty
        }
    }

    Context 'removals only' {
        It 'puts IDs in existing but not in target into ToRemove' {
            $result = Compare-RoleAssignments -TargetIds @('a') -ExistingIds @('a', 'b')
            $result.ToRemove | Should -Contain 'b'
            $result.ToRemove | Should -Not -Contain 'a'
        }
        It 'leaves ToAdd empty when target is a subset of existing' {
            $result = Compare-RoleAssignments -TargetIds @('a') -ExistingIds @('a', 'b')
            $result.ToAdd | Should -BeNullOrEmpty
        }
    }

    Context 'no changes needed' {
        It 'returns empty ToAdd and ToRemove when sets are identical' {
            $result = Compare-RoleAssignments -TargetIds @('a', 'b') -ExistingIds @('a', 'b')
            $result.ToAdd    | Should -BeNullOrEmpty
            $result.ToRemove | Should -BeNullOrEmpty
        }
    }

    Context 'preserved IDs (service principals)' {
        It 'never puts a preserved ID into ToRemove even when absent from target' {
            $result = Compare-RoleAssignments `
                -TargetIds    @('user-1') `
                -ExistingIds  @('user-1', 'spn-1') `
                -PreservedIds @('spn-1')
            $result.ToRemove | Should -Not -Contain 'spn-1'
        }
        It 'still removes non-preserved stale IDs' {
            $result = Compare-RoleAssignments `
                -TargetIds    @('user-1') `
                -ExistingIds  @('user-1', 'user-2', 'spn-1') `
                -PreservedIds @('spn-1')
            $result.ToRemove | Should -Contain 'user-2'
            $result.ToRemove | Should -Not -Contain 'spn-1'
        }
        It 'preserves multiple SPNs simultaneously' {
            $result = Compare-RoleAssignments `
                -TargetIds    @() `
                -ExistingIds  @('spn-1', 'spn-2') `
                -PreservedIds @('spn-1', 'spn-2')
            $result.ToRemove | Should -BeNullOrEmpty
        }
    }

    Context 'empty inputs' {
        It 'returns empty result when both sets are empty' {
            $result = Compare-RoleAssignments -TargetIds @() -ExistingIds @()
            $result.ToAdd    | Should -BeNullOrEmpty
            $result.ToRemove | Should -BeNullOrEmpty
        }
        It 'moves all target IDs to ToAdd when existing is empty' {
            $result = Compare-RoleAssignments -TargetIds @('a', 'b') -ExistingIds @()
            $result.ToAdd | Should -HaveCount 2
        }
        It 'moves all existing IDs to ToRemove when target is empty and none are preserved' {
            $result = Compare-RoleAssignments -TargetIds @() -ExistingIds @('a', 'b')
            $result.ToRemove | Should -HaveCount 2
        }
    }

    Context 'return shape' {
        It 'always returns an object with ToAdd and ToRemove properties' {
            $result = Compare-RoleAssignments -TargetIds @() -ExistingIds @()
            $result.PSObject.Properties.Name | Should -Contain 'ToAdd'
            $result.PSObject.Properties.Name | Should -Contain 'ToRemove'
        }
    }
}

# =============================================================================
Describe 'Invoke-TokenSubstitution' {

    BeforeAll {
        $catalog = [PSCustomObject]@{
            'Home.Workspace.Id'        = 'ws-111'
            'Default.Lakehouse.Id'     = 'lh-222'
            'MyWorkspace.Lakehouse.Id' = 'lh-333'
        }
    }

    Context 'exact token match' {
        It 'replaces a single token with its catalog value' {
            $result = Invoke-TokenSubstitution `
                -line   '...#{Home.Workspace.Id}#...' `
                -tokens $catalog
            $result | Should -Be '...ws-111...'
        }
        It 'replaces multiple tokens on the same line in one pass' {
            $result = Invoke-TokenSubstitution `
                -line   '#{Home.Workspace.Id}#::#{Default.Lakehouse.Id}#' `
                -tokens $catalog
            $result | Should -Be 'ws-111::lh-222'
        }
        It 'does not double-substitute a value that looks like another token' {
            # Value 'ws-111' contains no #{...}# pattern, so it should not be re-replaced
            $result = Invoke-TokenSubstitution `
                -line   '#{Home.Workspace.Id}#' `
                -tokens $catalog
            $result | Should -Be 'ws-111'
        }
    }

    Context 'Default.* fallback substitution' {
        It 'uses the Default.* variant when exact token is absent from the catalog' {
            # Catalog has 'MyWorkspace.Lakehouse.Id' — its Default form is 'Default.Lakehouse.Id'
            $partialCatalog = [PSCustomObject]@{
                'MyWorkspace.Lakehouse.Id' = 'lh-my'
            }
            $result = Invoke-TokenSubstitution `
                -line   '#{Default.Lakehouse.Id}#' `
                -tokens $partialCatalog
            $result | Should -Be 'lh-my'
        }
        It 'prefers the exact match over the Default.* fallback when both would apply' {
            # Catalog has both Default.Lakehouse.Id (exact) and MyWorkspace.Lakehouse.Id (fallback)
            # The exact key should win; result must be lh-222, not lh-333
            $result = Invoke-TokenSubstitution `
                -line   '#{Default.Lakehouse.Id}#' `
                -tokens $catalog
            $result | Should -Be 'lh-222'
        }
    }

    Context 'no match' {
        It 'returns the line unchanged when no #{...}# token is present' {
            $result = Invoke-TokenSubstitution -line 'plain text, no tokens' -tokens $catalog
            $result | Should -Be 'plain text, no tokens'
        }
        It 'returns the line unchanged when the token has no catalog entry and no Default.* variant' {
            $result = Invoke-TokenSubstitution -line '#{Unknown.Completely.Missing}#' -tokens $catalog
            $result | Should -Be '#{Unknown.Completely.Missing}#'
        }
        It 'handles an empty catalog without error' {
            $empty  = [PSCustomObject]@{}
            $result = Invoke-TokenSubstitution -line '#{Any.Token}#' -tokens $empty
            $result | Should -Be '#{Any.Token}#'
        }
    }

    Context 'edge cases' {
        It 'handles an empty line without error' {
            $result = Invoke-TokenSubstitution -line '' -tokens $catalog
            $result | Should -Be ''
        }
        It 'handles a line with regex-special characters outside of tokens' {
            $result = Invoke-TokenSubstitution `
                -line   'price: $100.00 (see #{Home.Workspace.Id}#)' `
                -tokens $catalog
            $result | Should -Be 'price: $100.00 (see ws-111)'
        }
    }
}

# =============================================================================
Describe 'Invoke-TokenReplacement' {

    BeforeAll {
        $catalog = [PSCustomObject]@{
            'Home.Workspace.Id'    = 'ws-abc'
            'Default.Lakehouse.Id' = 'lh-xyz'
        }
    }

    It 'replaces tokens that appear in the provided content lines' {
        $lines  = @('row,Type,path,#{Home.Workspace.Id}#')
        $result = Invoke-TokenReplacement -content $lines -tokens $catalog
        $result | Should -Match 'ws-abc'
        $result | Should -Not -Match '#{Home.Workspace.Id}#'
    }

    It 'appends the six default catalog rows (Notebook/SemanticModel/Report mappings)' {
        $lines  = @('header')
        $result = Invoke-TokenReplacement -content $lines -tokens $catalog
        $result | Should -Match 'Notebook'
        $result | Should -Match 'SemanticModel'
        $result | Should -Match 'Report'
    }

    It 'resolves tokens inside the appended default rows' {
        # The default rows reference #{Home.Workspace.Id}# — verify it is substituted
        $lines  = @()
        $result = Invoke-TokenReplacement -content $lines -tokens $catalog
        $result | Should -Match 'ws-abc'
        $result | Should -Not -Match '#{Home.Workspace.Id}#'
    }

    It 'joins all rows with CRLF' {
        $lines  = @('line1', 'line2')
        $result = Invoke-TokenReplacement -content $lines -tokens $catalog
        $result | Should -Match "`r`n"
    }

    It 'returns a single string, not an array' {
        $lines  = @('a', 'b')
        $result = Invoke-TokenReplacement -content $lines -tokens $catalog
        ($result -is [string]) | Should -Be $true
    }
}

# =============================================================================
Describe 'Update-JsonValues' {

    BeforeAll {
        # Suppress Write-Host from Write-Message "Debug" calls inside Update-JsonValues
        Mock Write-Message { }

        function New-TestJson {
            return @{
                name   = 'original'
                nested = @{ value = 'old'; level2 = @{ deep = 'deep-old' } }
                items  = @(
                    @{ name = 'first';  value = 'v1' }
                    @{ name = 'second'; value = 'v2' }
                )
            } | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        }
    }

    Context 'top-level property' {
        It 'updates a simple top-level string property' {
            $json   = New-TestJson
            $result = Update-JsonValues -csvData @{ 'name' = 'updated' } -jsonObject $json
            $result.name | Should -Be 'updated'
        }
        It 'returns the same object (mutates in place)' {
            $json   = New-TestJson
            $result = Update-JsonValues -csvData @{ 'name' = 'x' } -jsonObject $json
            [object]::ReferenceEquals($result, $json) | Should -Be $true
        }
    }

    Context 'nested property via dot-separated path' {
        It 'updates a property one level deep' {
            $json   = New-TestJson
            $result = Update-JsonValues -csvData @{ 'nested.value' = 'new-value' } -jsonObject $json
            $result.nested.value | Should -Be 'new-value'
        }
        It 'updates a property two levels deep' {
            $json   = New-TestJson
            $result = Update-JsonValues -csvData @{ 'nested.level2.deep' = 'deep-new' } -jsonObject $json
            $result.nested.level2.deep | Should -Be 'deep-new'
        }
        It 'leaves sibling properties untouched' {
            $json   = New-TestJson
            $result = Update-JsonValues -csvData @{ 'nested.value' = 'changed' } -jsonObject $json
            $result.name | Should -Be 'original'
        }
    }

    Context 'array index access [n]' {
        It 'updates the element at index 0' {
            $json   = New-TestJson
            $result = Update-JsonValues -csvData @{ 'items[0].value' = 'first-updated' } -jsonObject $json
            $result.items[0].value | Should -Be 'first-updated'
        }
        It 'updates the element at index 1' {
            $json   = New-TestJson
            $result = Update-JsonValues -csvData @{ 'items[1].value' = 'second-updated' } -jsonObject $json
            $result.items[1].value | Should -Be 'second-updated'
        }
        It 'leaves other array elements untouched when updating by index' {
            $json   = New-TestJson
            $result = Update-JsonValues -csvData @{ 'items[0].value' = 'first-updated' } -jsonObject $json
            $result.items[1].value | Should -Be 'v2'
        }
    }

    Context "named array item ['name'] - implicit .name shorthand" {
        It "updates the property on the element whose name matches" {
            $json   = New-TestJson
            $result = Update-JsonValues -csvData @{ "items['second'].value" = 'second-updated' } -jsonObject $json
            $result.items[1].value | Should -Be 'second-updated'
        }
        It 'leaves unmatched elements untouched when updating by name' {
            $json   = New-TestJson
            $result = Update-JsonValues -csvData @{ "items['second'].value" = 'second-updated' } -jsonObject $json
            $result.items[0].value | Should -Be 'v1'
        }
    }

    Context "named array item ['prop=value'] - explicit property match" {
        It "matches by an explicit 'name=' prefix (same as implicit shorthand)" {
            $json   = New-TestJson
            $result = Update-JsonValues -csvData @{ "items['name=second'].value" = 'explicit-updated' } -jsonObject $json
            $result.items[1].value | Should -Be 'explicit-updated'
        }
        It 'matches by a property other than .name' {
            $json   = New-TestJson
            $result = Update-JsonValues -csvData @{ "items['value=v1'].name" = 'renamed-first' } -jsonObject $json
            $result.items[0].name | Should -Be 'renamed-first'
        }
        It 'leaves other elements untouched when matching by non-name property' {
            $json   = New-TestJson
            $result = Update-JsonValues -csvData @{ "items['value=v1'].name" = 'renamed-first' } -jsonObject $json
            $result.items[1].name | Should -Be 'second'
        }
        It 'does not corrupt siblings when prop=value has no match' {
            $json   = New-TestJson
            $result = Update-JsonValues -csvData @{ "items['value=nosuch'].name" = 'bad' } -jsonObject $json
            $result.items[0].name | Should -Be 'first'
            $result.items[1].name | Should -Be 'second'
        }
        It 'matches by .id property (models the known_lakehouses scenario)' {
            $json = @{
                lakehouses = @(
                    @{ id = 'aaaa-1111'; displayName = 'LH_A' }
                    @{ id = 'bbbb-2222'; displayName = 'LH_B' }
                )
            } | ConvertTo-Json -Depth 5 | ConvertFrom-Json

            $result = Update-JsonValues -csvData @{ "lakehouses['id=bbbb-2222'].displayName" = 'LH_B_Updated' } -jsonObject $json
            $result.lakehouses[1].displayName | Should -Be 'LH_B_Updated'
            $result.lakehouses[0].displayName | Should -Be 'LH_A'
        }
    }

    Context 'array wildcard [*]' {
        It 'updates the property on every element in the array' {
            $json   = New-TestJson
            $result = Update-JsonValues -csvData @{ 'items[*].value' = 'all' } -jsonObject $json
            $result.items[0].value | Should -Be 'all'
            $result.items[1].value | Should -Be 'all'
        }
    }

    Context 'array element as final target - numeric index [n]' {
        BeforeAll {
            function New-LakehouseJson {
                return @{
                    dependencies = @{
                        lakehouse = @{
                            default_lakehouse = 'old-guid'
                            known_lakehouses  = @(
                                @{ id = 'aaa-111' }
                                @{ id = 'bbb-222' }
                            )
                        }
                    }
                } | ConvertTo-Json -Depth 10 | ConvertFrom-Json
            }
        }

        It 'replaces the whole element at index 0 with a JSON object' {
            $json   = New-LakehouseJson
            $result = Update-JsonValues -csvData @{ 'dependencies.lakehouse.known_lakehouses[0]' = '{"id":"new-111"}' } -jsonObject $json
            $result.dependencies.lakehouse.known_lakehouses[0].id | Should -Be 'new-111'
        }
        It 'leaves the other element untouched when replacing by index' {
            $json   = New-LakehouseJson
            $result = Update-JsonValues -csvData @{ 'dependencies.lakehouse.known_lakehouses[0]' = '{"id":"new-111"}' } -jsonObject $json
            $result.dependencies.lakehouse.known_lakehouses[1].id | Should -Be 'bbb-222'
        }
        It 'leaves siblings unchanged when the final index is out of bounds' {
            $json   = New-LakehouseJson
            $result = Update-JsonValues -csvData @{ 'dependencies.lakehouse.known_lakehouses[99]' = '{"id":"bad"}' } -jsonObject $json
            $result.dependencies.lakehouse.known_lakehouses[0].id | Should -Be 'aaa-111'
            $result.dependencies.lakehouse.known_lakehouses[1].id | Should -Be 'bbb-222'
        }
    }

    Context 'array element as final target - wildcard [*]' {
        It 'replaces every element in the array with the new JSON object' {
            $json = @{
                items = @( @{ id = 'x' }; @{ id = 'y' } )
            } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
            $result = Update-JsonValues -csvData @{ 'items[*]' = '{"id":"replaced"}' } -jsonObject $json
            $result.items[0].id | Should -Be 'replaced'
            $result.items[1].id | Should -Be 'replaced'
        }
    }

    Context "array element as final target - named ['prop=value']" {
        It 'replaces the matching element and leaves others untouched' {
            $json = @{
                known_lakehouses = @(
                    @{ id = 'aaa-111' }
                    @{ id = 'bbb-222' }
                )
            } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
            $result = Update-JsonValues -csvData @{ "known_lakehouses['id=aaa-111']" = '{"id":"new-aaa"}' } -jsonObject $json
            $result.known_lakehouses[0].id | Should -Be 'new-aaa'
            $result.known_lakehouses[1].id | Should -Be 'bbb-222'
        }
    }

    Context 'JSON-valued replacement' {
        It 'parses a JSON object value and assigns the resulting object' {
            $json      = New-TestJson
            $jsonValue = '{"key":"val","num":42}'
            $result    = Update-JsonValues -csvData @{ 'name' = $jsonValue } -jsonObject $json
            $result.name.key | Should -Be 'val'
            $result.name.num | Should -Be 42
        }
        It 'parses a JSON array value and assigns the resulting array' {
            $json   = New-TestJson
            $result = Update-JsonValues -csvData @{ 'name' = '["a","b"]' } -jsonObject $json
            $result.name[0] | Should -Be 'a'
            $result.name[1] | Should -Be 'b'
        }
        It 'assigns a plain string when the value is not valid JSON' {
            $json   = New-TestJson
            $result = Update-JsonValues -csvData @{ 'name' = 'just a string' } -jsonObject $json
            $result.name | Should -Be 'just a string'
        }
        It 'keeps a numeric string as a string without coercing to integer' {
            $json   = New-TestJson
            $result = Update-JsonValues -csvData @{ 'name' = '1433' } -jsonObject $json
            $result.name            | Should -Be '1433'
            $result.name.GetType().Name | Should -Be 'String'
        }
        It 'keeps a boolean-like string as a string without coercing to bool' {
            $json   = New-TestJson
            $result = Update-JsonValues -csvData @{ 'name' = 'true' } -jsonObject $json
            $result.name            | Should -Be 'true'
            $result.name.GetType().Name | Should -Be 'String'
        }
        It 'keeps a null-like string as a string without coercing to null' {
            $json   = New-TestJson
            $result = Update-JsonValues -csvData @{ 'name' = 'null' } -jsonObject $json
            $result.name            | Should -Be 'null'
            $result.name.GetType().Name | Should -Be 'String'
        }
    }

    Context 'missing or invalid paths' {
        It 'leaves the object unchanged when the top-level path does not exist' {
            $json   = New-TestJson
            $result = Update-JsonValues -csvData @{ 'nonexistent' = 'x' } -jsonObject $json
            $result.name | Should -Be 'original'
        }
        It 'leaves the object unchanged when a nested path does not exist' {
            $json   = New-TestJson
            $result = Update-JsonValues -csvData @{ 'nested.missing' = 'x' } -jsonObject $json
            $result.nested.value | Should -Be 'old'
        }
        It 'handles an empty csvData hashtable without error' {
            $json   = New-TestJson
            $result = Update-JsonValues -csvData @{} -jsonObject $json
            $result.name | Should -Be 'original'
        }
        It 'does not corrupt siblings when a named array lookup fails' {
            $json   = New-TestJson
            $result = Update-JsonValues -csvData @{ "items['nosuchname'].value" = 'bad' } -jsonObject $json
            $result.items[0].value | Should -Be 'v1'
            $result.items[1].value | Should -Be 'v2'
        }
        It 'does not corrupt siblings when an array index is out of bounds' {
            $json   = New-TestJson
            $result = Update-JsonValues -csvData @{ 'items[99].value' = 'bad' } -jsonObject $json
            $result.items[0].value | Should -Be 'v1'
            $result.items[1].value | Should -Be 'v2'
        }
        It 'does not corrupt siblings when the array property does not exist' {
            $json   = New-TestJson
            $result = Update-JsonValues -csvData @{ 'noarray[0].value' = 'bad' } -jsonObject $json
            $result.name | Should -Be 'original'
        }
    }
}

# =============================================================================
Describe 'Set-PropertyPath' {

    BeforeAll {
        Mock Write-Message { }

        function New-NodeJson {
            return @{
                value  = 'original'
                nested = @{ inner = 'inner-original' }
            } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        }
    }

    Context 'single-segment path (direct property)' {
        It 'updates the property at the node' {
            $node = New-NodeJson
            Set-PropertyPath -node $node -remainingPath 'value' -value 'changed'
            $node.value | Should -Be 'changed'
        }
    }

    Context 'multi-segment path' {
        It 'traverses nested objects and updates the final property' {
            $node = New-NodeJson
            Set-PropertyPath -node $node -remainingPath 'nested.inner' -value 'inner-changed'
            $node.nested.inner | Should -Be 'inner-changed'
        }
    }

    Context 'JSON-valued replacement' {
        It 'parses a JSON object value and assigns the resulting object' {
            $node = New-NodeJson
            Set-PropertyPath -node $node -remainingPath 'value' -value '{"parsed":true}'
            $node.value.parsed | Should -Be $true
        }
        It 'keeps a numeric string as a string without coercing to integer' {
            $node = New-NodeJson
            Set-PropertyPath -node $node -remainingPath 'value' -value '1433'
            $node.value            | Should -Be '1433'
            $node.value.GetType().Name | Should -Be 'String'
        }
        It 'keeps a boolean-like string as a string without coercing to bool' {
            $node = New-NodeJson
            Set-PropertyPath -node $node -remainingPath 'value' -value 'true'
            $node.value            | Should -Be 'true'
            $node.value.GetType().Name | Should -Be 'String'
        }
    }

    Context 'missing path' {
        It 'returns without error when an intermediate segment does not exist' {
            $node = New-NodeJson
            { Set-PropertyPath -node $node -remainingPath 'missing.path' -value 'x' } | Should -Not -Throw
        }
        It 'leaves other properties untouched when the path is missing' {
            $node = New-NodeJson
            Set-PropertyPath -node $node -remainingPath 'missing.path' -value 'x'
            $node.value | Should -Be 'original'
        }
    }

    Context 'array index in remainingPath' {
        BeforeAll {
            function New-ArrayNodeJson {
                return @{
                    items = @(
                        @{ id = 'a'; val = 'original-a' }
                        @{ id = 'b'; val = 'original-b' }
                    )
                } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
            }
        }

        It 'updates the element at a numeric index within remainingPath' {
            $node = New-ArrayNodeJson
            Set-PropertyPath -node $node -remainingPath 'items[0].val' -value 'updated-a'
            $node.items[0].val | Should -Be 'updated-a'
        }
        It 'leaves other elements untouched when updating by index in remainingPath' {
            $node = New-ArrayNodeJson
            Set-PropertyPath -node $node -remainingPath 'items[0].val' -value 'updated-a'
            $node.items[1].val | Should -Be 'original-b'
        }
        It 'updates all elements via wildcard in remainingPath' {
            $node = New-ArrayNodeJson
            Set-PropertyPath -node $node -remainingPath 'items[*].val' -value 'all'
            $node.items[0].val | Should -Be 'all'
            $node.items[1].val | Should -Be 'all'
        }
        It 'leaves other properties untouched when array index is out of bounds in remainingPath' {
            $node = New-ArrayNodeJson
            Set-PropertyPath -node $node -remainingPath 'items[99].val' -value 'bad'
            $node.items[0].val | Should -Be 'original-a'
        }
    }

    Context 'array element as final target in remainingPath' {
        BeforeAll {
            function New-FinalArrayNodeJson {
                return @{
                    items = @(
                        @{ id = 'x'; label = 'X' }
                        @{ id = 'y'; label = 'Y' }
                    )
                } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
            }
        }

        It 'replaces the whole element at index 0' {
            $node = New-FinalArrayNodeJson
            Set-PropertyPath -node $node -remainingPath 'items[0]' -value '{"id":"new","label":"New"}'
            $node.items[0].id | Should -Be 'new'
        }
        It 'leaves the other element untouched when replacing by final index' {
            $node = New-FinalArrayNodeJson
            Set-PropertyPath -node $node -remainingPath 'items[0]' -value '{"id":"new","label":"New"}'
            $node.items[1].id | Should -Be 'y'
        }
        It 'replaces all elements via [*] as final target' {
            $node = New-FinalArrayNodeJson
            Set-PropertyPath -node $node -remainingPath 'items[*]' -value '{"id":"all"}'
            $node.items[0].id | Should -Be 'all'
            $node.items[1].id | Should -Be 'all'
        }
        It 'leaves siblings untouched when final index is out of bounds' {
            $node = New-FinalArrayNodeJson
            Set-PropertyPath -node $node -remainingPath 'items[99]' -value '{"id":"bad"}'
            $node.items[0].id | Should -Be 'x'
            $node.items[1].id | Should -Be 'y'
        }
    }
}

# =============================================================================
Describe 'New-AzdoConfig' {

    It 'returns a PSCustomObject with all six properties populated' {
        $config = New-AzdoConfig `
            -AzdoBaseUrl         'https://dev.azure.com' `
            -OrganizationName    'myOrg' `
            -ProjectName         'myProject' `
            -RepositoryName      'myRepo' `
            -SourceBranchName    'main' `
            -DevOpsRequestHeader @{ Authorization = 'Bearer tok' }
        $config.AzdoBaseUrl                       | Should -Be 'https://dev.azure.com'
        $config.OrganizationName                  | Should -Be 'myOrg'
        $config.ProjectName                       | Should -Be 'myProject'
        $config.RepositoryName                    | Should -Be 'myRepo'
        $config.SourceBranchName                  | Should -Be 'main'
        $config.DevOpsRequestHeader.Authorization | Should -Be 'Bearer tok'
    }

    It 'defaults all properties to null when called with no arguments' {
        $config = New-AzdoConfig
        $config.AzdoBaseUrl         | Should -BeNullOrEmpty
        $config.OrganizationName    | Should -BeNullOrEmpty
        $config.ProjectName         | Should -BeNullOrEmpty
        $config.RepositoryName      | Should -BeNullOrEmpty
        $config.SourceBranchName    | Should -BeNullOrEmpty
        $config.DevOpsRequestHeader | Should -BeNullOrEmpty
    }
}

# =============================================================================
Describe 'Get-DeploymentCsvContent' {

    BeforeAll {
        . "$PSScriptRoot\..\private\GitFunctions.ps1"
    }

    BeforeEach {
        $testConfig = New-AzdoConfig `
            -AzdoBaseUrl         'https://dev.azure.com' `
            -OrganizationName    'testOrg' `
            -ProjectName         'testProject' `
            -RepositoryName      'testRepo' `
            -DevOpsRequestHeader @{ Authorization = 'Bearer test' }

        Mock Get-RemoteFile { return '.\temp\deploy\config.csv' }
        Mock Get-FileContent { return "name,type,jsonPath,token`r`nrow1,Notebook,/path,tok1" }
    }

    Context 'URL construction' {
        It 'builds the ADO items URL from AzdoConfig properties' {
            Get-DeploymentCsvContent -configFilePath '/deploy/config.csv' -branchName 'main' -AzdoConfig $testConfig
            Should -Invoke Get-RemoteFile -ParameterFilter {
                $DownloadUrl -like 'https://dev.azure.com/testOrg/testProject/_apis/git/repositories/testRepo/items*'
            }
        }

        It 'includes the branch name in the URL version descriptor' {
            Get-DeploymentCsvContent -configFilePath '/deploy/config.csv' -branchName 'feature/my-branch' -AzdoConfig $testConfig
            Should -Invoke Get-RemoteFile -ParameterFilter {
                $DownloadUrl -like '*versionDescriptor.version=feature/my-branch*'
            }
        }

        It 'strips the refs/heads/ prefix from the branch name in the URL' {
            Get-DeploymentCsvContent -configFilePath '/deploy/config.csv' -branchName 'refs/heads/main' -AzdoConfig $testConfig
            Should -Invoke Get-RemoteFile -ParameterFilter {
                $DownloadUrl -like '*versionDescriptor.version=main*' -and $DownloadUrl -notlike '*refs/heads*'
            }
        }

        It 'passes the DevOpsRequestHeader from AzdoConfig to Get-RemoteFile' {
            Get-DeploymentCsvContent -configFilePath '/deploy/config.csv' -branchName 'main' -AzdoConfig $testConfig
            Should -Invoke Get-RemoteFile -ParameterFilter {
                $Headers.Authorization -eq 'Bearer test'
            }
        }
    }

    Context 'content handling' {
        It 'returns the fallback header row when Get-FileContent returns null' {
            Mock Get-FileContent { return $null }
            $result = Get-DeploymentCsvContent -configFilePath '/deploy/config.csv' -branchName 'main' -AzdoConfig $testConfig
            $result | Should -Contain 'name,type,jsonPath,token'
        }

        It 'splits CRLF-separated content into an array of rows' {
            Mock Get-FileContent { return "header`r`nrow1`r`nrow2" }
            $result = Get-DeploymentCsvContent -configFilePath '/deploy/config.csv' -branchName 'main' -AzdoConfig $testConfig
            @($result) | Should -HaveCount 3
        }

        It 'splits LF-only content into an array of rows' {
            Mock Get-FileContent { return "header`nrow1`nrow2" }
            $result = Get-DeploymentCsvContent -configFilePath '/deploy/config.csv' -branchName 'main' -AzdoConfig $testConfig
            @($result) | Should -HaveCount 3
        }
    }
}

# =============================================================================
Describe 'New-GitBranch' {

    BeforeAll {
        . "$PSScriptRoot\..\private\GitFunctions.ps1"
        Mock Write-Message { }
    }

    BeforeEach {
        $testConfig = New-AzdoConfig `
            -AzdoBaseUrl         'https://dev.azure.com' `
            -OrganizationName    'testOrg' `
            -ProjectName         'testProject' `
            -RepositoryName      'testRepo' `
            -SourceBranchName    'main' `
            -DevOpsRequestHeader @{ Authorization = 'Bearer test' }

        # Default mock: returns a valid branch on list-refs, success on create.
        Mock Invoke-ApiEndpoint {
            if ($endPoint -like '*filter=heads*') {
                $content = '{"value":[{"name":"refs/heads/main","objectid":"abc123"}]}'
            } else {
                $content = '{"value":[{"repositoryId":"repo-123"}]}'
            }
            return [PSCustomObject]@{
                responseObject = [PSCustomObject]@{ StatusCode = 200; Content = $content }
                isException    = $false
            }
        }
    }

    Context 'URL construction' {
        It 'lists refs using org/project/repo from AzdoConfig' {
            New-GitBranch -newBranchName 'workspace/ws_test' -AzdoConfig $testConfig | Out-Null
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter {
                $endPoint -like '/testOrg/testProject/_apis/git/repositories/testRepo/refs*'
            }
        }

        It 'filters by SourceBranchName from AzdoConfig' {
            New-GitBranch -newBranchName 'workspace/ws_test' -AzdoConfig $testConfig | Out-Null
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter {
                $endPoint -like '*filter=heads/main*'
            }
        }

        It 'throws when the source branch is not found' {
            $cfg = New-AzdoConfig -AzdoBaseUrl 'https://dev.azure.com' -OrganizationName 'testOrg' `
                -ProjectName 'testProject' -RepositoryName 'testRepo' -SourceBranchName 'main'
            Mock Invoke-ApiEndpoint {
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}' }
                    isException    = $false
                }
            }
            { New-GitBranch -newBranchName 'new-branch' -AzdoConfig $cfg } | Should -Throw -ExpectedMessage "*main*wasn't found*"
        }
    }
}

# =============================================================================
Describe 'Test-DevOpsRepoPath' {

    BeforeAll {
        . "$PSScriptRoot\..\private\GitFunctions.ps1"
        Mock Write-Message { }
    }

    BeforeEach {
        $testConfig = New-AzdoConfig `
            -AzdoBaseUrl         'https://dev.azure.com' `
            -OrganizationName    'testOrg' `
            -ProjectName         'testProject' `
            -RepositoryName      'testRepo' `
            -SourceBranchName    'main'
    }

    Context 'URL construction' {
        It 'builds the endpoint using org/project/repo from AzdoConfig' {
            Mock Invoke-ApiEndpoint {
                return [PSCustomObject]@{ responseObject = [PSCustomObject]@{ StatusCode = 200 }; isException = $false }
            }
            Test-DevOpsRepoPath -gitPath '/some/file.csv' -AzdoConfig $testConfig
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter {
                $endPoint -like '/testOrg/testProject/_apis/git/repositories/testRepo/items*'
            }
        }

        It 'uses SourceBranchName from AzdoConfig when no explicit branchName is given' {
            Mock Invoke-ApiEndpoint {
                return [PSCustomObject]@{ responseObject = [PSCustomObject]@{ StatusCode = 200 }; isException = $false }
            }
            Test-DevOpsRepoPath -gitPath '/some/file.csv' -AzdoConfig $testConfig
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter {
                $endPoint -like '*versionDescriptor.version=main*'
            }
        }

        It 'explicit branchName takes priority over AzdoConfig.SourceBranchName' {
            Mock Invoke-ApiEndpoint {
                return [PSCustomObject]@{ responseObject = [PSCustomObject]@{ StatusCode = 200 }; isException = $false }
            }
            Test-DevOpsRepoPath -gitPath '/some/file.csv' -branchName 'feature/override' -AzdoConfig $testConfig
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter {
                $endPoint -like '*versionDescriptor.version=feature/override*'
            }
        }

        It 'strips the refs/heads/ prefix from the resolved branch name' {
            Mock Invoke-ApiEndpoint {
                return [PSCustomObject]@{ responseObject = [PSCustomObject]@{ StatusCode = 200 }; isException = $false }
            }
            Test-DevOpsRepoPath -gitPath '/some/file.csv' -branchName 'refs/heads/main' -AzdoConfig $testConfig
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter {
                $endPoint -like '*versionDescriptor.version=main*' -and $endPoint -notlike '*refs/heads*'
            }
        }
    }

    Context 'return value' {
        It 'returns true when the API responds 200' {
            Mock Invoke-ApiEndpoint {
                return [PSCustomObject]@{ responseObject = [PSCustomObject]@{ StatusCode = 200 }; isException = $false }
            }
            Test-DevOpsRepoPath -gitPath '/file.csv' -AzdoConfig $testConfig | Should -Be $true
        }

        It 'returns false when the API responds 404' {
            Mock Invoke-ApiEndpoint {
                return [PSCustomObject]@{ responseObject = [PSCustomObject]@{ StatusCode = 404 }; isException = $false }
            }
            Test-DevOpsRepoPath -gitPath '/file.csv' -AzdoConfig $testConfig | Should -Be $false
        }

        It 'throws on any other status code' {
            Mock Invoke-ApiEndpoint {
                return [PSCustomObject]@{
                    responseObject = [PSCustomObject]@{ StatusCode = 500; Content = '{"errorCode":"ServerError","message":"boom"}' }
                    isException    = $false
                }
            }
            { Test-DevOpsRepoPath -gitPath '/file.csv' -AzdoConfig $testConfig } | Should -Throw
        }
    }
}

# =============================================================================
Describe 'Copy-DevOpsRepoBranchRestAPI' {

    BeforeAll {
        . "$PSScriptRoot\..\private\GitFunctions.ps1"
        Mock Write-Message { }
    }

    BeforeEach {
        $testConfig = New-AzdoConfig `
            -AzdoBaseUrl         'https://dev.azure.com' `
            -OrganizationName    'testOrg' `
            -ProjectName         'testProject' `
            -RepositoryName      'testRepo' `
            -SourceBranchName    'main' `
            -DevOpsRequestHeader @{ Authorization = 'Bearer test' }

        Mock Invoke-ApiEndpoint {
            $item = [PSCustomObject]@{ path = '/deploy/file.csv'; isFolder = $false }
            $body = @{ value = @($item) } | ConvertTo-Json -Depth 5
            return [PSCustomObject]@{
                responseObject = [PSCustomObject]@{ StatusCode = 200; Content = $body }
                isException    = $false
            }
        }
        Mock Get-RemoteFile { }
        Mock Test-Path { return $false }
        Mock New-Item { }
    }

    Context 'URL construction' {
        It 'lists branch items using org/project/repo from AzdoConfig' {
            Copy-DevOpsRepoBranchRestAPI -gitPath '/deploy' -localFolder '.\temp\test' -AzdoConfig $testConfig
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter {
                $endPoint -like '/testOrg/testProject/_apis/git/repositories/testRepo/items*'
            }
        }

        It 'includes SourceBranchName in the listing endpoint' {
            Copy-DevOpsRepoBranchRestAPI -gitPath '/deploy' -localFolder '.\temp\test' -AzdoConfig $testConfig
            Should -Invoke Invoke-ApiEndpoint -ParameterFilter {
                $endPoint -like '*versionDescriptor.version=main*'
            }
        }
    }

    Context 'file download' {
        It 'passes DevOpsRequestHeader to Get-RemoteFile' {
            Copy-DevOpsRepoBranchRestAPI -gitPath '/deploy' -localFolder '.\temp\test' -AzdoConfig $testConfig
            Should -Invoke Get-RemoteFile -ParameterFilter {
                $Headers.Authorization -eq 'Bearer test'
            }
        }

        It 'builds the download URL using org/project/repo/branch from AzdoConfig' {
            Copy-DevOpsRepoBranchRestAPI -gitPath '/deploy' -localFolder '.\temp\test' -AzdoConfig $testConfig
            Should -Invoke Get-RemoteFile -ParameterFilter {
                $DownloadUrl -like 'https://dev.azure.com/testOrg/testProject/_apis/git/repositories/testRepo/items*'
            }
        }
    }
}
