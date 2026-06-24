<#
.SYNOPSIS
    ODCR / capacity-reservation setup for the test suite.

    Creates:
      * Regional CRG `crg-odcr-regional` in RG `rg-odcr-regional` (NCUS) with a
        Standard_D2s_v3 reservation. This is the CRG the EXISTING management-group
        policy assignment already points at (tests 1 & 2).
      * Zonal CRG `odcr-zonal-westus3-z2` in RG `rg-odcr-tests` (westus3, zone 2)
        with a Standard_D2s_v3 reservation (tests 3 & 4).
      * A second policy assignment that reuses the existing definition
        ("vm-cr-assignment") targeting the zonal CRG, with a system-assigned
        managed identity granted Virtual Machine Contributor.

    Idempotent: re-running skips resources that already exist.
#>
[CmdletBinding()]
param()
. "$PSScriptRoot\common.ps1"

$ev  = Initialize-OdcrRun -Name 'setup'
$log = Join-Path $ev 'setup.log'
$evi = Join-Path $ev 'setup-evidence.txt'
Write-Log "=== ODCR SETUP START ===" -Level STEP -LogFile $log

Set-OdcrSubscription -LogFile $log

# --- Resource groups -------------------------------------------------------
Write-Log "Ensuring resource groups exist" -Level STEP -LogFile $log
$rgCrgExists = (az group exists -n $Odcr.RegionalCrgRg)
if ($rgCrgExists -ne 'true') {
    Invoke-Az -Args @('group','create','-n',$Odcr.RegionalCrgRg,'-l',$Odcr.RegionalRegion,'-o','json') -EvidenceFile $evi -LogFile $log | Out-Null
}
$rgTestExists = (az group exists -n $Odcr.TestRg)
if ($rgTestExists -ne 'true') {
    Invoke-Az -Args @('group','create','-n',$Odcr.TestRg,'-l',$Odcr.TestRgRegion,'-o','json') -EvidenceFile $evi -LogFile $log | Out-Null
}

# --- Regional CRG + reservation (tests 1 & 2) ------------------------------
Write-Log "Ensuring REGIONAL CRG '$($Odcr.RegionalCrg)' (NCUS regional)" -Level STEP -LogFile $log
$crgShow = Invoke-Az -Args @('capacity','reservation','group','show','-g',$Odcr.RegionalCrgRg,'-n',$Odcr.RegionalCrg,'-o','json') -EvidenceFile $evi -LogFile $log -AllowFail
if (-not $crgShow.Json) {
    Invoke-Az -Args @('capacity','reservation','group','create','-g',$Odcr.RegionalCrgRg,'-n',$Odcr.RegionalCrg,'-l',$Odcr.RegionalRegion,'-o','json') -EvidenceFile $evi -LogFile $log | Out-Null
    Write-Log "Created regional CRG (regional scope, no zones)" -Level OK -LogFile $log
} else {
    Write-Log "Regional CRG already exists" -Level INFO -LogFile $log
}
$resShow = Invoke-Az -Args @('capacity','reservation','show','-g',$Odcr.RegionalCrgRg,'-c',$Odcr.RegionalCrg,'-n',$Odcr.RegionalRes,'-o','json') -EvidenceFile $evi -LogFile $log -AllowFail
if (-not $resShow.Json) {
    Write-Log "Creating regional reservation '$($Odcr.RegionalRes)' ($($Odcr.Sku) x$($Odcr.ReservedQty))" -Level STEP -LogFile $log
    Invoke-Az -Args @('capacity','reservation','create','-g',$Odcr.RegionalCrgRg,'-c',$Odcr.RegionalCrg,'-n',$Odcr.RegionalRes,
        '--sku',$Odcr.Sku,'--capacity',"$($Odcr.ReservedQty)",'-l',$Odcr.RegionalRegion,'-o','json') -EvidenceFile $evi -LogFile $log | Out-Null
    Write-Log "Regional reservation created" -Level OK -LogFile $log
} else {
    Write-Log "Regional reservation already exists" -Level INFO -LogFile $log
}

# --- Zonal CRG + reservation (tests 3 & 4) ---------------------------------
Write-Log "Ensuring ZONAL CRG '$($Odcr.ZonalCrg)' ($($Odcr.ZonalRegion) zone $($Odcr.ZonalZone))" -Level STEP -LogFile $log
$zCrgShow = Invoke-Az -Args @('capacity','reservation','group','show','-g',$Odcr.TestRg,'-n',$Odcr.ZonalCrg,'-o','json') -EvidenceFile $evi -LogFile $log -AllowFail
if (-not $zCrgShow.Json) {
    Invoke-Az -Args @('capacity','reservation','group','create','-g',$Odcr.TestRg,'-n',$Odcr.ZonalCrg,'-l',$Odcr.ZonalRegion,'--zones',$Odcr.ZonalZone,'-o','json') -EvidenceFile $evi -LogFile $log | Out-Null
    Write-Log "Created zonal CRG (zone $($Odcr.ZonalZone))" -Level OK -LogFile $log
} else {
    Write-Log "Zonal CRG already exists" -Level INFO -LogFile $log
}
$zResShow = Invoke-Az -Args @('capacity','reservation','show','-g',$Odcr.TestRg,'-c',$Odcr.ZonalCrg,'-n',$Odcr.ZonalRes,'-o','json') -EvidenceFile $evi -LogFile $log -AllowFail
if (-not $zResShow.Json) {
    Write-Log "Creating zonal reservation '$($Odcr.ZonalRes)' ($($Odcr.Sku) x$($Odcr.ReservedQty), zone $($Odcr.ZonalZone))" -Level STEP -LogFile $log
    Invoke-Az -Args @('capacity','reservation','create','-g',$Odcr.TestRg,'-c',$Odcr.ZonalCrg,'-n',$Odcr.ZonalRes,
        '--sku',$Odcr.Sku,'--capacity',"$($Odcr.ReservedQty)",'-l',$Odcr.ZonalRegion,'--zone',$Odcr.ZonalZone,'-o','json') -EvidenceFile $evi -LogFile $log | Out-Null
    Write-Log "Zonal reservation created" -Level OK -LogFile $log
} else {
    Write-Log "Zonal reservation already exists" -Level INFO -LogFile $log
}

# --- Zonal policy assignment (reuse existing definition) -------------------
$defId = "/providers/Microsoft.Management/managementGroups/$($Odcr.PolicyMg)/providers/Microsoft.Authorization/policyDefinitions/$($Odcr.PolicyDefName)"
$mgScope = "/providers/Microsoft.Management/managementGroups/$($Odcr.PolicyMg)"
$zonalCrgId = Get-OdcrCrgId -Rg $Odcr.TestRg -Crg $Odcr.ZonalCrg
Write-Log "Ensuring ZONAL policy assignment '$($Odcr.ZonalAssignName)' -> $zonalCrgId" -Level STEP -LogFile $log
$asgShow = Invoke-Az -Args @('policy','assignment','show','--name',$Odcr.ZonalAssignName,'--scope',$mgScope,'-o','json') -EvidenceFile $evi -LogFile $log -AllowFail
if (-not $asgShow.Json) {
    $paramsJson = @{
        capacityReservationGroupResourceId = @{ value = $zonalCrgId }
        targetRegion = @{ value = $Odcr.ZonalRegion }
        vmSkus       = @{ value = @($Odcr.Sku) }
        isZonal      = @{ value = $true }
        availabilityZone = @{ value = $Odcr.ZonalZone }
    } | ConvertTo-Json -Depth 6 -Compress
    $pfile = Join-Path $ev 'zonal-assignment-params.json'
    Set-Content -Path $pfile -Value $paramsJson
    # NOTE: do NOT pass --identity-scope; that triggers an az CLI bug
    # ('NoneType' object has no attribute '_data') when auto-creating the role
    # assignment. We create the identity here and grant the role manually below.
    Invoke-Az -Args @('policy','assignment','create','--name',$Odcr.ZonalAssignName,
        '--display-name','ODCR zonal westus3 z2 (test suite)',
        '--policy',$defId,'--scope',$mgScope,
        '--params',$pfile,
        '--mi-system-assigned',
        '--location',$Odcr.ZonalRegion,'-o','json') -EvidenceFile $evi -LogFile $log | Out-Null
    Write-Log "Zonal assignment created; waiting for managed identity to propagate" -Level OK -LogFile $log
    Start-Sleep -Seconds 20
} else {
    Write-Log "Zonal assignment already exists" -Level INFO -LogFile $log
}

# Ensure the assignment identity has Virtual Machine Contributor (idempotent).
$principalId = (az policy assignment show --name $Odcr.ZonalAssignName --scope $mgScope --query identity.principalId -o tsv)
if ($principalId) {
    Write-Log "Ensuring Virtual Machine Contributor for identity $principalId at $mgScope" -Level STEP -LogFile $log
    $hasRole = $false
    $attempt = 0
    while ($attempt -lt 6) {
        $rr = Invoke-Az -Args @('role','assignment','create','--assignee-object-id',$principalId,'--assignee-principal-type','ServicePrincipal',
            '--role',$Odcr.VmContributorRoleId,'--scope',$mgScope,'-o','json') -EvidenceFile $evi -LogFile $log -AllowFail
        if ($rr.ExitCode -eq 0 -or ($rr.Output -match 'RoleAssignmentExists')) { $hasRole = $true; Write-Log "Role present" -Level OK -LogFile $log; break }
        $attempt++; Start-Sleep -Seconds 15
    }
    if (-not $hasRole) { Write-Log "Could not confirm role assignment after retries" -Level WARN -LogFile $log }

    # Virtual Machine Contributor grants Microsoft.Compute/virtualMachines/write
    # but NOT Microsoft.Compute/capacityReservationGroups/deploy/action, which is
    # required to associate a VM to a CRG. Without it, a Modify-policy REMEDIATION
    # (which runs as this managed identity) fails with 'Forbidden' when it tries to
    # set capacityReservationGroup on an existing VM. Grant Contributor on the CRG
    # so remediation-based association can succeed.
    $zonalCrgScope = Get-OdcrCrgId -Rg $Odcr.TestRg -Crg $Odcr.ZonalCrg
    Write-Log "Ensuring Contributor (CRG deploy/action) for identity $principalId on zonal CRG" -Level STEP -LogFile $log
    $attempt = 0
    while ($attempt -lt 6) {
        $rc = Invoke-Az -Args @('role','assignment','create','--assignee-object-id',$principalId,'--assignee-principal-type','ServicePrincipal',
            '--role','Contributor','--scope',$zonalCrgScope,'-o','json') -EvidenceFile $evi -LogFile $log -AllowFail
        if ($rc.ExitCode -eq 0 -or ($rc.Output -match 'RoleAssignmentExists')) { Write-Log "CRG Contributor present" -Level OK -LogFile $log; break }
        $attempt++; Start-Sleep -Seconds 15
    }
} else {
    Write-Log "No managed identity principalId found on zonal assignment" -Level WARN -LogFile $log
}

# --- Validation summary ----------------------------------------------------
Write-Log "=== SETUP VALIDATION ===" -Level STEP -LogFile $log
$regOk = [bool](az capacity reservation show -g $Odcr.RegionalCrgRg -c $Odcr.RegionalCrg -n $Odcr.RegionalRes --query name -o tsv 2>$null)
$zonOk = [bool](az capacity reservation show -g $Odcr.TestRg -c $Odcr.ZonalCrg -n $Odcr.ZonalRes --query name -o tsv 2>$null)
$asgOk = [bool](az policy assignment show --name $Odcr.ZonalAssignName --scope $mgScope --query name -o tsv 2>$null)
Write-Log ("Regional reservation present : {0}" -f $regOk) -Level ($(if($regOk){'OK'}else{'ERROR'})) -LogFile $log
Write-Log ("Zonal reservation present    : {0}" -f $zonOk) -Level ($(if($zonOk){'OK'}else{'ERROR'})) -LogFile $log
Write-Log ("Zonal assignment present     : {0}" -f $asgOk) -Level ($(if($asgOk){'OK'}else{'ERROR'})) -LogFile $log

Write-OdcrResult -TestId 'SETUP' -Title 'ODCR setup (regional + zonal CRGs, zonal assignment)' `
    -Result ($(if($regOk -and $zonOk -and $asgOk){'PASS'}else{'FAIL'})) `
    -Criteria @{
        'Regional CRG/reservation (NCUS, D2s_v3)' = $regOk
        'Zonal CRG/reservation (westus3 z2, D2s_v3)' = $zonOk
        'Zonal policy assignment created' = $asgOk
    } -Notes "Evidence dir: $ev"

Write-Log "=== ODCR SETUP COMPLETE ===" -Level STEP -LogFile $log
