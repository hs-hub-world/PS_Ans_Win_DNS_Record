#!powershell
<#
    win_dns_record.ps1
    (c) 2021 Harry Saryan
    This script can be used as an Ansible module to manage DNS record(s)
    Note, this script preferably should be executed on a remote note that has all the necessary PS Modules installed (i.e. DNS, AD, etc..)    
    
#>


param(
    $name="ServiceAlias1",
    [validateset("present","absent")]    
    $state="absent",
    $ttl="3600",
    [validateset("A","AAAA","CNAME","PTR")]     
    $type="CNAME",
    $value=@("server.domain.local"),    
    $zone="domain.local",
    $dns_server="dc-server1",
    $WhatIf=$false
)

#NOTE: _LoadAllModules.ps1  may not be available/be part of this repo!
. "Modules\_LoadAllModules.ps1"  -ErrorAction Stop   #Dot sourcing

[bool]$WhatIf   = ConvertStringToBool $WhatIf
$Changed=$false


function fn_SyncAllDNSServers
{
    param(
        $zone,
        $dnsServer
    )
    $AllDNSServers = Get-DnsServerResourceRecord -ZoneName $zone -RRType "NS" -Node -ErrorAction:Ignore -ComputerName "$dnsServer"
    #write "Syncing DNS zones"
    $SyncJobs=@()
    foreach($Dns in @($AllDNSServers.RecordData.NameServer))
    {
        #write "Syncing:$($Dns)"
        $SyncJobs += Sync-DnsServerZone -Name "$zone" -PassThru -ComputerName $Dns -AsJob -ErrorAction SilentlyContinue
    }
    
    while($SyncJobs.State -eq "Running")
    {
        #Sync jobs running...
        sleep -Seconds 3
    }
    #$SyncJobs|Receive-Job  #Do not output sync jobs.. not necessary
}

$extra_args = @{}
if ($dns_server) {
    $extra_args.ComputerName = $dns_server
}





# TODO: add warning for forest minTTL override -- see https://docs.microsoft.com/en-us/windows/desktop/ad/configuration-of-ttl-limits
if ([int]$ttl -lt 1 -or [int]$ttl -gt 31557600) {
    throw "Parameter 'ttl' must be between 1 and 31557600"
}
$ittl = New-TimeSpan -Seconds $ttl


if (($type -eq 'CNAME' -or $type -eq 'PTR') -and $value -and $zone[-1] -ne '.') {
    # CNAMEs and PTRs should be '.'-terminated, or record matching will fail
    $value = "$($value)."  #Add period at the end
    
    # $values = $values | ForEach-Object {
    #     if ($_ -Like "*.") { $_ } else { "$_." }
    # }
}


$record_argument_name = @{
    A = "IPv4Address";
    AAAA = "IPv6Address";
    CNAME = "HostNameAlias";
    # MX = "MailExchange";
    # NS = "NameServer";
    PTR = "PtrDomainName";
    # TXT = "DescriptiveText"
}[$type]


$changes = @{
    before = "";
    after = ""
}

#So we don't have to wait for DNS zone replication we'll be updating each DNS server separately 
#for that we need to get all the NS records
$AllDNSServers = Get-DnsServerResourceRecord -ZoneName $zone -RRType "NS" -Node -ErrorAction:Ignore -ComputerName "$dns_server"

$records = Get-DnsServerResourceRecord -ZoneName $zone -Name $name -RRType $type -Node -ErrorAction:Ignore @extra_args  | Sort-Object
$record = $records |?{$_.RecordData.$record_argument_name.ToString() -eq $value}    

if ($record) 
{   

    if($state -eq "present")
    {
        #Record should be present, validate TTL state         
        if ($record.TimeToLive -ne $ittl) {
            $new_record = $record.Clone()
            $new_record.TimeToLive = $ittl
            Set-DnsServerResourceRecord -ZoneName $zone -OldInputObject $record -NewInputObject $new_record -WhatIf:$WhatIf @extra_args
            $changes.before += "[$zone] $($record.HostName) $($record.TimeToLive.TotalSeconds) IN $type $record_value`n"
            $changes.after += "[$zone] $($record.HostName) $($ittl.TotalSeconds) IN $type $record_value`n"
            $Changed = $true                 
        }
    }
    else 
    {
        #absent
        #Remove it from all DNS servers
        $record | Remove-DnsServerResourceRecord -ZoneName $zone -Force -WhatIf:$WhatIf @extra_args

        foreach($Server in @($AllDNSServers.RecordData.NameServer |?{$_ -notmatch $dns_server}))
        {
            try {
                $record | Remove-DnsServerResourceRecord -ZoneName $zone -Force -WhatIf:$WhatIf -ComputerName "$Server" -ErrorAction SilentlyContinue
            }
            catch {
                #ignore
            }
            
        }
        
        $changes.before += "[$zone] $($record.HostName) $($record.TimeToLive.TotalSeconds) IN $type $record_value`n"
        $Changed = $true
    }
}
elseif ($state -eq "present")
{
    #record is missing or record same name has another value. and state is present
    $splat_args = @{ $type = $true; $record_argument_name = $value }
    #$module.Result.debug_splat_args = $splat_args

    try {
        #First add record to the assignd DNS Server (main dns server)
        Add-DnsServerResourceRecord -ZoneName $zone -Name $name -AllowUpdateAny -TimeToLive $ittl @splat_args -WhatIf:$WhatIf @extra_args

        #Then add to the remaining DNS servers and ignore any errors
        foreach($Server in @($AllDNSServers.RecordData.NameServer |?{$_ -notmatch $dns_server}))
        {
            #Add record to all DNS servers zones
            try {
                Add-DnsServerResourceRecord -ZoneName $zone -Name $name -AllowUpdateAny -TimeToLive $ittl @splat_args -WhatIf:$WhatIf -ComputerName "$Server" -ErrorAction SilentlyContinue
            }
            catch {
                #ignore as long as the assignd dns server record was added successfuly, any failures will eventually replicate
            }
            
        }
        
    } catch {
        throw "Error adding DNS $($type) resource $($name) in zone $($zone) with value $($value): $($_.exception.message)"
    }
    $changes.after += "[$zone] $name $($ittl.TotalSeconds) IN $type $value`n"
    $Changed = $true
}




if (!$WhatIf) {
    # Real changes
    $records_end = Get-DnsServerResourceRecord -ZoneName $zone -Name $name -RRType $type -Node -ErrorAction:Ignore @extra_args | Sort-Object

    $changes.before = @($records | ForEach-Object { "[$zone] $($_.HostName) $($_.TimeToLive.TotalSeconds) IN $type $($_.RecordData.$record_argument_name.ToString())`n" }) -join ''
    $changes.after = @($records_end | ForEach-Object { "[$zone] $($_.HostName) $($_.TimeToLive.TotalSeconds) IN $type $($_.RecordData.$record_argument_name.ToString())`n" }) -join ''
}

if($changed)
{
    fn_SyncAllDNSServers -zone "$zone" -dnsServer "$dns_server"
}

$output = @{
    name              = $name
    ttl               = $ittl
    type              = $type
    value             = $value
    zone              = $zone
    dns_computer_name = $dns_server
    state             = $state
    before            = $changes.before
    after             = $changes.after
    changed           = $changed
    check_mode        = $WhatIf
    msg               = $msg
}

ConvertTo-Json $output
