<#
.SYNOPSIS
    This script suspends/deactivates active directory users based on input from a SharePoint list in SharePoint Online.
.NOTES
    File Name: New-UserSuspensionRequest.ps1
    Author   : Chris Edwards (christopher.edwards@outlook.com.au)
    Version  : 0.0.1
#>
param ( 
    [object]$WebhookData
)

#Import relevant Modules
Write-Verbose -Message "Checking and Importing MS PowerShell Defaults"
if (-not(Get-Module -Name Microsoft.PowerShell.Management, Microsoft.PowerShell.Security, Microsoft.PowerShell.Utility, Microsoft.WSMan.Management -ListAvailable)){
    Write-Warning "MS PowerShell Defaults are missing, Importing modules now."
    Import-Module -Name Microsoft.PowerShell.Management, Microsoft.PowerShell.Security, Microsoft.PowerShell.Utility, Microsoft.WSMan.Management -Scope CurrentUser -Force -AllowClobber
}
Import-Module ActiveDirectory -Verbose:$false
#Az likely to not be installed, run a check first. 
Write-Verbose -Message "Checking and Installing Azure Powershell Module"
if (-not(Get-Module -Name Az.Accounts -ListAvailable)){
    Write-Warning "Module 'Az.Accounts' is missing or out of date. Installing module now."
    Install-Module -Name Az.Accounts, Az.Resources, Az.Automation -Scope CurrentUser -Force -AllowClobber
}
Import-Module -Name Az.Accounts, Az.Resources, Az.Automation
#PnP (SharePoint PowerShell Online) likely to not be installed, run a check first. 
Write-Verbose -Message "Checking and Installing Azure Powershell Module"
if (-not(Get-Module -Name PnP.PowerShell -ListAvailable)){
    Write-Warning "Module 'PnP.PowerShell' is missing or out of date. Installing module now."
    Install-Module -Name PnP.PowerShell -Scope CurrentUser -Force -AllowClobber
}
Import-Module PnP.PowerShell
Import-Module Orchestrator.AssetManagement.Cmdlets -ErrorAction SilentlyContinue
Import-Module AzureAD #Session Revoking
Import-Module ExchangeOnlineManagement #Exchange Online Management

#Import the Required Assemblys from the Client components SDK (https://www.microsoft.com/en-us/download/details.aspx?id=35585)
[System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SharePoint.Client") | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SharePoint.Client.Runtime") | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName("System.Web") | Out-Null

#Define SharePoint Online Credentials with proper permissions
$Cred = Get-AutomationPSCredential -Name 'New-UserCreationRequest'

#SharePoint online address and list name
$SPOUrl = "https://korthcore.sharepoint.com/sites/AutomationTest/"
$SPOList = "New-UserCreationRequests"

#Column Name mapping in SharePoint List as Values with Script Variable Names as Keys
$SPListItemFields = @(
    'ID',
    'SubmitterEmail',
    'SubmitterName',
    'RequestStatus',
    'SuspendOrDisable',
    'FirstName',
    'LastName',
    'EmailAddress',
    'sAMAccountName',
    'AutoReply',
    'EmailForward',
    'MemberOf'
)

#begin functions
function Convert-ToLatinCharacters {
    param(
        [string]$inputString
    )
    [Text.Encoding]::ASCII.GetString([Text.Encoding]::GetEncoding("Cyrillic").GetBytes($inputString))
}

#Test AD User Exists
function Test-ADUser {
    param(
      [Parameter(Mandatory = $true)]
      [String] $sAMAccountName
    )
    $null -ne ([ADSISearcher] "(sAMAccountName=$sAMAccountName)").FindOne()
}

#Get the User sAMAccountName and Object based on the EmailAddress input from the Form (as this is unique to each User)
function Get-UserObject {
    param (
        [Parameter(Mandatory=$true)][string]$EmailAddress
    )

    $ADUser = @{}
    #User $EmailAddress to Get User Object
    $ADUser = Get-ADUser -Filter {userPrincipalName -eq $EmailAddress} -ErrorAction SilentlyContinue
  
    #Verify UserObject
    if ($ADUser) {
        $sAMAccountName = $ADUser.sAMAccountName
        $distinguishedName = $ADuser.distinguishedName

        #Get the User Type from which OU they belong to. Split to select the 3rd item in the list. This only works for MSSI and MSSA OUs. 
        $UserOU = Get-ADUser $ADUser | select @{l='UserType';e={$_.DistinguishedName.split(',')[2].split('=')[1]}}
        $UserType = $UserOU.UserType
    } else {
        Write-Verbose "The User $FirstName $LastName ($EmailAddress) does not appear to be in the system. Please verify you have provided the correct User Details."
    }

    #Store returned variables as Key/Pairs within Hashtable
    $ADUser.UserType = $UserType
    $ADUser.sAMAccountName = $sAMAccountName
    $ADUser.distinguishedName = $distinguishedName

    #Return Hashtable to use for the rest of the Process. 
    return $ADUser
}

#From Form Input determine which is the appropriate OU to target, Suspended or Disabled Users.
function Get-SuspendedOrDisabled {
    param (
        [Parameter(Mandatory=$true)][string]$SuspendOrDisable
    )

    $SuspendOrDisable = $SuspendOrDisable.Split(" ")[0]

    if ($SuspendOrDisable -eq "Suspend") {
        return "Suspended"
    } elseif ($SuspendOrDisable -eq "Disable") {
        return "Disabled"
    }
}

#Random Password Generator (this can be expanded upon)
function New-RandomPassword {
    param(
        [Parameter(Mandatory=$true)][int]$PasswordLength,
        [Parameter(Mandatory=$false)][int]$NumberOfAlphaNumericCharacters,
        [Parameter(Mandatory=$false)][switch]$ConvertToSecureString
    )

    $Password = [System.Web.Security.Membership]::GeneratePassword($PasswordLength,$NumberOfAlphaNumericCharacters) #This will need to be tested on PROD to ensure [System.Web.Security.Membership] can be used

    if ($ConvertToSecureString.IsPresent) {
        ConvertTo-SecureString -String $Password -AsPlainText -Force
    } else {
        $Password
    }
}

#Get MemberOf Data and Store in a local CSV for Audit/Historic Records Purposes, can be used to quickly restore access if a user returns to the same Role
function Remove-UserMemberOf {
    [CmdletBinding()]
    [Parameter(Mandatory=$true)][string]$sAMAccountName

    #Get-ADGroupMembership of User and store as an Array (except for Domain Users) #strip all
    $UserMemberOf = Get-ADPrincipalGroupMembership -Identity $sAMAccountName | Select Name

    #Loop through the list of Groups and remove from User Object
    foreach ($Group in $UserMemberOf) {
        Remove-ADGroupMember -Identity $Group.Name -Members $SamAccountName -Confirm:$false
    }

    return $UserMemberOf
}

#Get the list of Input Form Fields ($SanitiseCheck Hashtable) and verify the need to be sanitised.
##This should be updated down the track to allow single variables to be submitted, not just an array/hashtable.  
function Get-SanitisedVariables {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param (
        [Parameter(Mandatory=$true,ValueFromPipeline=$true)]$SanitiseCheck
    )

    #Enumerate through the values of the $SanitiseCheck hashtable and check each item to see if it needs to be sanitised. 
    $SanitiseCheck.GetEnumerator() | ForEach-Object{
        $key = '{0}' -f $_.key, $_.value
        $value = '{1}' -f $_.key, $_.value.Old
        $SanitiseCheck = [PSCustomObject]$SanitiseCheck
    
        if (($key -eq "FirstName") -or ($key -eq "LastName")) {
            #If the new value does not match the '[\W\d\s]' Regex, remove from the Hashtable. 
            if ($value -NotMatch '[\W\d\s]') {
                $SanitiseCheck.psobject.properties.remove($key)
            }
        }
    }

    #Convert PSObject Back to HashTable.
    $SanitiseChecked = @{}
    $SanitiseCheck.psobject.properties | ForEach { $SanitiseChecked[$_.Name] = $_.Value }

    return $SanitiseChecked
}

#For those items that require sanitisation, run through and sanitise them. 
##This should be updated down the track to allow single variables to be submitted, not just an array/hashtable. 
function Set-SanitisedVariables {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param (
        [Parameter(Mandatory=$true,ValueFromPipeline=$true)]$SanitiseChecked
    )

    #Enumerate through the $SanistiseChecked Table
    $SanitiseChecked.GetEnumerator() | ForEach-Object{
        $key = '{0}' -f $_.key, $_.value
        $oldValue = '{1}' -f $_.key, $_.value.Old
        
        #Do different Regex replacements depending on the form field. 
        if (($key -eq "FirstName") -or ($key -eq "LastName")) {
            #Set the 'New' value as the sanitised string with the [\W\d\s] regex targeting
            $newValue = $($oldValue -replace '[\W\d\s]','')
        }
    
        #Add the new values above under a 'New' key alongside the Old values. 
        $SanitiseChecked.$key.Add("New",$newValue)
    }

    return $SanitiseChecked
}
#end functions

#Connect to SharePoint Online
Try {
    #Connect to PnP Online
    Connect-PnPOnline -Url $SPOUrl -Credentials $Cred
}
catch {
    Write-Verbose "Error: $($_.Exception.Message)"
}

$UserData = (Get-PnPListItem -List $SPOList -Fields $SPListItemFields)

foreach ($User in $UserData) {
    #Grab List ID and Status 
    $ListItem = $User["ID"]
    $Status = $User["RequestStatus"]

    #Store Relevant attributes as Variables for the User from Form Data
    $SuspendOrDisable = Get-SuspendedOrDisabled -SuspendOrDisable $User.SuspendOrDisable
    $PasswordLength = 12
    $NumberOfAlphaNumericCharacters = 2  
    $UPNSuffix = 'korthcore.com'
    $FirstName = $User["FirstName"]
    $LastName = $User["LastName"]
    $EmailAddress = $User["EmailAddress"]
    $EmailForward = $User["EmailForward"]
    $AutoReply = $User["AutoReply"]

    #Create an ordered Hashtable to store inputs requiring sanitisation and linking them against the $SPListItemFields Key.
    $SanitiseCheck = [ordered]@{
        "FirstName" = @{Old = $FirstName}
        "LastName" = @{Old = $LastName}
        #Likely not use these as validating an email w/ regex is not recommended. 
        #"EmailAddress" = @{Old = $EmailAddress}
        #"EmailForward" = @{Old = $EmailForward}
    }
    
    #Check the Input Text Field Variables to see if they require sanitisation. Remove those that do not. 
    $SanitiseChecked = Get-SanitisedVariables -SanitiseCheck $SanitiseCheck
    
    #Only process a sanitisation if required, if HashTable is empty skip. 
    if ($SanitiseChecked.Count -ne 0) {
        #Sanitise the variables and set as a new item within the Hashtable under "New"
        $SanitiseChecked = Set-SanitisedVariables -SanitiseChecked $SanitiseChecked

        #Update Variables with new Sanitised strings, but only if they are not null
        ## This is a pretty dirty method, look to find a cleaner way to do this. 
        if ($null -ne $SanitiseChecked.FirstName.New) {
            $FirstName = $SanitiseChecked.FirstName.New
        }
        if ($null -ne $SanitiseChecked.LastName.New) {
            $LastName = $SanitiseChecked.LastName.New
        }
    }
    
    #Get the User Object from Active Directory from the $EmailAddress variable. This is required to process much of the script. 
    $ADUser = Get-UserObject -EmailAddress $EmailAddress
    $sAMAccountName = $ADUser.sAMAccountName
    $distinguishedName = $ADUser.distinguishedName
    $UserType = $ADUser.UserType
    
    #Set the Target OU for the User Type (MSSI or MSSA) based upon their Type and if Suspended or Disabled
    $TargetOU = "OU=$($SuspendOrDisable) Users,OU=$($UserType),OU=Company,DC=korthcore,DC=com,DC=au"
    
    #Start by Generating a new Random Password and resetting the User Password on the Object
    $Password = New-RandomPassword -PasswordLength $PasswordLength -NumberOfAlphaNumericCharacters $NumberOfAlphaNumericCharacters -ConvertToSecureString
    
    #Process the script only if Get-UserObject returns a result. 
    if ($ADUser) {
        #Start by immediately resetting the Account Password.
        Set-ADAccountPassword -Identity $sAMAccountName -NewPassword $Password -Reset

        #Disable the User Account as first step for security. 
        Get-ADUser -Identity $sAMAccountName | Disable-ADAccount

        #Remove User MemberOf and store data as $UserMemberOf variable
        $UserMemberOf = Remove-UserMemberOf -sAMAccountName $sAMAccountName

        #Remove Users extensionAttribute settings to ensure clear (Global Address List, Printer PIN, O365 License Type)
        Set-ADUser -Identity $sAMAccountName -Clear "extensionAttribute7", "extensionAttribute10", "extensionAttribute13", "extensionAttribute14"
        
        #Move the User Account to the relevant OU
        Move-ADObject -Identity $distinguishedName -TargetPath $TargetOU
        
        #Exchange Auto Reply
        Connect-ExchangeOnline -Credential $Cred
        Set-MailboxAutoReplyConfiguration -Identity $EmailAddress -AutoReplyState Enabled -InternalMessage $AutoReply -ExternalMessage $AutoReply

        #Forwarding Mail
        Set-Mailbox -Identity $EmailAddress -DeliverToMailboxAndForward $true -ForwardingSMTPAddress $EmailForward
        
        #Session Termination within O365
        Connect-AzureAD -Credential $Cred
        $ObjectID = (Get-AzureADUser -SearchString $sAMAccountName).ObjectID
        Revoke-AzureADUserAllRefreshToken -ObjectId $ObjectID

        #Run an AAD Connect Sync to ensure all changes are pushed immediately to Azure AD
        Start-ADSyncSyncCycle -PolicyType Delta

        #Update the SPOList RequestStatus to now be 'Complete' doing so here allows it to be run per loop, not per individual Form submission. 
        #Get the Timestamp and convert to UTC Time. 
        $timestamp = ((Get-Date).ToString('yyyy-MM-ddTHH:mm:ss'))
        $datetime  = ([DateTime]$timestamp).ToUniversalTime()
        #Convert from UTC Time to the local Timezone
        $lastUpdated = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId($datetime, 'AUS Eastern Standard Time')
        
        try {
            #Create a Splat of inputs for Set-PnPListItem
            $SPOUpdate = @{
                List = $SPOList
                Identity = $ListItem
                #Values within is it's own Hashtable to update the individual SPOList columns. 
                Values = @{
                    "RequestStatus" = "Complete"
                    "CompletionTime" = "$lastUpdated"
                    "LastUpdated" = "$lastUpdated"
                    "sAMAccountName" = "$sAMAccountName"
                    "FirstName" = "$FirstName"
                    "LastName" = "$LastName"
                    "JobTitle" = "$Title"
                    "DeskTelephoneNumber" = "$OfficePhone"
                    "MobileNumber" = "$MobilePhone"
                }
            }
            
            #Take the new values, including sanitised values, and update them on the SharePoint List Item. Set RequestStatus to complete. 
            Set-PnPListItem @SPOUpdate
        } catch {
            Write-Error "Error updating the user details in $SPOList SharePoint List `r`n$_"
        }
    } else {
        Write-Host "The User $FirstName $LastName ($EmailAddress) does not appear to be in the system. Please verify you have provided the correct User Details."
    }
}

#Disconnect from all opened sessions. 
Try {
    Disconnect-PnPOnline
    Disconnect-ExchangeOnline
    Disconnect-AzureAD
}
catch {
    Write-Verbose "Error: $($_.Exception.Message)"
}