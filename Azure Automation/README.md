# Azure Automation

PowerShell Runbook scripts for Azure Automation using System Assigned Managed Identity.

## Setup

Before running any runbook, assign the required Microsoft Graph API permissions
to the Managed Identity using the setup script Grant-ManagedIdentityGraphPermissions.

## Runbooks

Each runbook has its own subfolder containing the `.ps1` script and a `README.md`
with setup instructions, required permissions, and configuration details.

Browse the subfolders above for available runbooks.

## General Requirements

| Requirement | Details |
|---|---|
| Automation Account | System Assigned Managed Identity enabled |
| PowerShell runtime | 7.2 or higher |
| Az module | `Az.Accounts` must be available in the Automation Account |
