# Scripts

Scripts used within the Azure Pipeline. 

The scripts within are based upon the following sources : 
- [Deploy Azure Automation Runbooks with Source Control through Azure DevOps](https://scriptingchris.tech/2021/07/11/how-to-deploy-azure-automation-runbooks-with-source-control-through-azure-devops/)
- [Increase the success rate of Azure DevOps Pipelines using Pester](https://www.logitblog.com/increase-the-success-rate-of-azure-devops-pipelines-using-pester/)

## File Structure

```
├── scripts
    ├── README.md
    ├── DeployRunbooks.ps1
    ├── Pester.ps1
```

## Deploy Runbooks

The purpose of the *DeployRunbooks.ps1* script is to utilise the Azure DevOps Pipeline to automate the deployment of the code to the associated *Azure Runbook* when a merge is pushed into `main`. 

### Parameters

At current the Parameters are stored as Pipeline Variables and the script pulls these during the Pipeline run. Whilst this is satisfactory, down the line implemenation of Azure KeyVault to store these instead will be a better solution. 

The access is provided by an *Azure Service Principal*, however this should look to be replaced by an Azure Managed Identity instead, that is specifically tied to the resource for better security. 

### Process

The first check is whether or not the Pipeline can connect to Azure utilising the Service Principal credentials. If this is the case the script will then grab the name of all sub-folders within the top-level `runbooks` folder as an Array and loop through this to connect to the appropriate *Azure Runbook*, deploying the latest push to `main` via a `Start-AzAutomationSourceControlSyncJob` PowerShell command with the appropriate variables. 

## Pester

The purpose of the *Pester.ps1* script is to be used as the `Pester` engine rather than importing a plugin from the Azure DevOps Marketplace. Doing so allows more flexibility and better control over the testing implementation. 

### Process

When run during the Pipeline the `Pester` PowerShell Module will be installed and imported and will then process all `Pester` tests. Over time this is to be split out into individualised tests with only the PowerShell Module being installed and a full, rigourous, testing implemenation configured. 