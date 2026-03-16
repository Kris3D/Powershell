# Azure Automation

PowerShell Runbook scripts for Azure Automation using System Assigned Managed Identity.

## Setup

Before running any runbook, assign the required Microsoft Graph API permissions
to the Managed Identity using the setup script below.

### Grant-ManagedIdentityGraphPermissions.ps1

A one-time setup script that assigns Microsoft Graph API app roles to the
System Assigned Managed Identity of the Azure Automation Account.

**How to run:**
1. Open [Azure Cloud Shell](https://shell.azure.com) (PowerShell)
2. Copy and run [`Grant-ManagedIdentityGraphPermissions.ps1`](./Grant-ManagedIdentityGraphPermissions.ps1)
3. The script will assign the roles and verify the result

**Requirements:**
- Global Admin or Privileged Role Administrator role
- Object ID of the Managed Identity
  (Azure Portal → Automation Account → Identity → System assigned → Object ID)

**Customization:**
To add or remove permissions, edit the `$roles` array at the top of the script:
```powershell
$roles = @(
    "DeviceManagementManagedDevices.ReadWrite.All",
    "User.Read.All",
    "Mail.Send",
    "Application.Read.All"
)
```

---

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
