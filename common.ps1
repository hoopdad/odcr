<#
.SYNOPSIS
    Shared configuration and helper functions for the Azure ODCR tag-based
    association test suite. Dot-source this file from every test script:

        . "$PSScriptRoot\common.ps1"

    All settings live in $Odcr. Override any value via environment variables of
    the same name (e.g. $env:ODCR_TEST_RG) before running, if desired.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Module-scoped state (declared up front so StrictMode never sees them unset)
$script:OdcrRunDir = $null

# ---------------------------------------------------------------------------
# Configuration (discovered & confirmed for this environment)
# ---------------------------------------------------------------------------
#
# NOTE: All environment-specific identifiers below are PLACEHOLDERS. Do not commit
# real subscription IDs, management group names, or tenant-specific resource names.
# Override any value at run time via an environment variable named ODCR_<KEY>
# (uppercased), e.g.  $env:ODCR_SUBSCRIPTIONID = '<your-sub-guid>'.
#
$script:Odcr = [ordered]@{
    SubscriptionId = '00000000-0000-0000-0000-000000000000'   # set $env:ODCR_SUBSCRIPTIONID

    Sku            = 'Standard_D2s_v3'
    TagName        = 'UseCapacityReservation'
    TagValue       = 'true'

    # --- Regional (tests 1 & 2): matches the EXISTING MG policy assignment ---
    RegionalRegion = 'northcentralus'
    RegionalCrgRg  = 'rg-odcr-regional'     # existing RG the policy points at
    RegionalCrg    = 'crg-odcr-regional'    # CRG the existing policy injects
    RegionalRes    = 'res-d2sv3-ncus'       # reservation name inside the CRG

    # --- Zonal (tests 3 & 4): new CRG + new assignment reusing the def --------
    ZonalRegion    = 'westus3'
    ZonalZone      = '2'
    ZonalCrg       = 'odcr-zonal-westus3-z2'
    ZonalRes       = 'res-d2sv3-wus3-z2'

    ReservedQty    = 1

    # Resource group that holds the test VMs (+ the zonal CRG)
    TestRg         = 'rg-odcr-tests'
    TestRgRegion   = 'northcentralus'

    # VM image / auth
    Image          = 'Ubuntu2204'
    AdminUser      = 'azureuser'

    # Policy (existing) — reused for the zonal assignment
    PolicyMg       = 'mg-odcr-lab'                          # set $env:ODCR_POLICYMG
    PolicyDefName  = 'vm-cr-assignment-def'                 # set $env:ODCR_POLICYDEFNAME
    RegionalAssignName = 'vm-cr-regional-assign'            # set $env:ODCR_REGIONALASSIGNNAME
    ZonalAssignName= 'odcr-zonal-wus3-z2'
    VmContributorRoleId = '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'  # built-in: Virtual Machine Contributor

    # Tests 2 & 4: poll cadence + how long to wait for association after the
    # RG-scoped policy remediation completes.
    ScanPollSeconds            = 30
    PostRemediationWaitSeconds = 300
    # Test 4 runs the full policy path end-to-end; Azure Policy's async
    # ReEvaluateCompliance evaluation can take 15-30+ min before the Modify
    # remediation issues its PATCH, so allow a long terminal-state wait.
    RemediationTimeoutSeconds  = 2700

    # Evidence root (timestamped run dir is created under here)
    EvidenceRoot   = (Join-Path $PSScriptRoot 'evidence')
}

# Allow env overrides (ODCR_<KEY> uppercased)
foreach ($k in @($script:Odcr.Keys)) {
    $envName = "ODCR_$($k.ToUpper())"
    $v = [Environment]::GetEnvironmentVariable($envName)
    if ($v) { $script:Odcr[$k] = $v }
}

# ---------------------------------------------------------------------------
# Run / evidence directory
# ---------------------------------------------------------------------------
function Initialize-OdcrRun {
    param([string]$Name = 'run')
    if (-not $script:OdcrRunDir) {
        if ($env:ODCR_RUN_DIR) {
            # A parent (99-run-all) seeded a shared run dir - reuse it so all
            # tests write evidence/results into one consolidated folder.
            $script:OdcrRunDir = $env:ODCR_RUN_DIR
        } else {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $script:OdcrRunDir = Join-Path $script:Odcr.EvidenceRoot $stamp
        }
    }
    $dir = Join-Path $script:OdcrRunDir $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK','STEP')][string]$Level = 'INFO',
        [string]$LogFile
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Message"
    $color = switch ($Level) {
        'OK'    { 'Green' }   'WARN' { 'Yellow' }
        'ERROR' { 'Red' }     'STEP' { 'Cyan' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
    if ($LogFile) { Add-Content -Path $LogFile -Value $line }
}

# ---------------------------------------------------------------------------
# az wrapper: runs the command, tees stdout+stderr to an evidence file,
# returns a PSCustomObject { ExitCode, Output, Json }.
# ---------------------------------------------------------------------------
function Invoke-Az {
    param(
        [Alias('Args')][string[]]$AzArgs,
        [string]$EvidenceFile,
        [string]$LogFile,
        [switch]$AllowFail
    )
    $display = 'az ' + ($AzArgs -join ' ')
    Write-Log "RUN: $display" -Level STEP -LogFile $LogFile
    $out = & az @AzArgs 2>&1
    $code = $LASTEXITCODE
    $text = ($out | Out-String)
    if ($EvidenceFile) {
        Add-Content -Path $EvidenceFile -Value "`n### $display`n(exit=$code)`n$text"
    }
    if ($LogFile) { Add-Content -Path $LogFile -Value $text }
    if ($code -ne 0 -and -not $AllowFail) {
        Write-Log "az failed (exit=$code): $display" -Level ERROR -LogFile $LogFile
        Write-Host $text -ForegroundColor DarkYellow
        throw "az command failed: $display"
    }
    $json = $null
    if ($code -eq 0) { try { $json = $text | ConvertFrom-Json } catch { $json = $null } }
    [PSCustomObject]@{ ExitCode = $code; Output = $text; Json = $json }
}

# ---------------------------------------------------------------------------
# Ensure the CLI is pointed at the right subscription.
# ---------------------------------------------------------------------------
function Set-OdcrSubscription {
    param([string]$LogFile)
    Invoke-Az -Args @('account','set','--subscription',$script:Odcr.SubscriptionId) -LogFile $LogFile | Out-Null
    $cur = (az account show --query id -o tsv)
    Write-Log "Active subscription: $cur" -Level INFO -LogFile $LogFile
}

# ---------------------------------------------------------------------------
# Resolve a CRG resource id.
# ---------------------------------------------------------------------------
function Get-OdcrCrgId {
    param([Parameter(Mandatory)][string]$Rg, [Parameter(Mandatory)][string]$Crg)
    return "/subscriptions/$($script:Odcr.SubscriptionId)/resourceGroups/$Rg/providers/Microsoft.Compute/capacityReservationGroups/$Crg"
}

# ---------------------------------------------------------------------------
# Association check: does $VmId appear in the reservation's associated VMs,
# and how many VMs are currently allocated against it?
# Returns { Associated, AllocatedCount, AssociatedIds, Utilization }.
# ---------------------------------------------------------------------------
function Test-OdcrAssociation {
    param(
        [Parameter(Mandatory)][string]$Rg,
        [Parameter(Mandatory)][string]$Crg,
        [Parameter(Mandatory)][string]$Res,
        [string]$VmId,
        [string]$EvidenceFile,
        [string]$LogFile
    )
    $r = Invoke-Az -Args @('capacity','reservation','show','-g',$Rg,'-c',$Crg,'-n',$Res,
        '--instance-view','-o','json') -EvidenceFile $EvidenceFile -LogFile $LogFile -AllowFail
    $assocIds = @()
    $alloc = 0
    $util = $null
    if ($r.Json) {
        if ($r.Json.PSObject.Properties.Name -contains 'virtualMachinesAssociated' -and $r.Json.virtualMachinesAssociated) {
            $assocIds = @($r.Json.virtualMachinesAssociated | ForEach-Object { $_.id })
        }
        if ($r.Json.PSObject.Properties.Name -contains 'instanceView' -and $r.Json.instanceView) {
            $iv = $r.Json.instanceView
            if ($iv.PSObject.Properties.Name -contains 'utilizationInfo' -and $iv.utilizationInfo) {
                $util = $iv.utilizationInfo
                if ($util.PSObject.Properties.Name -contains 'virtualMachinesAllocated' -and $util.virtualMachinesAllocated) {
                    $alloc = @($util.virtualMachinesAllocated).Count
                }
            }
        }
    }
    $isAssoc = $false
    if ($VmId) { $isAssoc = [bool]($assocIds | Where-Object { $_ -and ($_.ToLower() -eq $VmId.ToLower()) }) }
    [PSCustomObject]@{
        Associated     = $isAssoc
        AllocatedCount = $alloc
        AssociatedIds  = $assocIds
        Utilization    = $util
    }
}

# ---------------------------------------------------------------------------
# Read the capacityReservationGroup id the platform recorded on a VM
# (i.e. what the Modify policy injected). Empty string if none.
# ---------------------------------------------------------------------------
function Get-VmCrgId {
    param([string]$Rg,[string]$Vm,[string]$EvidenceFile,[string]$LogFile)
    $r = Invoke-Az -Args @('vm','show','-g',$Rg,'-n',$Vm,
        '--query','capacityReservation.capacityReservationGroup.id','-o','tsv') `
        -EvidenceFile $EvidenceFile -LogFile $LogFile -AllowFail
    return ($r.Output).Trim()
}

# ---------------------------------------------------------------------------
# Append a structured result row to the run-level results.json + results.md
# ---------------------------------------------------------------------------
function Write-OdcrResult {
    param(
        [Parameter(Mandatory)][string]$TestId,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][ValidateSet('PASS','FAIL','INCONCLUSIVE')][string]$Result,
        [hashtable]$Criteria = @{},
        [string]$Notes = ''
    )
    if (-not $script:OdcrRunDir) { Initialize-OdcrRun | Out-Null }
    $obj = [PSCustomObject]@{
        TestId    = $TestId
        Title     = $Title
        Result    = $Result
        Criteria  = $Criteria
        Notes     = $Notes
        Timestamp = (Get-Date -Format 's')
    }
    $jsonPath = Join-Path $script:OdcrRunDir 'results.json'
    $all = @()
    if (Test-Path $jsonPath) { $all = @(Get-Content $jsonPath -Raw | ConvertFrom-Json) }
    $all += $obj
    $all | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath

    $mdPath = Join-Path $script:OdcrRunDir 'results.md'
    if (-not (Test-Path $mdPath)) {
        Set-Content -Path $mdPath -Value "# ODCR Test Suite Results`n`nRun dir: ``$($script:OdcrRunDir)```n"
    }
    $icon = switch ($Result) { 'PASS' {'PASS'} 'FAIL' {'FAIL'} default {'INCONCLUSIVE'} }
    Add-Content -Path $mdPath -Value "`n## $TestId - $Title`n`n**Result: $icon**`n"
    foreach ($c in $Criteria.GetEnumerator()) {
        Add-Content -Path $mdPath -Value ("- {0}: {1}" -f $c.Key, $c.Value)
    }
    if ($Notes) { Add-Content -Path $mdPath -Value "`n$Notes`n" }
    Write-Log "RESULT $TestId = $Result" -Level ($(if($Result -eq 'PASS'){'OK'}elseif($Result -eq 'FAIL'){'ERROR'}else{'WARN'}))
}

# ---------------------------------------------------------------------------
# Delete a VM and its disk/nic (best effort).
# ---------------------------------------------------------------------------
function Remove-OdcrVm {
    param([string]$Rg,[string]$Vm,[string]$EvidenceFile,[string]$LogFile)
    Write-Log "Deleting VM $Vm ..." -Level STEP -LogFile $LogFile
    Invoke-Az -Args @('vm','delete','-g',$Rg,'-n',$Vm,'--yes','--force-deletion','true') `
        -EvidenceFile $EvidenceFile -LogFile $LogFile -AllowFail | Out-Null
}

# ---------------------------------------------------------------------------
# Create an Azure Policy remediation task for a Modify policy assignment, scoped
# to a RESOURCE GROUP (the RG that holds the VM under test), and wait for it to
# reach a terminal state. This is the supported way to make a Modify policy act
# on an already-existing resource - it issues a PATCH that adds the
# capacityReservationGroup property to matching VMs.
#
# `ReEvaluateCompliance` re-evaluates compliance for the resources in scope
# before remediating, so a freshly-created VM (not yet in the compliance
# dataset) is picked up. RG scope is "subscription and below", where
# ReEvaluateCompliance is supported.
#
# Returns an object: { State, DeploymentSucceeded, DeploymentFailed, Detail }.
# ---------------------------------------------------------------------------
function Invoke-OdcrRemediation {
    param(
        [Parameter(Mandatory)][string]$AssignmentName,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [switch]$ReEvaluate,
        [string]$EvidenceFile,[string]$LogFile,
        [int]$TimeoutSeconds = 300
    )
    $asgId = "/providers/Microsoft.Management/managementGroups/$($script:Odcr.PolicyMg)/providers/Microsoft.Authorization/policyAssignments/$AssignmentName"
    $remName = "odcr-rem-$(Get-Date -Format 'HHmmss')"
    Write-Log "Creating policy remediation '$remName' for assignment '$AssignmentName' scoped to RG '$ResourceGroup'" -Level STEP -LogFile $LogFile
    $createArgs = @('policy','remediation','create','--name',$remName,
        '--resource-group',$ResourceGroup,'--policy-assignment',$asgId)
    if ($ReEvaluate) { $createArgs += @('--resource-discovery-mode','ReEvaluateCompliance') }
    $createArgs += @('-o','json')
    $c = Invoke-Az -Args $createArgs -EvidenceFile $EvidenceFile -LogFile $LogFile -AllowFail
    if ($c.ExitCode -ne 0) {
        return [PSCustomObject]@{ State='RemediationCreateFailed'; DeploymentSucceeded=0; DeploymentFailed=0; Detail=$c.Output }
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $state = 'Unknown'
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 30
        $s = Invoke-Az -Args @('policy','remediation','show','--name',$remName,
            '--resource-group',$ResourceGroup,'--query','provisioningState','-o','tsv') -EvidenceFile $EvidenceFile -LogFile $LogFile -AllowFail
        $state = ($s.Output).Trim()
        Write-Log "Remediation '$remName' state=$state" -Level INFO -LogFile $LogFile
        if ($state -in @('Succeeded','Failed','Canceled')) { break }
    }

    # Capture per-resource deployment results for evidence and tally outcomes.
    $dep = Invoke-Az -Args @('policy','remediation','deployment','list','--name',$remName,
        '--resource-group',$ResourceGroup,'-o','json') -EvidenceFile $EvidenceFile -LogFile $LogFile -AllowFail
    $succeeded = 0; $failed = 0; $detail = ''
    if ($dep.Json) {
        $succeeded = @($dep.Json | Where-Object { $_.status -eq 'Succeeded' }).Count
        $failed    = @($dep.Json | Where-Object { $_.status -in @('Failed','Conflict') }).Count
        $detail    = ($dep.Json | ForEach-Object { "$($_.status): $($_.error.message)" }) -join ' | '
    }
    [PSCustomObject]@{ State=$state; DeploymentSucceeded=$succeeded; DeploymentFailed=$failed; Detail=$detail }
}

# ---------------------------------------------------------------------------
# Ensure a NIC with NO public IP exists (ALZ policy blocks public IPs).
# Creates a per-region vnet/subnet on demand, then a NIC, and returns its id.
# ---------------------------------------------------------------------------
function New-OdcrNic {
    param(
        [Parameter(Mandatory)][string]$Rg,
        [Parameter(Mandatory)][string]$Region,
        [Parameter(Mandatory)][string]$BaseName,
        [string]$EvidenceFile,[string]$LogFile
    )
    $vnet   = "odcr-vnet-$Region"
    $subnet = 'default'
    $exists = (az network vnet show -g $Rg -n $vnet --query name -o tsv 2>$null)
    if (-not $exists) {
        Invoke-Az -Args @('network','vnet','create','-g',$Rg,'-n',$vnet,'-l',$Region,
            '--address-prefixes','10.20.0.0/16','--subnet-name',$subnet,'--subnet-prefixes','10.20.0.0/24','-o','json') `
            -EvidenceFile $EvidenceFile -LogFile $LogFile | Out-Null
    }
    $nic = "$BaseName-nic"
    Invoke-Az -Args @('network','nic','create','-g',$Rg,'-n',$nic,'-l',$Region,
        '--vnet-name',$vnet,'--subnet',$subnet,'-o','json') -EvidenceFile $EvidenceFile -LogFile $LogFile | Out-Null
    return (az network nic show -g $Rg -n $nic --query id -o tsv)
}

Write-Host "common.ps1 loaded. Subscription=$($script:Odcr.SubscriptionId) Sku=$($script:Odcr.Sku)" -ForegroundColor DarkCyan
