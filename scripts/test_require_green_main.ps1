# Runs require_green_main.ps1 with stand-ins for git and gh that answer only the calls it should make.
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'require_green_main.ps1'
$failed = $false
$sha = '0123456789abcdef'

function Test-Case([string] $label, [string] $dirty, [string] $state, [string] $run, [bool] $passes) {
    $global:fakeDirty = $dirty; $global:fakeState = $state; $global:fakeRun = $run
    $ok = $true
    try { & $script -Repo x/y *> $null } catch { $ok = $false }
    if ($ok -ne $passes) { Write-Host "FAIL: $label"; $script:failed = $true }
}

function git {
    if ($args[0] -ne '-C' -or $args[1] -ne (Split-Path $PSScriptRoot)) { return }
    if ($args[2] -eq 'status') { $global:fakeDirty } elseif ($args[2] -eq 'rev-parse') { $sha }
}
function gh {
    if ($args[0] -eq 'api') { if ($args[1] -eq "repos/x/y/compare/main...$sha") { $global:fakeState } }
    elseif (($args -join ' ') -like "*--workflow ci.yml --commit $sha*") { $global:fakeRun }
}

$green = '[{"status":"completed","conclusion":"success"}]'
Test-Case "main's tip with a green run" '' 'identical' $green $true
Test-Case 'an older commit of main with a green run' '' 'behind' $green $true
Test-Case 'a commit on another branch' '' 'diverged' $green $false
Test-Case 'a red run' '' 'identical' '[{"status":"completed","conclusion":"failure"}]' $false
Test-Case 'a run still going' '' 'identical' '[{"status":"in_progress","conclusion":""}]' $false
Test-Case 'no run' '' 'identical' '[]' $false
Test-Case 'a dirty tree' ' M file' 'identical' $green $false
if ($failed) { exit 1 }
Write-Host 'require_green_main.ps1 stops where it should'
