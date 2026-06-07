<#
.SYNOPSIS
Synchronizes primary Teams phone numbers to on-prem Active Directory and always sends a notification email.

.DESCRIPTION
This script reads Teams user configurations from Microsoft Graph and retrieves the primary phone number
for Teams users with accountType = user.

The script compares those phone numbers with the on-prem Active Directory telephoneNumber attribute
for users within the configured OU search bases.

Business rule:
- AD telephoneNumber may only exist if the user has a primary Teams phone number.

Behavior:
- Only AD users within the configured OU search bases are processed
- Matching is done on userPrincipalName
- Only the primary Teams phone number is used
- AD telephoneNumber is set when a primary Teams number exists and differs
- AD telephoneNumber is cleared when no primary Teams number exists
- The email includes a summary of Teams users with phone numbers, scoped AD users, and Teams users not found in AD
- For Teams users not found in AD, the script checks whether the cloud user has onPremisesSyncEnabled
- An email is always sent
  -> When changes are made, a warning email with high importance is sent
  -> When no changes are made, an ok email with normal importance is sent

Authentication uses an Azure App Registration stored in Windows Credential Manager:
- Target   = ClientId
- Username = TenantId
- Password = Client Secret

Credentials must be created beforehand using the companion script:
- Set-WindowsCredential.ps1

Important:
- Credential Manager is context-based (user / SYSTEM)
- Scheduled Tasks running under SYSTEM require the credential to be created under SYSTEM

.PARAMETER clientId
Azure App Registration Client ID.
Used as the Credential Manager target.

.PARAMETER searchBases
Array of OU distinguished names where AD changes are allowed.

.PARAMETER fromEmail
Mailbox used to send the notification via Microsoft Graph.

.PARAMETER toEmail
Recipient of the notification.

.NOTES
Requirements:
- PowerShell module: CredentialManager
- PowerShell module: ActiveDirectory
- Microsoft Graph Application permissions:
  - TeamsUserConfiguration.Read.All
  - User.Read.All
  - Mail.Send

.EXAMPLE
.\Update-AdUserTelephoneNumberFromTeams.ps1 `
    -clientId "11111111-2222-3333-4444-555555555555" `
    -searchBases @(
        "OU=Users,OU=Finance,DC=contoso,DC=com",
        "OU=Users,OU=Sales,DC=contoso,DC=com"
    ) `
    -fromEmail "no-reply@contoso.com" `
    -toEmail "ict@contoso.com"
#>

param (
    [Parameter(Mandatory)]
    [string]$clientId = "11111111-2222-3333-4444-555555555555",

    [string[]]$searchBases = @(
        "OU=Users,OU=Municipality,DC=contoso,DC=com",
        "OU=Users,OU=Department,DC=contoso,DC=com"
    ),

    [string]$fromEmail = "no-reply@contoso.com",

    [string]$toEmail = "ict@contoso.com"
)

Import-Module CredentialManager -ErrorAction Stop
Import-Module ActiveDirectory -ErrorAction Stop

# =========================
# SECRET
# =========================
# Load the app registration secret from Windows Credential Manager.
# Expected structure:
# - Target   = ClientId
# - Username = TenantId
# - Password = Client Secret

Write-Output "`nLoad client secret"

$cred = Get-StoredCredential -Target $clientId

if (-not $cred) {
    Write-Output "Credential not found for clientId: $clientId"
    exit 1
}

if (-not $cred.UserName) {
    Write-Output "Credential found but tenantId (username) is empty"
    exit 1
}

if (-not $cred.Password) {
    Write-Output "Credential found but password is empty"
    exit 1
}

$tenantId = $cred.UserName
$clientSecret = [System.Net.NetworkCredential]::new("", $cred.Password).Password

if (-not $clientSecret) {
    Write-Output "Client secret conversion failed"
    exit 1
}

# =========================
# TOKEN
# =========================
# Request one Microsoft Graph app-only access token.
# The same token is used for:
# - Teams userConfigurations API
# - user lookup API
# - sendMail API

Write-Output "`nRequest Graph token"

$tokenBody = @{
    grant_type    = "client_credentials"
    scope         = "https://graph.microsoft.com/.default"
    client_id     = $clientId
    client_secret = $clientSecret
}

$tokenResponse = Invoke-RestMethod `
    -Method Post `
    -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
    -Body $tokenBody `
    -ErrorAction Stop

$token = $tokenResponse.access_token

if (-not $token) {
    Write-Output "Graph access token not received"
    exit 1
}

Write-Output "Token acquired"

$headers = @{
    Authorization  = "Bearer $token"
    "Content-Type" = "application/json"
}

# =========================
# GET AD USERS
# =========================
# Load all scoped AD users once.
#
# We keep track of:
# - adUsersByUpn     : fast lookup for comparison with Teams
# - adUsersWithPhone : only needed for the clear pass
# - adUserCount      : for reporting in the email
#
# ContainsKey() is used to avoid duplicate processing
# if search bases would ever overlap.

Write-Output "`nLoad AD users from scoped OUs"

$adUsersByUpn     = @{}
$adUsersWithPhone = [System.Collections.Generic.List[object]]::new()
$adUserCount      = 0

foreach ($searchBase in $searchBases) {
    Write-Output "Search OU: $searchBase"

    $ouUsers = Get-ADUser `
        -SearchBase $searchBase `
        -SearchScope Subtree `
        -LDAPFilter "(&(objectCategory=person)(objectClass=user))" `
        -Properties UserPrincipalName, telephoneNumber, DisplayName `
        -ErrorAction Stop

    foreach ($ouUser in $ouUsers) {
        if (-not $ouUser.UserPrincipalName) {
            continue
        }

        $upn = $ouUser.UserPrincipalName.ToLower()

        if (-not $adUsersByUpn.ContainsKey($upn)) {
            $adUsersByUpn[$upn] = $ouUser
            $adUserCount++

            if ($ouUser.telephoneNumber) {
                $adUsersWithPhone.Add($ouUser)
            }
        }
    }
}

Write-Output "$adUserCount AD user object(s) loaded"
Write-Output "$($adUsersWithPhone.Count) AD user object(s) with telephoneNumber loaded"

# =========================
# GET TEAMS USER CONFIG
# =========================
# Read Teams user configurations from Microsoft Graph.
#
# Only accountType = user is requested.
# Only the primary Teams phone number is used.
#
# During this pass, three things happen:
# 1. A lookup of Teams users with a primary number is built
# 2. AD is compared directly and set actions are executed when needed
# 3. Teams users not found in scoped AD are logged
#
# Teams users not found in AD are looked up again via /users/{id}
# so we can report whether they are:
# - cloud-only
# - synced from on-prem
# - previously synced

Write-Output "`nRetrieve Teams user configurations"

$teamsUserNumbers   = @{}
$notFoundTeamsUsers = [System.Collections.Generic.List[object]]::new()
$changes            = [System.Collections.Generic.List[object]]::new()

$teamsUsersUri = "https://graph.microsoft.com/v1.0/admin/teams/userConfigurations?`$select=id,userPrincipalName,accountType,telephoneNumbers&`$filter=accountType eq 'user'"

do {
    $teamsUsers = Invoke-RestMethod -Method Get -Uri $teamsUsersUri -Headers $headers -ErrorAction Stop

    foreach ($TeamsUser in $teamsUsers.value) {
        if (-not $TeamsUser.userPrincipalName) {
            continue
        }

        $upn = $TeamsUser.userPrincipalName.ToLower()
        $primaryNumber = $null

        # Keep only the primary Teams number.
        # Private or alternate numbers are ignored for this sync.
        if ($TeamsUser.telephoneNumbers) {
            foreach ($telephoneNumber in $TeamsUser.telephoneNumbers) {
                if ($telephoneNumber.assignmentCategory -eq "primary" -and $telephoneNumber.telephoneNumber) {
                    $primaryNumber = $telephoneNumber.telephoneNumber
                    break
                }
            }
        }

        if (-not $primaryNumber) {
            continue
        }

        $teamsUserNumbers[$upn] = $primaryNumber

        # If the user exists in scoped AD, compare and update when needed.
        if ($adUsersByUpn.ContainsKey($upn)) {
            $adUser = $adUsersByUpn[$upn]

            if ($adUser.telephoneNumber -ne $primaryNumber) {
                Set-ADUser `
                    -Identity $adUser.DistinguishedName `
                    -Replace @{ telephoneNumber = $primaryNumber } `
                    -ErrorAction Stop

                $changes.Add([PSCustomObject]@{
                    DisplayName       = $adUser.DisplayName
                    UserPrincipalName = $adUser.UserPrincipalName
                    Action            = "Set"
                    OldValue          = $adUser.telephoneNumber
                    NewValue          = $primaryNumber
                })

                Write-Output "telephoneNumber set for $($adUser.UserPrincipalName)"
            }
        }
        else {
            $cloudStatus = "Unknown"

            # Use the Entra user id from Teams configuration for reliable user lookup.
            if ($TeamsUser.id) {
                $graphUserUri = "https://graph.microsoft.com/v1.0/users/$($TeamsUser.id)?`$select=userPrincipalName,displayName,onPremisesSyncEnabled"

                try {
                    $graphUser = Invoke-RestMethod -Method Get -Uri $graphUserUri -Headers $headers -ErrorAction Stop

                    if ($null -eq $graphUser.onPremisesSyncEnabled) {
                        $cloudStatus = "Cloud-only (never synced from on-prem)"
                    }
                    elseif ($graphUser.onPremisesSyncEnabled -eq $true) {
                        $cloudStatus = "Synced from on-prem"
                    }
                    elseif ($graphUser.onPremisesSyncEnabled -eq $false) {
                        $cloudStatus = "Previously synced from on-prem, no longer synced"
                    }

                    $notFoundTeamsUsers.Add([PSCustomObject]@{
                        DisplayName       = $graphUser.displayName
                        UserPrincipalName = $graphUser.userPrincipalName
                        CloudStatus       = $cloudStatus
                    })
                }
                catch {
                    $notFoundTeamsUsers.Add([PSCustomObject]@{
                        DisplayName       = ""
                        UserPrincipalName = $TeamsUser.userPrincipalName
                        CloudStatus       = "Could not retrieve user details"
                    })
                }
            }
            else {
                $notFoundTeamsUsers.Add([PSCustomObject]@{
                    DisplayName       = ""
                    UserPrincipalName = $TeamsUser.userPrincipalName
                    CloudStatus       = "No Entra user id in Teams configuration"
                })
            }
        }
    }

    $teamsUsersUri = $teamsUsers.'@odata.nextLink'
}
while ($teamsUsersUri)

Write-Output "`n$($teamsUserNumbers.Count) Teams primary phone number(s) loaded"
Write-Output "$($notFoundTeamsUsers.Count) Teams user(s) not found in scoped AD"

# =========================
# CLEAR CHECK
# =========================
# Clear rule:
# AD telephoneNumber may only exist if the user has a primary Teams number.
#
# Therefore only AD users that currently have a telephoneNumber
# need to be checked. All other users are irrelevant for a clear action.

Write-Output "`nCheck which AD users should be cleared"

foreach ($adUser in $adUsersWithPhone) {
    $upn = $adUser.UserPrincipalName.ToLower()

    if (-not $teamsUserNumbers.ContainsKey($upn)) {
        Set-ADUser `
            -Identity $adUser.DistinguishedName `
            -Clear telephoneNumber `
            -ErrorAction Stop

        $changes.Add([PSCustomObject]@{
            DisplayName       = $adUser.DisplayName
            UserPrincipalName = $adUser.UserPrincipalName
            Action            = "Clear"
            OldValue          = $adUser.telephoneNumber
            NewValue          = ""
        })

        Write-Output "telephoneNumber cleared for $($adUser.UserPrincipalName)"
    }
}

if ($changes.Count -eq 0) {
    Write-Output "`nNo changes executed -> send informational email"
}
else {
    Write-Output "`n$($changes.Count) change(s) executed -> send email"
}

# =========================
# BUILD MAIL
# =========================
# Build the email body using the same basic style
# as your other reporting scripts.

Write-Output "`nBuild email content"

$tableStyle = "border-collapse:collapse;border:1px solid #b3d9ff;background:#ffffff;"
$thStyle    = "border:1px solid #b3d9ff;background:#e6f2fa;color:#0078d4;padding:6px;text-align:left;"
$tdStyle    = "border:1px solid #b3d9ff;padding:6px;"

$reportDate = Get-Date -Format "dd/MM/yyyy HH:mm"

$mailSubject = if ($changes.Count -gt 0) {
    "[Warning] Teams phone numbers synchronization to on-prem AD"
}
else {
    "[Ok] Teams phone numbers synchronization to on-prem AD"
}

$mailImportance = if ($changes.Count -gt 0) { "high" } else { "normal" }

$summaryRows = @(
    [PSCustomObject]@{ Metric = "Server";                      Value = $env:COMPUTERNAME }
    [PSCustomObject]@{ Metric = "Timestamp";                   Value = $reportDate }
    [PSCustomObject]@{ Metric = "Mode";                        Value = "Production" }
    [PSCustomObject]@{ Metric = "Teams users with phone";      Value = $teamsUserNumbers.Count }
    [PSCustomObject]@{ Metric = "Scoped AD users";             Value = $adUserCount }
    [PSCustomObject]@{ Metric = "Teams users not found in AD"; Value = $notFoundTeamsUsers.Count }
    [PSCustomObject]@{ Metric = "AD changes executed";         Value = $changes.Count }
)

$summaryHtml = ($summaryRows | ConvertTo-Html -Fragment -As Table) `
    -replace '<table>', "<table style='$tableStyle'>" `
    -replace '<th>', "<th style='$thStyle'>" `
    -replace '<td>', "<td style='$tdStyle'>"

if ($changes.Count -gt 0) {
    $detailHtml = ($changes | Select-Object DisplayName, UserPrincipalName, Action, OldValue, NewValue | ConvertTo-Html -Fragment -As Table) `
        -replace '<table>', "<table style='$tableStyle'>" `
        -replace '<th>', "<th style='$thStyle'>" `
        -replace '<td>', "<td style='$tdStyle'>"
}
else {
    $detailHtml = "<p>No AD changes were executed.</p>"
}

$notFoundHtml = ""

if ($notFoundTeamsUsers.Count -gt 0) {
    $notFoundHtml = ($notFoundTeamsUsers | Select-Object DisplayName, UserPrincipalName, CloudStatus | ConvertTo-Html -Fragment -As Table) `
        -replace '<table>', "<table style='$tableStyle'>" `
        -replace '<th>', "<th style='$thStyle'>" `
        -replace '<td>', "<td style='$tdStyle'>"
}
else {
    $notFoundHtml = "<p>No Teams users were found that are missing from scoped AD.</p>"
}

$emailContent = @"
<h2>Teams phone numbers synchronization to on-prem AD</h2>

<p><b>Server:</b> $env:COMPUTERNAME</p>
<p><b>Timestamp:</b> $reportDate</p>
<p><b>Mode:</b> Production - AD changes have been processed</p>

<h3>Summary</h3>
$summaryHtml

<h3>Teams users not found in scoped AD</h3>
$notFoundHtml

<h3>Executed changes</h3>
$detailHtml
"@

$body = @{
    message = @{
        subject    = $mailSubject
        importance = $mailImportance
        body       = @{
            contentType = "HTML"
            content     = $emailContent
        }
        toRecipients = @(
            @{
                emailAddress = @{
                    address = $toEmail
                }
            }
        )
    }
    saveToSentItems = $true
} | ConvertTo-Json -Depth 10

# =========================
# SEND MAIL
# =========================

Write-Output "`nSend email"

$mailUri = "https://graph.microsoft.com/v1.0/users/$fromEmail/sendMail"

Invoke-RestMethod `
    -Method Post `
    -Uri $mailUri `
    -Headers $headers `
    -Body $body `
    -ErrorAction Stop

Write-Output "Email sent"
exit 0
