param (
    [Parameter(Mandatory=$false)][String]$AutomationAccountName,
    [Parameter(Mandatory=$false)][String]$ResourceGroupName,
    [Parameter(Mandatory=$false)][String]$ServicePrincipalName,
    [Parameter(Mandatory=$false)][String]$ServicePrincipalPass,
    [Parameter(Mandatory=$false)][String]$SubscriptionId,
    [Parameter(Mandatory=$false)][String]$TenantId,
    [Parameter(Mandatory=$false)][String]$RepoURL,
    [Parameter(Mandatory=$false)][String]$RepoAccessToken,
    [Parameter(Mandatory=$false)][String]$SourceControlType = "VsoGit", #VsoGit is Azure DevOps
    [Parameter(Mandatory=$false)][String]$SourceControlBranch = "main", #We only want to sync from Main for this. 
    [Parameter(Mandatory=$false)][Switch]$ConnectAzure,
    [Parameter(Mandatory=$false)][Switch]$DeployRunbooks
)

#Region
## Another Switch could be added here to clean up runbooks no longer in the list, ensuring each Pipeline not only updates appropriate Runbooks but also cleans up those no longer in use/required. 
## This will require planning and forethought into the relevant structure of AzureAutomation Accounts
#EndRegion

#Region - Connecting to Azure
if($ConnectAzure.IsPresent) {
    Write-Verbose -Message "Checking and Installing Azure Powershell Module"
    if (-not(Get-Module -Name Az.Accounts -ListAvailable)){
        Write-Warning "Module 'Az.Accounts' is missing or out of date. Installing module now."
        Install-Module -Name Az.Accounts, Az.Resources, Az.Automation -Scope CurrentUser -Force -AllowClobber
    }

    Write-Verbose -Message "Connecting to Azure"
    $ServicePrincipalPassword = ConvertTo-SecureString -AsPlainText -Force -String $ServicePrincipalPass
    $azureAppCred = New-Object System.Management.Automation.PSCredential ($ServicePrincipalName,$ServicePrincipalPassword)
    Connect-AzAccount -ServicePrincipal -Credential $azureAppCred -Tenant $tenantId -Subscription $SubscriptionId
}
#EndRegion

#Region - Deploying the Azure Runbooks
if($DeployRunbooks.IsPresent) {
    $Runbooks = (Get-ChildItem -Path "./runbooks").Name
    #Below is a Lookup, we may use this later, but for now a specified AutomationAccountName variable will be added instead. 
    #$AutomationAccountName = (Get-AzResource -ResourceGroupName $ResourceGroupName | Where-Object ResourceType -eq "Microsoft.Automation/automationAccounts").name
    $AutomationSourceControl = Get-AzAutomationSourceControl -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName
    # Adding the names of existing runbooks into an Array
    $AutomationSourceControlList = New-Object -TypeName System.Collections.ArrayList
    foreach($sourceControl in $AutomationSourceControl){ 
        $AutomationSourceControlList.Add($sourceControl.Name)
    }
    
    # foreach loop running through all the runbooks located in your repository
    foreach($Runbook in $Runbooks) {
        if($AutomationSourceControlList -contains $Runbook) {
            # If the runbook exists in Azure, then just run a sync on it
            try {
                Write-Verbose -Message "Runbook: $($Runbook) was found in Automation Source Control list. Updating source code now"
                Start-AzAutomationSourceControlSyncJob -SourceControlName $Runbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName
            }
            catch {
                Write-Error -Message "$($_)"
            }
        }
        else {
            # If the runbooks doesn't exist, the create a new source control job, and sync it to Azure
            Write-Verbose -Message "Runbook hasn't been connected with Azure Automation. Uploading source code for runbook"
            $FolderPath = "/runbooks/" + $Runbook + "/"
            try {
                New-AzAutomationSourceControl -ResourceGroupName $ResourceGroupName `
                    -AutomationAccountName $AutomationAccountName `
                    -Name $Runbook `
                    -RepoUrl $RepoURL `
                    -SourceType $SourceControlType `
                    -Branch $SourceControlBranch `
                    -FolderPath $FolderPath `
                    -AccessToken (ConvertTo-SecureString $RepoAccessToken -AsPlainText -Force)
                
                Start-AzAutomationSourceControlSyncJob -SourceControlName $Runbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName
    
            }
            catch {
                Write-Error -Message "$($_)"
            }
        }
    }
}