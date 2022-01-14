#!powershell
<#
    win_spn.ps1
    (c) 2021 Harry Saryan
    This script can be used as an Ansible module to manage SPN records(s)
    Note, this script preferably should be executed on a remote note that has all the necessary PS Modules installed (i.e. DNS, AD, etc..)        
#>

param(
    $svcacct="svcaccount1",
    $SPN="http/testspnxx1,http/testspnxx2,http/testspnxx3,http/testdup1,http/testdup1,",
    [validateset("present","absent")]
    $state="present",
    $RemoveDupRecords=$true,
    $WhatIf=$false
)

#Warning, this module(s) may not be included/be part of this repo.
. "Modules\_LoadAllModules.ps1"  -ErrorAction Stop   #Dot sourcing


[bool]$RemoveDupRecords = ConvertStringToBool $RemoveDupRecords
[bool]$WhatIf           = ConvertStringToBool $WhatIf

$SPN = @($SPN -split(',') |?{$_}| Select-Object -Unique)  #Select unique and non-empty values
#write "---------SPN List ------"
#$SPN

Import-Module ActiveDirectory
$Changed=$false
$msg=""
function CheckForDup
{
    param(
        [array]$spn,
        $svcacct,
        $FailIfExis=$true,
        $RemoveDupRecord=$false,
        $Whatif
    )

    $DupObj=@{}
    $DupObj.DupExists=$false
    $AllUsers = @(Get-ADUser -Filter *  -Properties name,Surname,SamAccountName, ServicePrincipalNames |?{$_.ServicePrincipalNames -ne ""})
    $otherUser = $AllUsers |?{$_.SamAccountName -ne  "$svcacct"}
    $DupRecords = Compare-Object -ReferenceObject $otherUser.ServicePrincipalNames -DifferenceObject $SPN -IncludeEqual -ExcludeDifferent -PassThru

    foreach($dup in $DupRecords)
    {
        
        if($RemoveDupRecord)
        {
            foreach($user in $AllUsers |?{$_.ServicePrincipalNames -match "$dup"})
            {
                #Remove dup record before creating new one
                $script:msg +="*Removing Existing SPN record from $($user.Name)"
                $script:msg += Set-ADUser -Identity "$($user.Name)" -ServicePrincipalNames @{Remove="$dup"} -WhatIf:$Whatif
            }
            
        }
        else
        {
            #Fail
            $DupAcct = $AllUsers |?{$_.ServicePrincipalNames -match "$dup"}
            Write-Host "Dup SPN:$($dup) in Act: $($DupAcct.SamAccountName) "
            Write-Host "----------------"
            $DupAcct.ServicePrincipalNames -join(",")
            if($FailIfExis)
            {
                throw "Critical -> Existing SPN:$($dup) record found in Acct:$($DupAcct.SamAccountName).  New one will NOT be created it will create duplicate entry. Please remove existing record and try again."
                return $false #this line may never execute
            }
        }

        
    }
    return $true
}

#write "Applying SPN for svc acct:$($svcacct) SPN:$($SPN) state:$($state)"
try {
    #spn -username $svcacct -SPN "$SPN" -state $state
    
    $SPNListPre = @((Get-ADUser -Identity "$svcacct" -Properties ServicePrincipalNames).ServicePrincipalNames)

    if($state -eq "present")
    {
        #$SPNListPre |?{$_ -notmatch "$SPN"}
        #$OverrideResult = Compare-Object -ReferenceObject @($file.BaseName.split('.')) -DifferenceObject $WordsToOverrideConflict -IncludeEqual -ExcludeDifferent -PassThru

        $MissingItems = (Compare-Object -ReferenceObject $SPNListPre -DifferenceObject $SPN  |?{$_.SideIndicator -eq "=>"}).InputObject
        if($MissingItems)
        {
            try {
                if(CheckForDup -svcacct "$svcacct" -spn $SPN -RemoveDupRecord $RemoveDupRecords -Whatif $Whatif)
                {
                    #Set-AdUser examples can be found here: https://ss64.com/ps/set-aduser.html                    
                    $script:msg += Set-ADUser -Identity "$svcacct" -ServicePrincipalNames @{Add=$MissingItems} -WhatIf:$WhatIf
                    $Changed=$true
                }    
            }
            catch {
                throw "Error trying to add SPN to svcacct:$($svcacct) $($_.exception.message)"   
            }
            
            
        }
    }
    else 
    {
        $ExtraSPNItems = Compare-Object -ReferenceObject $SPNListPre -DifferenceObject $SPN -IncludeEqual -ExcludeDifferent  -PassThru
        if($ExtraSPNItems)
        {
            try {
                #Set-AdUser examples can be found here: https://ss64.com/ps/set-aduser.html
                Set-ADUser -Identity "$svcacct" -ServicePrincipalNames @{Remove=$ExtraSPNItems} -WhatIf:$WhatIf
                $Changed=$true
            }
            catch {
                throw "Error trying to remove  SPN from svcacct:$($svcacct) $($_.exception.message)"   
            }            
        }
    }
    $SPNListPost = @((Get-ADUser -Identity "$svcacct" -Properties ServicePrincipalNames).ServicePrincipalNames)

    #Always Check for Dup records regardless of the process, this will cause to fail the playbook in case of any dup records. Because you can't have any dup SPN records at any time...
    #Note: checkForDup function will throw an exception when dup is detected...
    CheckForDup -svcacct "$svcacct" -spn $SPN -RemoveDupRecord $false -Whatif $Whatif |Out-Null
}
catch 
{
    throw "Error:$($_.exception.message)"
}

$output = @{
    svcacct          = $svcacct
    spn              = $spn
    state            = $state
    spnlistbefore    = $spnlistpre
    spnlistafter     = $spnlistpost
    removeduprecords = $removeduprecords
    changed          = $changed
    check_mode       = $WhatIf
    msg              = $msg
}


ConvertTo-Json $output
