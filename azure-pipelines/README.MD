# Opinionated CI/CD Pipelines

The pipelines in this repository follow opinionated best practices. They are documented here for reference and easier debugging. 

This structure is based upon *Azure DevOps Governance* as provided by *Julie Ng* (Microsoft Engineer) 
- [Azure DevOps Governance](https://github.com/Azure/devops-governance)
- [Julie Ng - GitHub](https://github.com/julie-ng)
- [Julie Ng - Website](https://julie.io/)
- [Julie Ng - YouTube](https://www.youtube.com/c/JulieNgTech)

## File Structure

```
├── azure-pipelines
    ├── README.md
    ├── production.yaml
    ├── dev.yaml
    ├── jobs
    │   ├── asset-pipeline.yaml
    │   ├── tests.yaml
    │   └── version.yaml
    ├── steps
    │   └── debug-vars.yaml
    └── vars
        ├── dev.yaml
        ├── global.yaml
        └── prod.yaml
```

## Templates and Variables

### Local Templates 

The jobs and steps are intended for local use only and thus do not require `parameters:` definitions at each job scope. Therefore any varable referenced in a job, e.g. `variables.isProduction` can be found at a higher scope. 

### Global Variables

Due to the sheer amount of variables set, the conditionals and global defaults are set in `vars/global.yaml`.

```yaml
# Global scope
trigger:
  - main
variables:
  - template: vars/global.yaml
```

## Triggers and Deployments

| Pipeline | Branch Triggers | Pull Request Triggers | Deployment |
|:--|:--|:--|:--|
| [`dev.yaml`](./dev.yaml) | &bull; `main`<br>&bull; `feat/*`<br>&bull; `fix/*` | `main` | Dev |
| [`production.yaml`](./production.yaml) | &bull; `production`  | (none) |  Production |

### Zero Trust Principle

Pull Requests only runs tests and does not build or deploy at all. The YAML pedanticly excludes forks, pull requests and scheduled runs. In this manner only `git merge` events, which requires human intervention will trigger deployments. This is configured using branch production configurations.

See [`vars/global.yaml`](./vars/global.yaml) for details:

```yaml
# Excerpt
variables:
  isFork:       ${{ eq(variables['System.PullRequest.IsFork'], 'True') }}
  isPR:         ${{ eq(variables['Build.Reason'], 'PullRequest') }}
  isScheduled:  ${{ eq(variables['Build.Reason'], 'Schedule') }}
  isTrustedCI:  ${{ and( eq(variables.isFork,'False'), eq(variables.isPR,'False'), eq(variables.isScheduled,'False') ) }}
```