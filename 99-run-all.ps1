<#
.SYNOPSIS
  Runs the full ODCR test suite: setup -> test 1..4 -> summary -> optional teardown.

.PARAMETER Tests
  Which tests to run (default 1,2,3,4).

.PARAMETER SkipSetup
  Skip 00-setup-odcr.ps1 (assume CRGs/assignment already exist).

.PARAMETER Teardown
  Run teardown.ps1 at the end (delete RG + CRGs + zonal assignment).

.EXAMPLE
  ./99-run-all.ps1 -Teardown
#>
[CmdletBinding()]
param(
    [int[]]$Tests = @(1,2,3,4),
    [switch]$SkipSetup,
    [switch]$Teardown
)
. "$PSScriptRoot\common.ps1"
Initialize-OdcrRun -Name 'run' | Out-Null

$log = Join-Path $script:OdcrRunDir 'run-all.log'
Write-Log "######## ODCR TEST SUITE RUN START ########" -Level STEP -LogFile $log
Write-Log "Run dir: $script:OdcrRunDir" -Level INFO -LogFile $log

$scripts = @{
    1 = '01-test-regional-tag-at-create.ps1'
    2 = '02-test-regional-tag-after-start.ps1'
    3 = '03-test-zonal-tag-at-create.ps1'
    4 = '04-test-zonal-tag-after-start.ps1'
}

# Pass the shared run dir to child scripts so all evidence lands together.
$env:ODCR_EVIDENCEROOT = $script:Odcr.EvidenceRoot
$env:ODCR_RUN_DIR = $script:OdcrRunDir

if (-not $SkipSetup) {
    Write-Log "Running setup..." -Level STEP -LogFile $log
    & "$PSScriptRoot\00-setup-odcr.ps1"
} else {
    Write-Log "Skipping setup (-SkipSetup)" -Level WARN -LogFile $log
}

foreach ($t in $Tests) {
    if (-not $scripts.Contains($t)) { Write-Log "Unknown test $t" -Level WARN -LogFile $log; continue }
    Write-Log "---- Running TEST $t : $($scripts[$t]) ----" -Level STEP -LogFile $log
    try {
        & (Join-Path $PSScriptRoot $scripts[$t])
    } catch {
        Write-Log "TEST $t threw: $($_.Exception.Message)" -Level ERROR -LogFile $log
        Write-OdcrResult -TestId "TEST$t" -Title "$($scripts[$t]) (errored)" -Result 'INCONCLUSIVE' `
            -Criteria @{ 'Completed without exception' = $false } -Notes $_.Exception.Message
    }
}

# --- Summary ---------------------------------------------------------------
Write-Log "######## SUMMARY ########" -Level STEP -LogFile $log
$resultsPath = Join-Path $script:OdcrRunDir 'results.json'
if (Test-Path $resultsPath) {
    $all = @(Get-Content $resultsPath -Raw | ConvertFrom-Json)
    $all | ForEach-Object { Write-Log ("{0,-6} {1,-13} {2}" -f $_.TestId, $_.Result, $_.Title) -Level ($(if($_.Result -eq 'PASS'){'OK'}elseif($_.Result -eq 'FAIL'){'ERROR'}else{'WARN'})) -LogFile $log }
    Write-Host ""
    Write-Host "Markdown summary: $(Join-Path $script:OdcrRunDir 'results.md')" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "Test VMs were LEFT RUNNING in RG '$($Odcr.TestRg)' for portal review." -ForegroundColor Yellow
Write-Host "  Review reservations: portal -> Capacity Reservation Groups ('$($Odcr.RegionalCrg)', '$($Odcr.ZonalCrg)')." -ForegroundColor Yellow
Write-Host "  Delete VMs only : .\remove-test-vms.ps1" -ForegroundColor Yellow
Write-Host "  Delete EVERYTHING: .\teardown.ps1" -ForegroundColor Yellow

if ($Teardown) {
    Write-Log "Running teardown..." -Level STEP -LogFile $log
    & "$PSScriptRoot\teardown.ps1" -Force
}

Write-Log "######## ODCR TEST SUITE RUN COMPLETE ########" -Level STEP -LogFile $log
