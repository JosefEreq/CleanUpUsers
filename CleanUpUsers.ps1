

<#

This script cleans up users, according to conditions specified in CleanUpUsers.csv:
    It disables accounts in specified OUs, that have not logged on for a specified amount of time.
    It removes licenses on disabled user accounts that are synced to AzureAD.
    It deletes disabled users in specified OUs, that have not been modified for a specified amount of time.


Author 
Josef Ereq

Version 1.1

#> 

# - Specify input file for parameter-values.
$InputFile = ".\CleanUpUsersInput.csv"
$InputData = import-csv $InputFile -Delimiter ";"

#- Specify control properties for what checks to execute.
$RunInactivityFunction = ($InputData | where {$_.Property -eq "ControlInactivity"}).value
$RunLicenseFunction = ($InputData | where {$_.Property -eq "ControlLicense"}).value
$RunDeletionFunction = ($InputData | where {$_.Property -eq "ControlDeletion"}).value

# - Import list of attributes to clear when disabling a user.
$AttributeClearOnDisable = (($InputData | where {$_.Property -eq "AttributeClearOnDisable"}).value).Split(",")


# - Specify credentials for connection to AzureAD and Exchange Online.

$AADCred = Import-CliXml -Path "AAD_upn+hash.cred"

$EXOCred = Import-CliXml -Path "EXO_upn+hash.cred"

#  - Specify Exchange server URI to connect to.
$ExchURI = ($InputData | where {$_.Property -eq "ExchConnectionURI"}).value
    
# - Import the Active Directory module.
import-module activedirectory


#- Specify domain controller to work on.
$Server = ($InputData | where {$_.Property -eq "DomainController"}).value


#  - Specify home-OUs for the different kind of accounts to check.
$UserAccOU = ($InputData | where {$_.Property -eq "UserAccountOU"}).value
$AdminAccOU = ($InputData | where {$_.Property -eq "AdminAccountOU"}).value


# - Specify disabled-OUs for the different kind of accounts.
$UserAccDABOU = ($InputData | where {$_.Property -eq "UserAccountDisabledOU"}).value
$AdminAccDABOU = ($InputData | where {$_.Property -eq "AdminAccountDisabledOU"}).value


# - Specify the name of the group for which the members should be exluded from being disabled. Load the group members into a separate variable.
$ExclGrp = ($InputData | where {$_.Property -eq "ExcludeDisableGroup"}).value

$ExclUsrs = (Get-ADGroupMember $ExclGrp -server $($Server)).distinguishedName


# - Specify name-prefix for service accounts.
$SAPrefix = ($InputData | where {$_.Property -eq "ServiceAccountPrefix"}).value


# - Specify log path, and log-files for each operation.
$LogPath = ($InputData | where {$_.Property -eq "LogPath"}).value
$LogDelete = (Join-Path $LogPath "Deleted_$(get-date -Format yyyyMMdd).txt")
$LogDisabled = (Join-Path $LogPath "Disabled_$(get-date -Format yyyyMMdd).txt")
$LogLicense = (Join-Path $LogPath "LicensesRemoved_$(get-date -Format yyyyMMdd).txt")


# - Specify format for description set on disabled users.
$DABForm = ($InputData | where {$_.Property -eq "DisableStampRegEx"}).value


# -Specify format(regex) for description on users that should be exluded from being disabled.
$ExclDescription = ($InputData | where {$_.Property -eq "ExcludeDisableStampRegEx"}).value


# - Set todays date, into a variable. This will be used for calculating criterias limits for disabling and deleting accounts.
$date = get-date


# - Specify the limits for disabling and deleting users, in amount of days. Also specify limits for excluding newly created accounts and recently modified accounts.
$DaysDelete = ($InputData | where {$_.Property -eq "DisabledDaysBeforeDelete"}).value
$DaysLogon = ($InputData | where {$_.Property -eq "InactiveDaysBeforeDisable"}).value
$DaysCreate = ($InputData | where {$_.Property -eq "ExcludeDisableCreationLimit"}).value
$DaysModify = ($InputData | where {$_.Property -eq "ExcludeDisableModifyLimit"}).value

    ## - Create date-variables from limits specified above.
    $LimitLogon = ($date).AddDays(-$($DaysLogon))
    $LimitCreate = ($date).AddDays(-$($DaysCreate))
    $LimitModify = ($date).AddDays(-$($DaysModify))
    $LimitDeleteStamp = ($date).AddDays(-$($DaysDelete)).tostring("yyyyMMdd")
    $LimitDeleteModified = ($date).AddDays(-$($DaysDelete))

# - Set todays date in specified format, into a variable. This will be used for time-stamping users when they get disabled.
$DABStamp = get-date -Format yyyyMMdd

# - Specify description text for users getting disabled for inactivity.
$DescriptionDAB = ($InputData | where {$_.Property -eq "InactiveStamp"}).value
$DescriptionDABForm = $DescriptionDAB -replace "(\133DISABLEDATE\135)","$DabStamp" -replace "(\133INACTIVEDAYS\135)","$DaysLogon"


Function DisableInactiveUsers()
    {
    # - Set the execution-parameter for the function.
    Param(
    [Parameter(Mandatory=$true,Position=0)]
    [string]$Enabled
        )
    if($Enabled -eq $TRUE)
        {

        # - Specify the ADuser-properties to load when fetching the users. Specify as arrays.
        $DabProperties = @("createTimeStamp","whenChanged","Modified","modifyTimeStamp","name","pwdLastSet","lastlogontimestamp","whencreated","mail","lastlogon","description","memberof")
        # - Load all users objects used for the disable operaion, into separate variables.
        $DabUsers = @()
        $DabUsers += get-aduser -server $($Server) -filter {enabled -eq $true} -Properties $DabProperties -SearchBase $AdminAccOU -SearchScope Subtree
        $DabUsers += get-aduser -server $($Server) -filter {enabled -eq $true} -Properties $DabProperties -SearchBase $UserAccOU -SearchScope Subtree
        
        # - Create a session to Exchange Online.
        $EXOSESSION = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri $ExchURI -Credential $EXOCred -Authentication Basic -AllowRedirection -Name "365"
        Import-PSSession $EXOSESSION

        # - Loop trough all users for the disable-operation.
        foreach ($DabUser in $DabUsers)
                {
                # - Load the timestamp for when users logged on to domain controller or Office365-mailbox, into to variables.
                $LogonEXO = $null
                $LogonAD1 = $null
                $LogonAD2 = $null
                $PSWAD = $null
                $LogonEXO = (Get-MailboxStatistics -Identity "$(($DabUser).userprincipalname)" -WarningAction ignore -ErrorAction ignore).LastLogonTime
                $LogonAD1 = [datetime]::FromFileTime($DabUser.lastlogon)
                $LogonAD2 = [datetime]::FromFileTime($DabUser.lastlogontimestamp)
                $PSWAD = [datetime]::FromFileTime($DabUser.pwdLastSet)
                
                # - Check if the user meets the critiera for being disabled, based on the creation-limit, modify-limit and logon-limit.
                # - Dont loop the user if it's member of the exclusion-group, has a description matching the exclusion-string or have a name matching the service account-prefix.
                if ( ($DabUser.createTimeStamp -lt $LimitCreate) -and ($DabUser.Modified -lt $LimitModify) -and ($DabUser.whenChanged -lt $LimitModify) -and ($DabUser.modifyTimeStamp -lt $LimitModify) -and ($PSWAD -lt $LimitLogon) -and ($LogonEXO -lt $LimitLogon) -and ($LogonAD1 -lt $LimitLogon) -and ($LogonAD2 -lt $LimitLogon) -and ($ExclUsrs -notcontains $DabUser.distinguishedName) -and ($DabUser.Description -notmatch "$($ExclDescription)") -and ($DabUser.name -notmatch "^$($SAPrefix)") )
                    {           
                    # - Set the disable stamp on the users description.
                    Set-ADUser -Server $($Server) $DabUser -Description "$($DescriptionDABForm)"
                    # - Disable the user account.
                    Disable-adaccount $DabUser -server $($Server)   
  
                    # - Loop trough each entry of attributes to clear when disabling a user, and clear that attribute.
                    foreach($AttributeClear in $AttributeClearOnDisable)
                        {
                        $DabUser | Set-ADUser -Server $($Server) -clear $AttributeClear
                        }
                
                    # - Take the distinguished name for the OU that the user is located in, from the distinguished name of the user, into a separate variable.
                    $UserOU = ($DabUser.DistinguishedName).Substring(($DabUser.distinguishedName).IndexOf(",")+1)
                    # - If the user is located in the organizational unit for user accounts, move it to the matching OU for disabled users.
                    if($UserOU -match "$($UserAccOU)")
                        {
                        if($UserAccDABOU)
                            {                            
                            $DabUser | Move-ADObject -Server $($Server) -TargetPath $UserAccDABOU
                            }
                        }                
                    # - If the user is located in the organizational unit for admin accounts, move it to the matching OU for disabled users.
                    elseif($UserOU -match "$($AdminAccOU)")
                        {
                        if($AdminAccDABOU)
                            {                            
                            $DabUser | Move-ADObject -Server $($Server) -TargetPath $AdminAccDABOU
                            }
                        }                
                    # - Output the name of the user into the log-file.
                    $DabUser.name | out-file $LogDisabled -append  

                    }
            


                }
            Remove-PSSession $EXOSESSION
            }
        }


Function DeleteOldUsers()
    {
    # - Set the execution-parameter for the function.
    Param(
    [Parameter(Mandatory=$true,Position=0)]
    [string]$Enabled
        )
    if($Enabled -eq $TRUE)
        {

        # - Specify the ADuser-properties to load when fetching the users. Specify as arrays.
        $DelProperties = @("name","description","Modified","modifyTimeStamp","distinguishedname")

        # - Loop trough all users for the deletion-operation.
        $DelUsers = @()
        $DelUsers += get-aduser -filter {enabled -eq $false} -Server "$($server)" -Properties $DelProperties -SearchBase $UserAccOU -SearchScope Subtree
        $DelUsers += get-aduser -filter {enabled -eq $false} -Server "$($server)" -Properties $DelProperties -SearchBase $AdminAccOU -SearchScope Subtree

        # - Loop trough all users for the deletion-operation.
        foreach ($DelUser in $DelUsers)
                {
        
                # - Get the newest date from the attributes that is used to date when the acccount was modified.
                $ModMax = ($DelUser.Modified),($DelUser.modifyTimeStamp) | measure -Maximum
                $DabStampMatch = $null
                # - Check if the description of the user match the disable stamp.
                $DabStampMatch = $DelUser.description | select-string -Pattern $dabform -AllMatches | %{$_.matches.value}
                if($DabStampMatch)
                   {
                   $DabDate = $DabStampMatch | select-string -Pattern "(\d){8}" -AllMatches | %{$_.matches.value | where {$_}}
                   # - Check if the date for when the user was disabled(from the description) exceds the specified limit. If so, run the script.
                    if ($DabDate -lt $LimitDeleteStamp)
                        {
                        # - Delete the user account and save the name of the user in to a log file.
                        $DelUser | Remove-adobject -server $($server) -Confirm:$false -Recursive   
                        $DelUser.name | out-file $LogDelete -append

                        }

                   }


                # - If the condition for user description wasnt meet above, check if the time when user was last modified exceds the specified limit. If so, run the script.
                elseif ($ModMax.maximum -lt $LimitDeleteModified)
                    {
                    # - Delete the user account and save the name of the user in to a log file.
                    $DelUser | Remove-adobject -server $($server) -Confirm:$false -Recursive       
                    $DelUser.name | out-file $LogDelete -append

                    }

                }
            }
    }



Function RemoveUnusedLicenses()
    {
    # - Set the execution-parameter for the function.
    Param(
    [Parameter(Mandatory=$true,Position=0)]
    [string]$Enabled
        )
    if($Enabled -eq $TRUE)
        {
        # - Specify the ADuser-properties to load when fetching the users. Specify as arrays.
        $LicProperties = @("Modified","modifyTimeStamp","Description","userprincipalname","whenChanged")

        # - Load all users used for license removal-operation, into a variable.
        $LicUsers = get-aduser -server "$($Server)" -filter {enabled -eq $false} -Properties $LicProperties
        
        # - Connect to AzureAD.
        Connect-MsolService -Credential $AADCred

        # - Loop trough all users for the license removal-operation.
        foreach ($LicUser in $LicUsers)
            {
            # - Check if the user is not modified during the modify time-limit. If so, run the script block.
            if ( ($LicUser.Modified -lt $LimitModify ) -and ($LicUser.whenChanged -lt $LimitModify) -and ($LicUser.modifyTimeStamp -lt $LimitModify) )
                {
                # - Check if the user is synced to AzureAD, if so, set it into a variable.
                $MSOLUsr = $null
                $MSOLUsr = get-msoluser -UserPrincipalName $LicUser.UserPrincipalName -ErrorAction ignore -WarningAction ignore
          
                # - Check if the user is licensed.
                if ($Msolusr.islicensed -eq $true)
                    {
                    # - Load all assigned users licenses into a variable.
                    $AccountSkuIds = $msolusr.licenses.AccountSkuId
                    # - Loop trough each of the user license, and un-assign it.
                    foreach($Lic in $AccountSkuIds)
                        {
                        $Msolusr | Set-MsolUserLicense -RemoveLicenses $Lic                        
                        }
                    $MSOLUsr = get-msoluser -UserPrincipalName $LicUser.UserPrincipalName -ErrorAction ignore -WarningAction ignore
                    if ($Msolusr.islicensed -eq $false)
                        {
                        # - Output the name of the user into the log-file.
                        $LicUser.name | out-file $LogLicense -append
                        }
                    }

                }



            }
        }
    }


DisableInactiveUsers $RunInactivityFunction
DeleteOldUsers $RunDeletionFunction
RemoveUnusedLicenses $RunLicenseFunction 

