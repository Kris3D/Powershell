# Monitor-AppRegistrationSecretExpiry

Monitors client secret expiration dates across all App Registrations in the tenant
and sends a color-coded HTML email report via Microsoft Graph API.

## What it does

- Fetches all App Registrations via Microsoft Graph API with pagination support
- Checks each client secret and calculates days until expiry
- Sends a color-coded HTML email report:
  - Red — Expired secrets
  - Yellow — Expiring within 30 days
  - Green — Healthy secrets (beyond 30 days)
- Sets email importance to **High** when expired or expiring secrets are detected
- Fallback secret name: `App name (hint)` when no display name is set
- Apps without secrets are skipped

## Authentication

Uses a **System Assigned Managed Identity** on the Azure Automation Account.
No App Registration, Key Vault, or client secret required.

## Required Graph API Permissions

Assign the following App Roles to the Managed Identity.
Use [`Grant-ManagedIdentityGraphPermissions.ps1`](../Grant-ManagedIdentityGraphPermissions.ps1)
to assign these roles via Azure Cloud Shell.

| Permission | Type | Purpose |
|---|---|---|
| `Application.Read.All` | Application | Read all App Registrations and their secrets |
| `Mail.Send` | Application | Send email report |

## Configuration

Edit the following variables at the top of the script:

| Variable | Description | Example |
|---|---|---|
| `$fromEmail` | Sender address (requires Mail.Send on the MI) | `no-reply@contoso.com` |
| `$toEmail` | Recipient address for the report | `ict@contoso.com` |

## Requirements

| Requirement | Details |
|---|---|
| Automation Account | System Assigned Managed Identity enabled |
| PowerShell runtime | **7.2 or higher** — script uses the `??` null-coalescing operator |
| Az module | `Az.Accounts` must be available in the Automation Account |

## Schedule

Recommended: daily at via an Azure Automation Schedule.

## Email Report

The email report contains:
- A status badge: **Action required** or **All clear**
- Three summary counters: Expired / Expiring Soon / Healthy
- A detailed table per secret with app name, app ID, secret name, expiry date,
  days remaining and status
- Email subject prefix `[ACTION REQUIRED]` or `[OK]` for easy mail rule filtering

## Notes

- The `??` null-coalescing operator requires PowerShell 7.2 or higher.
  This script will **not work** on PowerShell 5.1 runtimes.
- Apps without any secrets are skipped.
- If an app has multiple secrets, each secret is listed as a separate row.
- If a secret has no display name, the fallback is `App name (hint)` where
  hint is the first 3 characters of the secret — sufficient to identify it in the portal.
