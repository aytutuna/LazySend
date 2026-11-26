# Runs require_green_main.ps1 in a throw-away repository with stand-ins for git and gh.
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'require_green_main.ps1'
$failed = $false

function Test-Case([string] $label, [string] $dirty, [string] $state, [string] $run, [bool] $passes) {
    $global:fakeDirty = $dirty; $global:fakeState = $state; $global:fakeRun = $run
    $ok = $true
    try { & $script *> $null } catch { $ok = $false }
    if ($ok -ne $passes) { Write-Host "FAIL: $label"; $script:failed = $true }
}

function git { if ($args[0] -eq 'status') { $global:fakeDirty } else { '0123456789abcdef' } }
function gh { if ($args[0] -eq 'api') { $global:fakeState } else { $global:fakeRun } }

Test-Case "main's tip with a green run" '' 'identical' 'completed success' $true
Test-Case 'an older commit of main with a green run' '' 'behind' 'completed success' $true
Test-Case 'a commit on another branch' '' 'diverged' 'completed success' $false
Test-Case 'a red run' '' 'identical' 'completed failure' $false
Test-Case 'a run still going' '' 'identical' 'in_progress ' $false
Test-Case 'no run' '' 'identical' 'null null' $false
Test-Case 'a dirty tree' ' M file' 'identical' 'completed success' $false
if ($failed) { exit 1 }
Write-Host 'require_green_main.ps1 stops where it should'
