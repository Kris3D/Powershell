<#
.SYNOPSIS
    Script stores a client secret in the Windows Credential Manager.

.DESCRIPTION
    This script writes a client secret to the local Windows Credential Manager
    as a Generic Credential and validates that it has been stored correctly.

.PARAMETER Target
    Unique name of the credential (recommended format: Azure-<ClientId>-Secret)

.PARAMETER Username
    Descriptive name for the credential (e.g. App Registration name)

.PARAMETER Password
    Client secret to store

.NOTES
    Requirements:
    - PowerShell module: CredentialManager
      Install with:
      Install-Module -Name CredentialManager -Scope AllUsers -Force

    Important:
    - Credential Manager is context-based (user / SYSTEM)
    - Scheduled Tasks running under SYSTEM require the credential to be stored under SYSTEM as well
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$Target,

    [Parameter(Mandatory = $true)]
    [string]$Username,

    [Parameter(Mandatory = $true)]
    [string]$Password
)

Import-Module CredentialManager

# =========================
# WRITE CREDENTIAL
# =========================
Write-Output "Credential wegschrijven: $Target"

$existing = Get-StoredCredential -Target $Target

if ($existing) {
    Write-Output "WARNING: Credential bestond al en wordt overschreven"
}

New-StoredCredential `
    -Target $Target `
    -Username $Username `
    -Password $Password `
    -Persist LocalMachine

# =========================
# VALIDATION
# =========================
Write-Output "Validatie gestart"

$cred = Get-StoredCredential -Target $Target

if (-not $cred) {
    throw "FAIL: Credential niet gevonden: $Target"
}

if ($cred.UserName -ne $Username) {
    throw "FAIL: Username mismatch (verwacht: $Username - gevonden: $($cred.UserName))"
}

if (-not $cred.Password) {
    throw "FAIL: Password is leeg of fout opgeslagen"
}

# optionele sanity check
if ($cred.Password.Length -lt 10) {
    throw "FAIL: Password lijkt ongeldig (te kort)"
}

Write-Output "OK: Credential succesvol opgeslagen en gevalideerd"
