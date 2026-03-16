# Grant-ManagedIdentityGraphPermissions

One-time setup script that assigns Microsoft Graph API app roles to the
System Assigned Managed Identity of an Azure Automation Account.
Runs directly in Azure Cloud Shell — no additional modules required.

## What it does

- Fetches the Microsoft Graph service principal from the tenant
- Assigns the configured app roles to the Managed Identity
- Skips roles that are already assigned
- Verifies and lists all assigned roles at the end

## How to run

1. Open [Azure Cloud Shell](https://shell.azure.com) (PowerShell)
2. Update `$miObjectId` with the Object ID of your Managed Identity
   (Azure Portal → Automation Account → Identity → System assigned → Object ID)
3. Edit the `$roles` array if needed (see Configuration below)
4. Run the script

## Requirements

| Requirement | Details |
|---|---|
| Azure Cloud Shell | PowerShell mode |
| Role | Global Admin or Privileged Role Administrator |
| Module | None — uses Azure CLI + Invoke-RestMethod |

## Configuration

Edit the following variables at the top of the script:

| Variable | Description | Example |
|---|---|---|
| `$miObjectId` | Object ID of the Managed Identity | `1bbd43d9-5586-48d7-9f0f-0e1586968e14` |
| `$roles` | App roles to assign | See below |

To add or remove permissions, edit the `$roles` array:
```powershell
$roles = @(
    "DeviceManagementManagedDevices.ReadWrite.All",
    "User.Read.All",
    "Mail.Send",
    "Application.Read.All"
)
```

## Default permissions assigned

| Permission | Used by |
|---|---|
| `DeviceManagementManagedDevices.ReadWrite.All` | Update-IntuneDevicesPrimaryUser |
| `User.Read.All` | Update-IntuneDevicesPrimaryUser |
| `Mail.Send` | Update-IntuneDevicesPrimaryUser, Monitor-AppRegistrationSecretExpiry |
| `Application.Read.All` | Monitor-AppRegistrationSecretExpiry |

## Notes

- Already assigned roles are skipped without error.
- Run this script again after adding a new runbook that requires additional permissions —
  just add the new role to `$roles` and re-run.
- This script will **not work** outside of Azure Cloud Shell as it relies on
  the Azure CLI session for authentication.
