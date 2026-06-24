<#
.SYNOPSIS
  TEST 1 - Regional VM, tag set AT creation.

  Creates a REGIONAL (no zone) Standard_D2s_v3 VM in North Central US with the
  tag UseCapacityReservation=true. The existing management-group Modify policy
  should inject the regional CRG (crg-odcr-regional) inline during creation.

  Validates that the reservation accounts for the VM, then deletes the VM.

  Expected behavioral result: ASSOCIATED.
#>
[CmdletBinding()]
param([switch]$DeleteVm)
. "$PSScriptRoot\common.ps1"

$ev  = Initialize-OdcrRun -Name 'test01'
$log = Join-Path $ev 'test01.log'
$evi = Join-Path $ev 'test01-evidence.txt'
$vm  = "odcr-t1-reg-$(Get-Date -Format 'HHmmss')"

Write-Log "=== TEST 1: regional, tag at create ===" -Level STEP -LogFile $log
Set-OdcrSubscription -LogFile $log

# 1) Create regional VM WITH the tag (let the policy do the association).
Write-Log "Creating NIC (no public IP) for '$vm'" -Level STEP -LogFile $log
$nicId = New-OdcrNic -Rg $Odcr.TestRg -Region $Odcr.RegionalRegion -BaseName $vm -EvidenceFile $evi -LogFile $log
Write-Log "Creating regional VM '$vm' WITH tag $($Odcr.TagName)=$($Odcr.TagValue)" -Level STEP -LogFile $log
Invoke-Az -Args @('vm','create','-g',$Odcr.TestRg,'-n',$vm,'-l',$Odcr.RegionalRegion,
    '--image',$Odcr.Image,'--size',$Odcr.Sku,'--admin-username',$Odcr.AdminUser,
    '--generate-ssh-keys','--nics',$nicId,
    '--os-disk-delete-option','Delete',
    '--tags',"$($Odcr.TagName)=$($Odcr.TagValue)",'-o','json') -EvidenceFile $evi -LogFile $log | Out-Null

$vmId = (az vm show -g $Odcr.TestRg -n $vm --query id -o tsv)
Write-Log "VM id: $vmId" -Level INFO -LogFile $log

# 2) Validate criteria.
$crgOnVm = Get-VmCrgId -Rg $Odcr.TestRg -Vm $vm -EvidenceFile $evi -LogFile $log
$zones   = (az vm show -g $Odcr.TestRg -n $vm --query 'zones' -o tsv)
$size    = (az vm show -g $Odcr.TestRg -n $vm --query 'hardwareProfile.vmSize' -o tsv)
$loc     = (az vm show -g $Odcr.TestRg -n $vm --query 'location' -o tsv)
$tagVal  = (az vm show -g $Odcr.TestRg -n $vm --query "tags.$($Odcr.TagName)" -o tsv)

$assoc = Test-OdcrAssociation -Rg $Odcr.RegionalCrgRg -Crg $Odcr.RegionalCrg -Res $Odcr.RegionalRes -VmId $vmId -EvidenceFile $evi -LogFile $log
Write-Log "Reservation associated=$($assoc.Associated) allocated=$($assoc.AllocatedCount)" -Level INFO -LogFile $log

$expectedCrg = (Get-OdcrCrgId -Rg $Odcr.RegionalCrgRg -Crg $Odcr.RegionalCrg)
$crgMatches  = ($crgOnVm -and ($crgOnVm.ToLower() -eq $expectedCrg.ToLower()))
$isRegional  = [string]::IsNullOrWhiteSpace($zones)

$criteria = @{
    'Region == northcentralus'        = ($loc -eq $Odcr.RegionalRegion)
    'SKU == Standard_D2s_v3'          = ($size -eq $Odcr.Sku)
    'Regional (no zone)'              = $isRegional
    "Tag $($Odcr.TagName)=$($Odcr.TagValue) at create" = ($tagVal -eq $Odcr.TagValue)
    'VM.capacityReservationGroup injected by policy' = $crgMatches
    'Reservation accounts for VM (associated)'        = $assoc.Associated
}
$pass = $criteria.Values -notcontains $false
Write-OdcrResult -TestId 'TEST1' -Title 'Regional VM, tag at create' `
    -Result ($(if($pass){'PASS'}else{'FAIL'})) -Criteria $criteria `
    -Notes "VM=$vm; injectedCRG=$crgOnVm; allocated=$($assoc.AllocatedCount). Evidence: $ev"

# 3) Destroy the VM.
if ($DeleteVm) {
    Remove-OdcrVm -Rg $Odcr.TestRg -Vm $vm -EvidenceFile $evi -LogFile $log
} else {
    Write-Log "VM '$vm' left running in RG '$($Odcr.TestRg)' for portal review. Run .\remove-test-vms.ps1 (VMs only) or .\teardown.ps1 (everything) to delete." -Level WARN -LogFile $log
}
Write-Log "=== TEST 1 COMPLETE ($(if($pass){'PASS'}else{'FAIL'})) ===" -Level ($(if($pass){'OK'}else{'ERROR'})) -LogFile $log
