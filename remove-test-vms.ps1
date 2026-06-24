<#
.SYNOPSIS
  Deletes ONLY the test VMs (and their disks/NICs) created by the ODCR test
  suite, leaving the capacity reservation groups, reservations, and the zonal
  policy assignment in place so you can still review them or re-run tests.

  For a FULL cleanup (RG + CRGs + zonal assignment + role), use teardown.ps1.

.PARAMETER Force
  Skip the confirmation prompt.

.EXAMPLE
  .\remove-test-vms.ps1            # prompts, then deletes all odcr-* test VMs
  .\remove-test-vms.ps1 -Force     # no prompt
#>
[CmdletBinding()]
param([switch]$Force)
. "$PSScriptRoot\common.ps1"

$ev  = Initialize-OdcrRun -Name 'remove-vms'
$log = Join-Path $ev 'remove-vms.log'
$evi = Join-Path $ev 'remove-vms-evidence.txt'
Write-Log "=== REMOVE TEST VMs START ===" -Level STEP -LogFile $log
Set-OdcrSubscription -LogFile $log

if ((az group exists -n $Odcr.TestRg) -ne 'true') {
    Write-Log "Resource group '$($Odcr.TestRg)' does not exist - nothing to do." -Level WARN -LogFile $log
    return
}

# Find the test VMs (names start with 'odcr-').
$vms = @(az vm list -g $Odcr.TestRg --query "[?starts_with(name,'odcr-')].name" -o tsv 2>$null) | Where-Object { $_ }
if (-not $vms -or $vms.Count -eq 0) {
    Write-Log "No odcr-* test VMs found in '$($Odcr.TestRg)'." -Level INFO -LogFile $log
    return
}

Write-Log ("Found {0} test VM(s): {1}" -f $vms.Count, ($vms -join ', ')) -Level INFO -LogFile $log
if (-not $Force) {
    $ans = Read-Host "Delete these $($vms.Count) VM(s) and their disks/NICs? (y/N)"
    if ($ans -notin @('y','Y')) { Write-Log "Cancelled." -Level WARN -LogFile $log; return }
}

foreach ($vm in $vms) {
    Remove-OdcrVm -Rg $Odcr.TestRg -Vm $vm -EvidenceFile $evi -LogFile $log
}

# Clean up any leftover NICs from the test VMs (created by New-OdcrNic as
# '<vm>-nic'; VM delete with --nic-delete-option Delete usually removes them,
# but tidy up any stragglers).
$nics = @(az network nic list -g $Odcr.TestRg --query "[?ends_with(name,'-nic') && starts_with(name,'odcr-')].name" -o tsv 2>$null) | Where-Object { $_ }
foreach ($nic in $nics) {
    Write-Log "Removing leftover NIC '$nic'" -Level STEP -LogFile $log
    Invoke-Az -Args @('network','nic','delete','-g',$Odcr.TestRg,'-n',$nic) -EvidenceFile $evi -LogFile $log -AllowFail | Out-Null
}

Write-Log "Reservations and the zonal policy assignment were left in place." -Level INFO -LogFile $log
Write-Log "=== REMOVE TEST VMs COMPLETE ===" -Level OK -LogFile $log
