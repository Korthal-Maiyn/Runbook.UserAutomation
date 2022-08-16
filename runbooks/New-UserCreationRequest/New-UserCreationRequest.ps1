<#
.SYNOPSIS
    This script creates active directory users based on input from a SharePoint list, which is populated with data from a Form submission. An Azure Logic App processes this script to automate the New User Creation process.
.NOTES
    File Name: New-UserCreationRequest.ps1
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

#Import the Required Assemblys from the Client components SDK (https://www.microsoft.com/en-us/download/details.aspx?id=35585)
[System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SharePoint.Client") | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SharePoint.Client.Runtime") | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName("System.Web") | Out-Null

#Define SharePoint Online Credentials with proper permissions.
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
    'NewUserMSSIorMSSA',
    'NewOrExistingRole',
    'NewUserCasual',
    'ContractEndDate',
    'O365LicenseType',
    'FirstName',
    'LastName',
    'sAMAccountName',
    'JobTitle',
    'DeskTelephoneNumber',
    'MobileNumber',
    'NewUserPrimaryLocation',
    'NewUserAdditionalLocation',
    'MSSINetworkDrives',
    'ApplicationsRequired',
    'MSSIDistributionList',
    'MSSADistributionList',
    'MOSAudienceGroup'
)

#The below is considered bad practice, however due to the current configuration of Active Directory this is the current easiest method for SG/DL Targeting.
#Generate an Application HashTable to determine Application names for associated Security Groups.
$AppTable = @{
    "Application Name" = "Associated-Security-Group"
}

# Signature HashTable for Exlaimer Security Groups for Email Signature Generation
$SigTable = @{
    "Office Location" = "Associated-Signature-Security-Group"
}

#Generate a Network Drive HashTable to determine Network Drive names for associated Security Groups
$NDriveTable = @{
    "D: - Drive Name" = "Network-Drive-Security-Group"
}

#Generate a MSSI Distribution List HashTable to determine Names and associated Distribution Groups
$MSSIDistTable = @{
    "Distribution List Name" = "MSSI-Distribution-List-Group"
}

#Generate a MSSA Distribution List HashTable to determine Names and associated Distribution Groups
$MSSADistTable = @{
    "Distribution List Name" = "MSSA-Distribution-List-Group"
}

#begin functions
function Convert-ToLatinCharacters {
    param(
        [string]$inputString
    )
    [Text.Encoding]::ASCII.GetString([Text.Encoding]::GetEncoding("Cyrillic").GetBytes($inputString))
}

#Get ADUser Distinguished Name. 
function Get-DNFromUPN {
    param (
        [ValidateScript({Get-ADUser -Filter {UserprincipalName -eq $ManagerUPN}})] 
        [Parameter(Mandatory=$true)][string]$UserPrincipalName
    )
        $ADUser = Get-ADUser -Filter {UserprincipalName -eq $ManagerUPN} -ErrorAction stop
        return $ADUser.distinguishedname
}

#Generate a sAMAccountName from FirstName and LastName inputs. 
function New-sAMAccountName {
    param (
        [Parameter(Mandatory=$true)][string]$FirstName,
        [Parameter(Mandatory=$true)][string]$LastName
    )
    #Construct the base sAMAccountName from Users FirstName and LastName. 
    $BaseSam = "{0}.{1}" -f (Convert-ToLatinCharacters $FirstName),(Convert-ToLatinCharacters $LastName)
  
    #Add a number until you find a free sAMAccountName
    if (Get-ADUser -Filter {samaccountname -eq $BaseSam} -ErrorAction SilentlyContinue) {
        $index = 0
        do {
            $index++
            $sAMAccountName = "{0}{1}" -f $BaseSam.ToLower(),$index
        } until (-not(Get-ADUser -Filter {samaccountname -eq $sAMAccountName } -ErrorAction SilentlyContinue))
    } else {
        $sAMAccountName = $BaseSam.tolower()
    }
    return $sAMAccountName
}

#Generate UPN from FirstName, LastName and the UPNSuffix
function New-UPNandMail {
    param (
        [Parameter(Mandatory=$true)][string]$FirstName,
        [Parameter(Mandatory=$true)][string]$LastName,
        [Parameter(Mandatory=$true)][string]$UPNSuffix
     )
    #Construct the base userPrincipalName
    $BaseUPN = "{0}.{1}@{2}" -f (Convert-ToLatinCharacters $FirstName).tolower(),(Convert-ToLatinCharacters $LastName).tolower(),$UPNSuffix
      
    if (Get-ADUser -Filter {userprincipalname -eq $BaseUPN} -ErrorAction SilentlyContinue) {
        $index = 0
        do {
            $index++
            $UserPrincipalName = "{0}{1}@{2}" -f $BaseUPN.Split("@")[0],$index,$UPNSuffix
        } until (-not(Get-ADUser -Filter {userprincipalname -eq $UserPrincipalName} -ErrorAction SilentlyContinue))
  
    } else {
        $UserPrincipalName = $BaseUPN
    }
    return $UserPrincipalName
}

# If UserLocation is set as an Office, create relevant Address Fields to store against AD Object relevant to Location provided. 
function Get-UserOfficeDetails {
    param (
        [Parameter(Mandatory=$true)][string]$UserLocation
    )
    Begin {
        Write-Verbose "In Begin Block: Get-UserOfficeDetails"
        [hashtable] $UserOffice = @{}
        $StreetAddress = ""
        $City = ""
        $PostCode = ""
    }
    Process{
        Write-Verbose "In Process Block: Get-UserOfficeDetails"
        if ($UserLocation -eq "Office - Location 1") {
            $UserOffice = @{StreetAddress = "Location 1 Address"; City = "Location 1"; PostCode = "XXXX"}
        } elseif ($UserLocation -eq "Office - Location 2") {
            $UserOffice = @{StreetAddress = "Location 2 Address"; City = "Location 2"; PostCode = "XXXX"}
        } elseif ($UserLocation -eq "Office - Location 3") {
            $UserOffice = @{StreetAddress = "Location 3 Address"; City = "Location 3"; PostCode = "XXXX"}
        } elseif ($UserLocation -eq "Office - Location 4") {
            $UserOffice = @{StreetAddress = "Location 4 Address"; City = "Location 4"; PostCode = "XXXX"}
        } else {
            $UserOffice = @{StreetAddress = $null; City = $null; PostCode = $null}
        }
    }
    End{
        Write-Verbose "In End Block: Get-UserOfficeDetails"
        return $UserOffice
    }
}

#Determine which AddressBook is required based on Form Input and return correct entry for AD User.
function Get-UserAddressList {
    param (
        [Parameter(Mandatory=$true)][string]$AddressBook
    )

    if ($AddressBook -eq "MSSA") {
        return "DHHS"
    } elseif ($AddressBook -eq "MSSI") {
        return "MSS"
    } elseif ($AddressBook -eq "Both") {
        return "ALL"
    }
}

#Process Applications Required in to a Readable Array to add to relevant Security Groups upon User Creation
function Get-ApplicationList {
    param (
        [Parameter(Mandatory=$true)][AllowEmptyString()][string[]]$ApplicationsRequired,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string[]]$UserType
    )
    Begin {
        Write-Verbose "In Begin Block: Get-ApplicationList"
        #Generate an empty Application ArrayList to store values in.
        $ApplicationList = @()
    }
    Process{
        Write-Verbose "In Process Block: Get-ApplicationList"
        #Format $ApplicationList into a PowerShell Array. 
        $ApplicationList = $ApplicationsRequired.Replace('[','').Replace(']','').Replace('"','').Split(',')

        #Add Default Desktop (Citrix) to Applications List
        $ApplicationList += "Desktop (Citrix)"

        #If New User is of MSSA Type, add Kronos Security Group as default as well. 
        if ($UserType -eq "MSSA") {
            $ApplicationList += "MSSA Kronos"
        }
    }
    End{
        Write-Verbose "In End Block: Get-ApplicationList"
        return $ApplicationList
    }
}

#Process Network Drives Required in to a Readable Array to add to relevant Security Groups upon User Creation
function Get-NetworkDriveList {
    param (
        [Parameter(Mandatory=$true)][AllowEmptyString()][string[]]$MSSIDrives
    )
    Begin {
        Write-Verbose "In Begin Block: Get-NetworkDriveList"
        #Generate an empty Network Drive ArrayList to store values in.
        $NetworkDrives = @()
    }
    Process{
        Write-Verbose "In Process Block: Get-NetworkDriveList"

        if ($MSSIDrives) {
            #Format $NetworkDrives into a PowerShell Array. 
            $NetworkDrives = $MSSIDrives.Replace('[','').Replace(']','').Replace('"','').Split(',')
        }
        
    }
    End{
        Write-Verbose "In End Block: Get-NetworkDriveList"
        return $NetworkDrives
    }
}

#Process MSSI Distribution Lists aequired in to a Readable Array to add to relevant Distribution Lists upon User Creation
function Get-MSSIDistList {
    param (
        [Parameter(Mandatory=$true)][AllowEmptyString()][string[]]$MSSIDistLists
    )
    Begin {
        Write-Verbose "In Begin Block: Get-DistList"
        #Generate empty Distribution ArrayLists to store relevant values in. Also an empty DistributionLists HashTable 
        $MSSIList = @()
        $DistributionLists = @{} #Look to implement this for combined functions during refactor.
    }
    Process{
        Write-Verbose "In Process Block: Get-DistList"
        
        if ($MSSIDistLists) {
            #Format $MSSIList into a PowerShell Array.
            $MSSIList = $MSSIDistLists.Replace('[','').Replace(']','').Replace('"','').Split(',')
        }
    
        $MSSIList += "All Staff (default group)"
    }
    End{
        Write-Verbose "In End Block: Get-DistList"
        return $MSSIList
    }
}

#Process MSSA Distribution Lists aequired in to a Readable Array to add to relevant Distribution Lists upon User Creation
function Get-MSSADistList {
    param (
        [Parameter(Mandatory=$true)][AllowEmptyString()][string[]]$MSSADistLists
    )
    Begin {
        Write-Verbose "In Begin Block: Get-DistList"
        #Generate empty Distribution ArrayLists to store relevant values in. Also an empty DistributionLists HashTable 
        $MSSAList = @()
        $DistributionLists = @{} #Look to implement this for combined functions during refactor.
    }
    Process{
        Write-Verbose "In Process Block: Get-DistList"
        
        if ($MSSADistLists) {
            #Format $MSSIList into a PowerShell Array.
            $MSSAList = $MSSADistLists.Replace('[','').Replace(']','').Replace('"','').Split(',')
        }
    
        $MSSAList += "MSSA All Staff (default group)"
    }
    End{
        Write-Verbose "In End Block: Get-DistList"
        return $MSSAList
    }
}

#Generate $ExclaimSignature variable to determine which Exclaimer Signature the New User
function Get-ExclaimerSignature {
    param (
        [Parameter(Mandatory=$true)][AllowEmptyString()][string[]]$Location
    )
    Begin {
        Write-Verbose "In Begin Block: Get-ExclaimerSignature"
        $ExclaimerSignature = ""
        $MSSA_Standard = ($Location.StartsWith('House') -And ($Casual -eq 'No'))
        $MSSA_Casual = ($Location.StartsWith('House') -And ($Casual -eq 'Yes'))
    }
    Process{
        Write-Verbose "In Process Block: Get-ExclaimerSignature"
        if ($MSSA_Standard) {
            $ExclaimerSignature = "MSSA"
        } elseif ($MSSA_Casual) {
            $ExclaimerSignature = "MSSA - Casual"
        } else {
            $ExclaimerSignature = $Location
        }
    }
    End{
        Write-Verbose "In End Block: Get-ExclaimerSignature"
        return $ExclaimerSignature
    }
}

function Get-MOSAudienceGroup {
    param (
        [Parameter(Mandatory=$false)][AllowEmptyString()][string[]]$UserType,
        [Parameter(Mandatory=$false)][switch]$Both
    )
    Begin {
        Write-Verbose "In Begin Block: Get-MOSAudienceGroup"
        $MOSSecurityGroup = @()
    }
    Process{
        Write-Verbose "In Process Block: Get-MOSAudienceGroup"

        #If Both is flagged add both groups, else only add relevant security group based on $UserType. 
        if ($Both.IsPresent) {
            $MOSSecurityGroup += "SEC_MOS_"
            $MOSSecurityGroup += "SEC_MOS_MSSA_SECONDED"
        } elseif ($UserType -eq "MSSI") {
            $MOSSecurityGroup += "SEC_MOS_"
        } elseif ($UserType -eq "MSSA") {
            $MOSSecurityGroup += "SEC_MOS_MSSA_SECONDED"
        }
    }
    End{
        Write-Verbose "In End Block: Get-MOSAudienceGroup"
        return $MOSSecurityGroup
    }
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
        } elseif (($key -eq "DeskTelephoneNumber") -or ($key -eq "MobileNumber")) {
            #If the new value does not match the '[\W\D\s]' Regex, remove from the Hashtable. 
            if ($value -NotMatch '[\W\D\s]') {
                $SanitiseCheck.psobject.properties.remove($key)
            }
        } elseif ($key -eq "JobTitle") {
            #If the new value does not match the '[^A-Za-z_ ]' Regex, remove from the Hashtable. 
            if ($value -NotMatch '[^A-Za-z_ ]') {
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
        } elseif (($key -eq "DeskTelephoneNumber") -or ($key -eq "MobileNumber")) {
            #Set the 'New' value as the sanitised string with the [\W\D\s] regex targeting
            $newValue = $($oldValue -replace '[\W\D\s]','')
        } elseif ($key -eq "JobTitle") {
            #Set the 'New' value as the sanitised string with the [^A-Za-z_ ] regex targeting
            $newValue = $($oldValue -replace '[^A-Za-z_ ]','').Trim()
        }
    
        #Add the new values above under a 'New' key alongside the Old values. 
        $SanitiseChecked.$key.Add("New",$newValue)
    }

    return $SanitiseChecked
}

#Create new AD User using inputs provided from Form/SPO List. 
function New-KXCADUser {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param (
        [Parameter(Mandatory=$true)][string]$FirstName,
        [Parameter(Mandatory=$true)][string]$LastName,
        [Parameter(Mandatory=$true)][string]$UserPrincipalName,
        [Parameter(Mandatory=$true)][string]$sAMAccountName,
        [Parameter(Mandatory=$true)][string]$Title,
        [Parameter(Mandatory=$true)][string]$TargetOU,
        [Parameter(Mandatory=$false)][string]$Manager,
        [Parameter(Mandatory=$true)][DateTime]$ContractEndDate,
        [Parameter(Mandatory=$false)][AllowEmptyString()][string]$OfficePhone,
        [Parameter(Mandatory=$false)][AllowEmptyString()][string]$MobilePhone,
        #Address Variables
        [Parameter(Mandatory=$true)][string]$Office,
        [Parameter(Mandatory=$true)][string]$Company,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$StreetAddress,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$City,
        [Parameter(Mandatory=$true)][string]$State,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$PostCode,
        #[Parameter(Mandatory=$true)][string]$AddressBook,
        [Parameter(Mandatory=$true)][int]$PasswordLength = 12
    )
    
    #Generate a password
    $Password = [System.Web.Security.Membership]::GeneratePassword($PasswordLength,2) #This will need to be tested on PROD to ensure [System.Web.Security.Membership] can be used
    
    #Construct the user HT
    $ADUserHt = @{
        GivenName = $FirstName
        SurName = $LastName
        ChangePasswordAtLogon = $true
        AccountExpirationDate = $ContractEndDate
        EmailAddress = $UserPrincipalName
        UserPrincipalName = $UserPrincipalName
        sAMAccountName = $sAMAccountName
        Title = $Title
        Name = "$FirstName $LastName ($sAMAccountName)"
        Displayname = "$FirstName $LastName"
        Path = $TargetOU
        AccountPassword = (ConvertTo-SecureString -String $Password -AsPlainText -Force)
        Enabled = $true
        OfficePhone = $OfficePhone
        MobilePhone = $MobilePhone
        Office = $Office
        Company = $Company
        State = $State
        StreetAddress = $StreetAddress
        PostalCode = $PostCode
        City = $City
        OtherAttribute = @{proxyAddresses = "SMTP:$UserPrincipalName"}
        #Manager = $Manager
        HomePage = "https://www.korthcore.com"
    }
    try {
        #Create the user and return a custom object
        New-ADUser @ADUserHt -ErrorAction Stop
        Write-Verbose "Successfully created the user $($ADUserHt.Name)"
        [pscustomobject] @{
            sAMAccountName = $ADUserHt.sAMAccountName
            UserPrincipalName = $ADUserHt.UserPrincipalName
            Password = $Password
        }
    } catch {
        Write-Error "Error creating the user $($ADUserHt.Name) `r`n$_"
    }
}

#Test AD User Exists
function Test-ADUser {
    param(
      [Parameter(Mandatory = $true)]
      [String] $sAMAccountName
    )
    $null -ne ([ADSISearcher] "(sAMAccountName=$sAMAccountName)").FindOne()
}
#end functions

#Connect to SharePoint Online
Try {
    #Connect to PnP Online
    Connect-PnPOnline -Url $SPOUrl -Credentials $Cred -Verbose:$true
    $UserData = (Get-PnPListItem -List $SPOList -Fields $SPListItemFields)
}
catch {
    Write-Verbose "Error: $($_.Exception.Message)"
}

# Loop through each User from $UserData and process User Creation 
ForEach ($NewUser in $UserData) {
    #Grab List ID and Status 
    $ListItem = $NewUser["ID"]
    $Status = $NewUser["RequestStatus"]

    If ($Status -eq "Approved") {
        Write-Verbose "Processing list item $Firstname $LastName with ID=$ListItem"
  
        #Store Static variables for future reference.
        $PasswordLength = "12"
        $UPNSuffix = 'korthcore.com'
        $Company = "Korthcore"
        $State = "Queensland"
        $AddressBook = "ALL"

        #Store Relevant attributes as Variables for the New User
        $UserType = $NewUser["NewUserMSSIorMSSA"]
        $Casual = $NewUser["NewUserCasual"]
        $ContractEndDate = $NewUser["ContractEndDate"]
        $O365LicenseType = $NewUser["O365LicenseType"]
        $TargetOU = "OU=Users,OU=$($UserType),OU=Company,DC=korthcore,DC=com,DC=au"
        $FirstName = $NewUser["FirstName"]
        $LastName = $NewUser["LastName"]
        $Title = $NewUser["JobTitle"]
        $OfficePhone = $NewUser["DeskTelephoneNumber"]
        $MobilePhone = $NewUser["MobileNumber"]

        #Create an ordered Hashtable to store inputs requiring sanitisation and linking them against the $SPListItemFields Key.
        $SanitiseCheck = [ordered]@{
            "FirstName" = @{Old = $FirstName}
            "LastName" = @{Old = $LastName}
            "JobTitle" = @{Old = $Title}
            "DeskTelephoneNumber" = @{Old = $OfficePhone}
            "MobileNumber" = @{Old = $MobilePhone}
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
            if ($null -ne $SanitiseChecked.JobTitle.New) {
                $Title = $SanitiseChecked.JobTitle.New
            }
            if ($null -ne $SanitiseChecked.DeskTelephoneNumber.New) {
                $OfficePhone = $SanitiseChecked.DeskTelephoneNumber.New
            }
            if ($null -ne $SanitiseChecked.MobileNumber.New) {
                $MobilePhone = $SanitiseChecked.MobileNumber.New
            }
        }

        #Manager Details - This is currently the person submitting the form, this will need to be updated appropriately where necessary on the Form. 
        #$Manager = $NewUser["SubmitterName"]
        #$ManagerUPN = $NewUser["SubmitterEmail"]
    
        #Adress Details
        $UserLocation = $NewUser["NewUserPrimaryLocation"]
        [hashtable] $UserOffice = @{}

        #Applications
        $ApplicationsRequired = $NewUser["ApplicationsRequired"]

        #Network Drives
        $MSSIDrives = $NewUser["MSSINetworkDrives"]

        #DistributionLists
        $MSSIDistLists = $NewUser["MSSIDistributionList"]
        $MSSADistLists = $NewUser["MSSADistributionList"]

        #MOS Audience Group required. 
        $MOSGroup = $NewUser["MOSAudienceGroup"]

        #Printer PIN set as random 5 digit character. 
        $PrinterPIN = Get-Random -Minimum 0 -Maximum 99999
        
        try {
            #Below will try to process and create based upon the above details. 
            $sAMAccountName = New-sAMAccountName -FirstName $Firstname -LastName $LastName
            $UPNandMail = New-UPNandMail -FirstName $Firstname -LastName $LastName -UPNSuffix $UPNSuffix
            #$Manager = Get-DNFromUPN -UserPrincipalName $ManagerUPN
            #$AddressBook = Get-UserAddressList -AddressBook $AddressBook #Uncomment if this is required later, currently ALL is default. 
            $UserOffice = Get-UserOfficeDetails -UserLocation $UserLocation

            if ($null -eq $ContractEndDate) {
                $timestamp = (Get-Date).AddDays(90).ToString('yyyy-MM-ddTHH:mm:ss')
                $datetime  = ([DateTime]$timestamp).ToUniversalTime()
                #Convert from UTC Time to the local Timezone
                $ContractEndDate = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId($datetime, 'AUS Eastern Standard Time')
            }

            #Create the user in Active Directory
            $NewAdUserHt = @{
                FirstName = $Firstname
                LastName = $LastName
                OfficePhone = $OfficePhone
                MobilePhone = $MobilePhone
                ContractEndDate = $ContractEndDate
                #Manager = $Manager
                sAMAccountName = $sAMAccountName
                UserPrincipalName = $UPNandMail
                Title = $Title
                TargetOU = $TargetOU
                PasswordLength = $PasswordLength
                #User Location Details
                Office = $UserLocation
                Company = $Company
                State = $State
                StreetAddress = $UserOffice.StreetAddress
                PostCode = $UserOffice.PostCode
                City = $UserOffice.City
            }

            $ADUser = New-KXCADUser @NewAdUserHt -ErrorAction Stop

            #Verify User Exists before modifying any additional items.
            $TestUser = Test-ADUser -sAMAccountName $sAMAccountName

            if ($TestUser -eq $true) {
                Write-Verbose "Created the AD user $sAMAccountName with UPN $UPNandMail in $TargetOU"
            } else {
                Write-Verbose "The user $sAMAccountName failed to be created."
            }

            #Store newly created User ass $NewADUserObject Object variable for further account actions. 
            $ADUserObject = Get-ADUSer -Identity $sAMAccountName

            #Update relevant Country Codes (easier on a Set rather than New) 
            Set-ADUser -Identity $ADUserObject -Replace @{c="AU";co="Australia";countrycode=36} -ErrorAction Stop

            #Set Home Directory Mount on AD Object, as per Documentation this is configured as "\\MSS-FS01\Redirected Folders$\%username%\My Documents"  
            Set-ADUser -Identity $ADUserObject -Replace @{homeDirectory="\\MSS-FS01\Redirected Folders$\$sAMAccountName\My Documents";homeDrive="H:"} -ErrorAction Stop

            #Set User Licences (O365 F1 and E3) 
            #if ($O365LicenseType -eq "E3") {
            #    Set-ADUser -Identity $ADUserObject -Add @{"extensionattribute14"="1"}
            #} elseif ($O365LicenseType -eq "F1") {
            #    Set-ADUser -Identity $ADUserObject -Add @{"extensionattribute13"="1"}
            #}
            
            #Add AddressBook value to extensionAttribute7
            # Currently this will fail on test as there are no Exchange Attributes (extensionAttribute1-15) on the Test Server due to no Exchange Server to provide them. 
            #Set-ADUser -Identity $ADUserObject -Add @{"extensionattribute7"="$AddressBook"}

            #Add PrinterPin value to extensionAttribute10
            #if ($UserType -eq "MSSI") {
            #    Set-ADUser -Identity $ADUserObject -Add @{"extensionattribute10"="$PrinterPIN"}
            #}

            #Add MOS Audience Group value based on $UserType and if $MOSGroup is set to Both required or not. Store in an Array
            if ($MOSGroup -eq "Yes") {
                $MOSSecurityGroups = Get-MOSAudienceGroup -Both
            } else {
                $MOSSecurityGroups = Get-MOSAudienceGroup -UserType $UserType
            }

            #For each item in the Array, add the relevant Security Group to the User Object. 
            foreach ($SecGroup in $MOSSecurityGroups) {
                Get-ADGroup -Identity $SecGroup | Add-ADGroupMember -Members $ADUserObject -ErrorAction Stop
            }

            #Add user to Requested Application Security Groups
            if ($ApplicationsRequired) {
                $ApplicationList = Get-ApplicationList -ApplicationsRequired $ApplicationsRequired -UserType $UserType
            
                foreach ($App in $ApplicationList) {
                    $ApplicationGroup = $AppTable.Item($App)
                
                    if ($ApplicationGroup) {
                        #Get the Security Group and add the User as a Member of this Security Group
                        Get-ADGroup -Identity $ApplicationGroup | Add-ADGroupMember -Members $ADUserObject -ErrorAction Stop
                    } else {
                        Write-Verbose "There is no $App association in $ApplicationGroup"
                    }
                }
            }

            #Add User to requested MSSI Network Drive Security Groups if provided
            if ($MSSIDrives) {
                $NetworkDrives = Get-NetworkDriveList -MSSIDrives $MSSIDrives

                foreach ($NDrive in $NetworkDrives) {
                    $NetworkGroup = $NDriveTable.Item($NDrive)
                
                    if ($NetworkGroup) {
                        #Get the Security Group and add the User as a Member of this Security Group
                        Get-ADGroup -Identity $NetworkGroup | Add-ADGroupMember -Members $ADUserObject -ErrorAction Stop
                    } else { 
                        Write-Verbose "$NDrive failed to find a Drive Security Group match."    
                        break 
                    }
                }
            }

            #Add User to requested MSSI Distribution List Security Groups if provided. 
            if ($MSSIDistLists) {
                $MSSIDistributionGroups = Get-MSSIDistList -MSSIDistLists $MSSIDistLists
            
                foreach ($MailList in $MSSIDistributionGroups) {
                    $MSSIDistributionGroup = $MSSIDistTable.Item($MailList)

                    if ($MSSIDistributionGroup) {
                        #Get the Distribution Group and add the User as a Member of this Distribution Group
                        Get-ADGroup -Identity $MSSIDistributionGroup | Add-ADGroupMember -Members $ADUserObject -ErrorAction Stop
                    } else { 
                        Write-Verbose "No associated MSSI $MailList Distribution Group."    
                        break 
                    }
                }
            }

            #Add User to requested MSSA Distribution Groups if provided
            if ($MSSADistLists) {
                $MSSADistributionGroups = Get-MSSADistList -MSSADistLists $MSSADistLists
            
                foreach ($MailList in $MSSADistributionGroups) {
                    $MSSADistributionGroup = $MSSADistTable.Item($MailList)
                
                    if ($MSSADistributionGroup) {
                        #Get the Distribution Group and add the User as a Member of this Distribution Group
                        Get-ADGroup -Identity $MSSADistributionGroup | Add-ADGroupMember -Members $ADUserObject -ErrorAction Stop
                    } else { 
                        Write-Verbose "No associated MSSA $MailList Distribution Group."    
                        break 
                    }
                }
            }

            #Add Exclaimer Security Group for Email Signature
            $ExclaimerSignature = Get-ExclaimerSignature -Location $UserLocation
            $ExlaimerGroup = $SigTable.Item($ExclaimerSignature)

            if (!$ExlaimerGroup) {
                Write-Verbose "There are no entries for the Exclaimer Signature."
            } else {
                #Get the Distribution Group and add the User as a Member of this Distribution Group
                Get-ADGroup -Identity $ExlaimerGroup | Add-ADGroupMember -Members $ADUserObject -ErrorAction Stop
            }

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
        } catch {
            Write-Error $_
        }
    }
}

#Disconnect from SharePoint Online
Try {
    #Connect to PnP Online
    Disconnect-PnPOnline
}
catch {
    Write-Verbose "Error: $($_.Exception.Message)"
}