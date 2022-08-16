# Azure Runbooks

- New-UserCreationRequest
- New-UserSuspensionRequest

## File Structure

```
├── runbooks
    ├── README.md
    ├── New-UserCreationRequest
    │   ├── New-UserCreationRequest.ps1
    └── New-UserSuspensionRequest
        └── New-UserSuspensionRequest.ps1
```

## Naming Conventions

Due to the way in which Azure Runbooks are deployed the *Folder Name* (which is also the name of the *Logic App*) containing the *PowerShell Script* must match (without the .ps1 extension). This ensures that the appropriate script is deployed to the appropriate Runbook. 

## New-UserCreationRequest

Additional Documentation to fill out here. 

## New-UserSuspensionRequest

Additional Documentation to fill out here. 