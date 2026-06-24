<#
.SYNOPSIS
  TEST 2 - Regional VM, tag added AFTER the VM is running.

  Creates a REGIONAL Standard_D2s_v3 VM in North Central US WITHOUT the tag
  (so it is not associated), confirms no association, then adds the tag
  UseCapacityReservation=true to the running VM. It then triggers an Azure
  Policy compliance scan (`az policy state trigger-scan`), waits, and re-checks
  whether the reservation now accounts for the VM.

  Behavioral test: observe whether adding the tag post-creation (plus a policy
  scan) causes association. Azure does not allow changing a VM's capacity
  reservation while it is running, so association via the Modify policy is not
  expected to succeed without a deallocate/start cycle - this script documents
  the actual observed outcome.
#>
[CmdletBinding()]
param([switch]$DeleteVm)
. "$PSScriptRoot\common.ps1"

$ev  = Initialize-OdcrRun -Name 'test02'
$log = Join-Path $ev 'test02.log'
$evi = Join-Path $ev 'test02-evidence.txt'
$vm  = "odcr-t2-reg-$(Get-Date -Format 'HHmmss')"

Write-Log "=== TEST 2: regional, tag added after start ===" -Level STEP -LogFile $log
Set-OdcrSubscription -LogFile $log

# 1) Create regional VM WITHOUT the tag.
Write-Log "Creating NIC (no public IP) for '$vm'" -Level STEP -LogFile $log
$nicId = New-OdcrNic -Rg $Odcr.TestRg -Region $Odcr.RegionalRegion -BaseName $vm -EvidenceFile $evi -LogFile $log
Write-Log "Creating regional VM '$vm' WITHOUT tag" -Level STEP -LogFile $log
Invoke-Az -Args @('vm','create','-g',$Odcr.TestRg,'-n',$vm,'-l',$Odcr.RegionalRegion,
    '--image',$Odcr.Image,'--size',$Odcr.Sku,'--admin-username',$Odcr.AdminUser,
    '--generate-ssh-keys','--nics',$nicId,
    '--os-disk-delete-option','Delete','-o','json') -EvidenceFile $evi -LogFile $log | Out-Null

$vmId = (az vm show -g $Odcr.TestRg -n $vm --query id -o tsv)
Write-Log "VM id: $vmId" -Level INFO -LogFile $log

# 2) Confirm NOT associated initially.
$pre = Test-OdcrAssociation -Rg $Odcr.RegionalCrgRg -Crg $Odcr.RegionalCrg -Res $Odcr.RegionalRes -VmId $vmId -EvidenceFile $evi -LogFile $log
Write-Log "Pre-tag associated=$($pre.Associated)" -Level INFO -LogFile $log

# 3) Add the tag to the RUNNING VM (capture success/failure of the update).
#    Use `az tag update` (Merge) - `az vm update --set tags.x=true` mis-parses
#    the literal `true` as a bool and errors out.
Write-Log "Adding tag $($Odcr.TagName)=$($Odcr.TagValue) to running VM" -Level STEP -LogFile $log
$upd = Invoke-Az -Args @('tag','update','--resource-id',$vmId,'--operation','Merge',
    '--tags',"$($Odcr.TagName)=$($Odcr.TagValue)",'-o','json') -EvidenceFile $evi -LogFile $log -AllowFail
$tagAddSucceeded = ($upd.ExitCode -eq 0)
$tagVal = (az vm show -g $Odcr.TestRg -n $vm --query "tags.$($Odcr.TagName)" -o tsv 2>$null)
Write-Log "Tag update exit=$($upd.ExitCode); tag now='$tagVal'" -Level ($(if($tagAddSucceeded){'OK'}else{'WARN'})) -LogFile $log

# 4) Create a policy remediation scoped to the VM's resource group. This is the
#    supported way to make the Modify policy act on the already-running VM (it
#    re-evaluates compliance, then PATCHes matching VMs to add the CRG).
Write-Log "Creating policy remediation for the running VM (RG-scoped)" -Level STEP -LogFile $log
$rem = Invoke-OdcrRemediation -AssignmentName $Odcr.RegionalAssignName -ResourceGroup $Odcr.TestRg -ReEvaluate -EvidenceFile $evi -LogFile $log

# 5) Poll for association after remediation completes.
$deadline = (Get-Date).AddSeconds([int]$Odcr.PostRemediationWaitSeconds)
$assoc = $pre
while ((Get-Date) -lt $deadline) {
    $assoc = Test-OdcrAssociation -Rg $Odcr.RegionalCrgRg -Crg $Odcr.RegionalCrg -Res $Odcr.RegionalRes -VmId $vmId -EvidenceFile $evi -LogFile $log
    $crgNow = Get-VmCrgId -Rg $Odcr.TestRg -Vm $vm -EvidenceFile $evi -LogFile $log
    Write-Log "Poll: associated=$($assoc.Associated) vmCRG='$crgNow'" -Level INFO -LogFile $log
    if ($assoc.Associated) { break }
    Start-Sleep -Seconds ([int]$Odcr.ScanPollSeconds)
}

# 6) Capture compliance state for the VM (evidence).
Invoke-Az -Args @('policy','state','list','--subscription',$Odcr.SubscriptionId,
    '--filter',"ResourceId eq '$vmId'",'--query','[].{policy:policyDefinitionName,compliance:complianceState}','-o','json') `
    -EvidenceFile $evi -LogFile $log -AllowFail | Out-Null

$crgOnVm = Get-VmCrgId -Rg $Odcr.TestRg -Vm $vm -EvidenceFile $evi -LogFile $log
$zones   = (az vm show -g $Odcr.TestRg -n $vm --query 'zones' -o tsv)

# Documented expectation (Microsoft Learn, "Associate an existing virtual
# machine"): an existing REGIONAL VM must be reallocated (deallocate -> set CRG
# -> start). A remediation PATCH on a running regional VM therefore cannot
# associate it in place, so the expected outcome here is NOT associated.
$expectedAssociated = $false

$criteria = @{
    'Region == northcentralus' = ((az vm show -g $Odcr.TestRg -n $vm --query location -o tsv) -eq $Odcr.RegionalRegion)
    'SKU == Standard_D2s_v3'   = ((az vm show -g $Odcr.TestRg -n $vm --query 'hardwareProfile.vmSize' -o tsv) -eq $Odcr.Sku)
    'Regional (no zone)'       = ([string]::IsNullOrWhiteSpace($zones))
    'Created WITHOUT tag (initially not associated)' = (-not $pre.Associated)
    'Tag added to running VM'  = ($tagVal -eq $Odcr.TagValue)
    'Reservation accounts for VM after remediation' = $assoc.Associated
    'Matches documented expectation (regional needs deallocate cycle => not associated in place)' = ($assoc.Associated -eq $expectedAssociated)
}
# PASS when observed behavior matches the documented expectation.
$pass = ($assoc.Associated -eq $expectedAssociated)
$result = if ($pass) { 'PASS' } else { 'FAIL' }
$notes = @"
Mechanism: RG-scoped 'az policy remediation create' (ReEvaluateCompliance) against
assignment $($Odcr.RegionalAssignName), targeting RG $($Odcr.TestRg).
remediationState=$($rem.State); deploymentsSucceeded=$($rem.DeploymentSucceeded);
deploymentsFailed=$($rem.DeploymentFailed); remediationDetail=$($rem.Detail).
tagApplied=$($tagVal -eq $Odcr.TagValue); injectedCRG='$crgOnVm'; finalAssociated=$($assoc.Associated).
Per Microsoft Learn, an existing REGIONAL VM must be reallocated (deallocate -> set
CRG -> start); a remediation PATCH cannot change capacityReservationGroup on a
running regional VM, so 'not associated in place' is the expected, correct result.
Evidence: $ev
"@
Write-OdcrResult -TestId 'TEST2' -Title 'Regional VM, tag after start (remediation)' -Result $result -Criteria $criteria -Notes $notes

# 7) Destroy the VM.
if ($DeleteVm) {
    Remove-OdcrVm -Rg $Odcr.TestRg -Vm $vm -EvidenceFile $evi -LogFile $log
} else {
    Write-Log "VM '$vm' left running in RG '$($Odcr.TestRg)' for portal review. Run .\remove-test-vms.ps1 (VMs only) or .\teardown.ps1 (everything) to delete." -Level WARN -LogFile $log
}
Write-Log "=== TEST 2 COMPLETE ($result) ===" -Level ($(if($pass){'OK'}else{'ERROR'})) -LogFile $log
