# Melba-UserAutomation

User Onboarding, Offboarding Automation Tool. 

## Relevant Subsections

```
├── azure-pipelines
├── runbooks
├── scripts
└── tests (coming soon)
```

## Description

Let people know what your project can do specifically. Provide context and add a link to any reference visitors might be unfamiliar with. A list of Features or a Background subsection can also be added here. If there are alternatives to your project, this is a good place to list differentiating factors.

## Pipeline Status

| **Branch** | **Status** |
|:----------:|:-----------:|
| Main | [![Build Status]()]() |
| Dev | [![Build Status]()]() |

## Installation

This script should not need to be installed manually, however if there is a need to simply ensure you copy the contents of the relevant Runbook PowerShell files, which are located within `runbooks` and the associated *Logic App* folder, and manually paste this into the *Logic App* in Azure itself. 

However, this should not need to be done as any merge into the `main` branch will automatically kick off a deployment to automate this process. 

## Support

** Best support contact / method for this tool**

## Roadmap

- Continue to build out Testing
- Continue to build out CI/CD Pipeline
- Integrate Azure Key Vault for additional security
- Abstract functions from PowerShell Script(s) into a singular User-Automation (name pending) PowerShell Module

## Contributing

**Complete with contribution Standards and processes**

## Project status

In Development
