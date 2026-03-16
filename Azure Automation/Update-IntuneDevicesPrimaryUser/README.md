# Update-IntuneDevicesPrimaryUser

Automatically updates the primary user of Intune-managed Windows devices based on
the last logged-on user, using Microsoft Graph API via Managed Identity.

## What it does

- Fetches all company-owned Windows devices from Intune (Graph beta endpoint)
- Compares the current primary user with the last logged-on user
- Updates the primary user where a discrepancy is found
- Excludes configured users from being set as primary user
- Exports a full device report and a change report as CSV
- Sends an HTML summary email with both CSV files attached
- Sets email importance to **High** when primary user changes are detected

## Authentication

Uses a **System Assigned Managed Identity** on the Azure Automation Account.
No App Registration, Key Vault, or client secret required.

## Required Graph API Permissions

Assign the following App Roles to the Managed Identity.
Use [`Grant-ManagedIdentityGraphPermissions.ps1`](../Grant-ManagedIdentityGraphPermissions/Grant-ManagedIdentityGraphPermissions.ps1).
to assign these roles via Azure Cloud Shell.

| Permission | Type | Purpose |
|---|---|---|
| `DeviceManagementManagedDevices.ReadWrite.All` | Application | Read and update Intune managed devices |
| `User.Read.All` | Application | Read user details for last logged-on user |
| `Mail.Send` | Application | Send email report |

## Configuration

Edit the following variables in the Configuration region of the script:

| Variable | Description | Example |
|---|---|---|
| `$fromEmail` | Sender address (requires Mail.Send on the MI) | `no-reply@contoso.com` |
| `$toEmail` | Recipient address for the report | `ict@contoso.com` |
| `$UsersToExclude` | UPNs of users to exclude from being set as primary user | `@("user@contoso.com")` |

## Requirements

| Requirement | Details |
|---|---|
| Automation Account | System Assigned Managed Identity enabled |
| PowerShell runtime | **7.2 or higher** — script uses the `??` null-coalescing operator |
| Az module | `Az.Accounts` must be available in the Automation Account |

## Schedule

Recommended: daily at **08:00 PM (UTC+1 Brussels)** via an Azure Automation Schedule.

## Email Report

The email report contains:
- A summary table with total devices, differences found, successful and failed updates
- Two CSV attachments:
  - Full device report — all processed devices
  - Change report — only devices where the primary user was updated or failed to update
- Email subject includes the date and time of the run
- Email importance set to **High** when primary user changes are detected

## Notes

- The `??` null-coalescing operator requires PowerShell 7.2 or higher.
  This script will **not work** on PowerShell 5.1 runtimes.
- Only company-owned Windows devices are processed.
- The `usersLoggedOn` property is only available on the Graph **beta** endpoint.
- Users in `$UsersToExclude` are never set as primary user, even if they are
  the last logged-on user.

## Credits

Forked from [Shehab1Noaman - Community](https://github.com/Shehab1Noaman/Community/tree/main/Intune)

Changes from original:
- Replaced App Registration + Key Vault authentication with Managed Identity
- Replaced Microsoft.Graph module calls with pure REST via Invoke-RestMethod
- Unified error handling
- Removed redundant headers variable
- Fixed MorethanOneLogin parameter scope issue
- Email importance set to High when primary user changes are detected
