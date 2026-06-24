<#
.SYNOPSIS
  TEST 4 - Zonal VM, tag added AFTER the VM is running.

  Creates a ZONAL Standard_D2s_v3 VM in westus3 zone 2 WITHOUT the tag, confirms
  no association, then adds UseCapacityReservation=true to the running VM,
  triggers an Azure Policy compliance scan, waits, and re-checks whether the
  zonal reservation now accounts for the VM.

  Behavioral test: same as Test 2 but zonal. Changing a running VM's capacity
  reservation is not permitted, so association is not expected without a
  deallocate/start cycle - this documents the actual observed outcome.
#>
[CmdletBinding()]
param([switch]$DeleteVm)
. "$PSScriptRoot\common.ps1"

$ev  = Initialize-OdcrRun -Name 'test04'
$log = Join-Path $ev 'test04.log'
$evi = Join-Path $ev 'test04-evidence.txt'
$vm  = "odcr-t4-zon-$(Get-Date -Format 'HHmmss')"

Write-Log "=== TEST 4: zonal, tag added after start ===" -Level STEP -LogFile $log
Set-OdcrSubscription -LogFile $log

# 1) Create zonal VM WITHOUT the tag.
Write-Log "Creating NIC (no public IP) for '$vm'" -Level STEP -LogFile $log
$nicId = New-OdcrNic -Rg $Odcr.TestRg -Region $Odcr.ZonalRegion -BaseName $vm -EvidenceFile $evi -LogFile $log
Write-Log "Creating zonal VM '$vm' in $($Odcr.ZonalRegion) zone $($Odcr.ZonalZone) WITHOUT tag" -Level STEP -LogFile $log
Invoke-Az -Args @('vm','create','-g',$Odcr.TestRg,'-n',$vm,'-l',$Odcr.ZonalRegion,'--zone',$Odcr.ZonalZone,
    '--image',$Odcr.Image,'--size',$Odcr.Sku,'--admin-username',$Odcr.AdminUser,
    '--generate-ssh-keys','--nics',$nicId,
    '--os-disk-delete-option','Delete','-o','json') -EvidenceFile $evi -LogFile $log | Out-Null

$vmId = (az vm show -g $Odcr.TestRg -n $vm --query id -o tsv)
Write-Log "VM id: $vmId" -Level INFO -LogFile $log

# 2) Confirm NOT associated initially.
$pre = Test-OdcrAssociation -Rg $Odcr.TestRg -Crg $Odcr.ZonalCrg -Res $Odcr.ZonalRes -VmId $vmId -EvidenceFile $evi -LogFile $log
Write-Log "Pre-tag associated=$($pre.Associated)" -Level INFO -LogFile $log

# 3) Add the tag to the RUNNING VM. Use `az tag update` (Merge) - `az vm update
#    --set tags.x=true` mis-parses the literal `true` as a bool and errors out.
Write-Log "Adding tag $($Odcr.TagName)=$($Odcr.TagValue) to running VM" -Level STEP -LogFile $log
$upd = Invoke-Az -Args @('tag','update','--resource-id',$vmId,'--operation','Merge',
    '--tags',"$($Odcr.TagName)=$($Odcr.TagValue)",'-o','json') -EvidenceFile $evi -LogFile $log -AllowFail
$tagVal = (az vm show -g $Odcr.TestRg -n $vm --query "tags.$($Odcr.TagName)" -o tsv 2>$null)
Write-Log "Tag update exit=$($upd.ExitCode); tag now='$tagVal'" -Level ($(if($upd.ExitCode -eq 0){'OK'}else{'WARN'})) -LogFile $log

# 4) Create a policy remediation scoped to the VM's resource group (supported
#    path to make the Modify policy act on the running VM). Azure Policy's
#    ReEvaluateCompliance evaluation is async and can take 15-30+ min before the
#    Modify remediation issues its PATCH, so allow a long terminal-state wait.
Write-Log "Creating policy remediation for the running VM (RG-scoped, long wait)" -Level STEP -LogFile $log
$rem = Invoke-OdcrRemediation -AssignmentName $Odcr.ZonalAssignName -ResourceGroup $Odcr.TestRg -ReEvaluate `
    -TimeoutSeconds ([int]$Odcr.RemediationTimeoutSeconds) -EvidenceFile $evi -LogFile $log

# 5) Poll for association after remediation completes.
$deadline = (Get-Date).AddSeconds([int]$Odcr.PostRemediationWaitSeconds)
$assoc = $pre
while ((Get-Date) -lt $deadline) {
    $assoc = Test-OdcrAssociation -Rg $Odcr.TestRg -Crg $Odcr.ZonalCrg -Res $Odcr.ZonalRes -VmId $vmId -EvidenceFile $evi -LogFile $log
    $crgNow = Get-VmCrgId -Rg $Odcr.TestRg -Vm $vm -EvidenceFile $evi -LogFile $log
    Write-Log "Poll: associated=$($assoc.Associated) vmCRG='$crgNow'" -Level INFO -LogFile $log
    if ($assoc.Associated) { break }
    Start-Sleep -Seconds ([int]$Odcr.ScanPollSeconds)
}

# 6) Capture compliance state (evidence).
Invoke-Az -Args @('policy','state','list','--subscription',$Odcr.SubscriptionId,
    '--filter',"ResourceId eq '$vmId'",'--query','[].{policy:policyDefinitionName,compliance:complianceState}','-o','json') `
    -EvidenceFile $evi -LogFile $log -AllowFail | Out-Null

$crgOnVm = Get-VmCrgId -Rg $Odcr.TestRg -Vm $vm -EvidenceFile $evi -LogFile $log
$zones   = (az vm show -g $Odcr.TestRg -n $vm --query 'zones' -o tsv)

# Documented expectation (Microsoft Learn, "Associate an existing virtual
# machine"): an existing ZONAL VM "can simply be updated with Capacity
# Reservation Group property without the need of deallocation". A remediation
# PATCH on the running zonal VM should therefore associate it in place.
$expectedAssociated = $true

$criteria = @{
    "Region == $($Odcr.ZonalRegion)" = ((az vm show -g $Odcr.TestRg -n $vm --query location -o tsv) -eq $Odcr.ZonalRegion)
    'SKU == Standard_D2s_v3'         = ((az vm show -g $Odcr.TestRg -n $vm --query 'hardwareProfile.vmSize' -o tsv) -eq $Odcr.Sku)
    "Zonal (zone $($Odcr.ZonalZone))" = ($zones.Trim() -eq $Odcr.ZonalZone)
    'Created WITHOUT tag (initially not associated)' = (-not $pre.Associated)
    'Tag added to running VM'        = ($tagVal -eq $Odcr.TagValue)
    'Reservation accounts for VM after remediation' = $assoc.Associated
    'Matches documented expectation (zonal associates in place => associated)' = ($assoc.Associated -eq $expectedAssociated)
}
$pass = ($assoc.Associated -eq $expectedAssociated)
$result = if ($pass) { 'PASS' } else { 'FAIL' }
$notes = @"
Mechanism: RG-scoped 'az policy remediation create' (ReEvaluateCompliance) against
assignment $($Odcr.ZonalAssignName), targeting RG $($Odcr.TestRg).
remediationState=$($rem.State); deploymentsSucceeded=$($rem.DeploymentSucceeded);
deploymentsFailed=$($rem.DeploymentFailed); remediationDetail=$($rem.Detail).
tagApplied=$($tagVal -eq $Odcr.TagValue); injectedCRG='$crgOnVm'; finalAssociated=$($assoc.Associated).
Per Microsoft Learn, an existing ZONAL VM can be associated by updating the
capacityReservationGroup property WITHOUT deallocation, so the remediation PATCH is
expected to associate the running VM in place. Evidence: $ev
"@
Write-OdcrResult -TestId 'TEST4' -Title 'Zonal VM, tag after start (remediation)' -Result $result -Criteria $criteria -Notes $notes

# 6) Destroy the VM.
if ($DeleteVm) {
    Remove-OdcrVm -Rg $Odcr.TestRg -Vm $vm -EvidenceFile $evi -LogFile $log
} else {
    Write-Log "VM '$vm' left running in RG '$($Odcr.TestRg)' for portal review. Run .\remove-test-vms.ps1 (VMs only) or .\teardown.ps1 (everything) to delete." -Level WARN -LogFile $log
}
Write-Log "=== TEST 4 COMPLETE ($result) ===" -Level ($(if($pass){'OK'}else{'WARN'})) -LogFile $log
