<#
.SYNOPSIS
Stores an Azure App Registration client secret in Windows Credential Manager.

.DESCRIPTION
This script writes a client secret to the local Windows Credential Manager
as a Generic Credential and validates the stored values.

The credential is structured as follows:
- Target   = ClientId (Azure App Registration)
- Username = TenantId
- Password = Client secret

.PARAMETER clientId
Azure App Registration Client ID.
Used as Credential Manager target.

.PARAMETER tenantId
Azure AD Tenant ID.
Stored as the credential username.

.PARAMETER clientSecret
Azure App Registration client secret.
Stored as the credential password.

.NOTES
Requirements:
- PowerShell module: CredentialManager

Important:
- Credential Manager is context-based (user / SYSTEM)
- Scheduled Tasks running under SYSTEM require the credential to be created under SYSTEM

Behavior:
- Existing credential is overwritten
- Validation is performed after write
#>

param (
    [Parameter(Mandatory)]
    [string]$clientId,

    [Parameter(Mandatory)]
    [string]$tenantId,

    [Parameter(Mandatory)]
    [string]$clientSecret
)

Import-Module CredentialManager -ErrorAction Stop

# =========================
# WRITE CREDENTIAL
# =========================

Write-Output "Writing credential for clientId: $clientId"

$existing = Get-StoredCredential -Target $clientId

if ($existing) {
    Write-Output "Credential already exists -> overwrite"
}

New-StoredCredential `
    -Target $clientId `
    -Username $tenantId `
    -Password $clientSecret `
    -Persist LocalMachine

# =========================
# VALIDATION
# =========================

Write-Output "Validate stored credential"

$cred = Get-StoredCredential -Target $clientId

if (-not $cred) {
    Write-Output "Credential not found after write"
    exit 1
}

if ($cred.UserName -ne $tenantId) {
    Write-Output "TenantId mismatch (expected: $tenantId / found: $($cred.UserName))"
    exit 1
}

if (-not $cred.Password) {
    Write-Output "Stored password is empty"
    exit 1
}

Write-Output "Credential stored and validated successfully"
exit 0
