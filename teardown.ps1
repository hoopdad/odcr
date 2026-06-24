<#
.SYNOPSIS
  Tears down everything the test suite created (cleanup = all):
    * Deletes the test resource group `rg-odcr-tests` (test VMs + zonal CRG).
    * Deletes the regional reservation + CRG `crg-odcr-regional` (leaves the
      pre-existing RG `rg-odcr-regional` in place).
    * Removes the zonal policy assignment and its role assignment.

  Does NOT touch the pre-existing regional policy assignment or the shared
  policy definition.

.PARAMETER Force
  Skip the confirmation prompt.
#>
[CmdletBinding()]
param([switch]$Force)
. "$PSScriptRoot\common.ps1"

$ev  = Initialize-OdcrRun -Name 'teardown'
$log = Join-Path $ev 'teardown.log'
$evi = Join-Path $ev 'teardown-evidence.txt'
Write-Log "=== ODCR TEARDOWN START ===" -Level STEP -LogFile $log
Set-OdcrSubscription -LogFile $log

if (-not $Force) {
    $ans = Read-Host "Delete RG '$($Odcr.TestRg)', CRG '$($Odcr.RegionalCrg)', and zonal assignment '$($Odcr.ZonalAssignName)'? (y/N)"
    if ($ans -notin @('y','Y')) { Write-Log "Teardown cancelled." -Level WARN -LogFile $log; return }
}

$mgScope = "/providers/Microsoft.Management/managementGroups/$($Odcr.PolicyMg)"

# 1) Remove zonal policy assignment + its role assignment.
$principalId = (az policy assignment show --name $Odcr.ZonalAssignName --scope $mgScope --query identity.principalId -o tsv 2>$null)
if ($principalId) {
    Write-Log "Removing role assignment for identity $principalId" -Level STEP -LogFile $log
    Invoke-Az -Args @('role','assignment','delete','--assignee',$principalId,'--role',$Odcr.VmContributorRoleId,'--scope',$mgScope) -EvidenceFile $evi -LogFile $log -AllowFail | Out-Null
}
Write-Log "Removing zonal policy assignment '$($Odcr.ZonalAssignName)'" -Level STEP -LogFile $log
Invoke-Az -Args @('policy','assignment','delete','--name',$Odcr.ZonalAssignName,'--scope',$mgScope) -EvidenceFile $evi -LogFile $log -AllowFail | Out-Null

# 2) Delete the test RG (removes any leftover VMs, vnets, and the zonal CRG).
if ((az group exists -n $Odcr.TestRg) -eq 'true') {
    Write-Log "Deleting resource group '$($Odcr.TestRg)' (this also removes the zonal CRG)" -Level STEP -LogFile $log
    Invoke-Az -Args @('group','delete','-n',$Odcr.TestRg,'--yes') -EvidenceFile $evi -LogFile $log -AllowFail | Out-Null
}

# 3) Delete the regional reservation + CRG (leave the shared RG intact).
Write-Log "Deleting regional reservation + CRG '$($Odcr.RegionalCrg)'" -Level STEP -LogFile $log
Invoke-Az -Args @('capacity','reservation','delete','-g',$Odcr.RegionalCrgRg,'-c',$Odcr.RegionalCrg,'-n',$Odcr.RegionalRes,'--yes') -EvidenceFile $evi -LogFile $log -AllowFail | Out-Null
Invoke-Az -Args @('capacity','reservation','group','delete','-g',$Odcr.RegionalCrgRg,'-n',$Odcr.RegionalCrg,'--yes') -EvidenceFile $evi -LogFile $log -AllowFail | Out-Null

Write-Log "=== ODCR TEARDOWN COMPLETE ===" -Level OK -LogFile $log
