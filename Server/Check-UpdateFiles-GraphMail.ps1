<#
.SYNOPSIS
Checks an update folder and sends a Microsoft Graph alert when files are detected.

.DESCRIPTION
This script checks a local path for update files.
If no files are found, the script exits without further action.
If one or more files are detected, a high-priority email is sent including a file overview.

Authentication is performed using an Azure App Registration where credentials are stored in Windows Credential Manager:
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
Used as Credential Manager target.

.PARAMETER updatePath
Local path where update files are expected.

.PARAMETER fromEmail
Mailbox used to send the message via Microsoft Graph.

.PARAMETER toEmail
Recipient of the notification.

.NOTES
Requirements:
- PowerShell module: CredentialManager
- Microsoft Graph Application permission: Mail.Send (admin consent required)

Behavior:
- No files → exit 0 (no mail sent)
- Files detected → high importance email sent
- Error → exit 1

.EXAMPLE
.\Check-UpdateFiles.ps1 `
    -clientId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -updatePath "C:\Cevi\Vergunningen\AutoUpdater"
#>
param (
    [Parameter(Mandatory)]
    [string]$clientId,
    [Parameter(Mandatory)]
    [string]$updatePath,
    [string]$fromEmail  = "no-reply@contoso.com",
    [string]$toEmail    = "ict@contoso.com"
)

Import-Module CredentialManager -ErrorAction Stop

# =========================
# SECRET
# =========================

Write-Output "Load client secret"

$cred = Get-StoredCredential -Target $clientId

if (-not $cred) {
    Write-Output "Credential not found for clientId: $clientId"
    exit 1
}

if (-not $cred.Password) {
    Write-Output "Credential found but password empty"
    exit 1
}

if (-not $cred.UserName) {
    Write-Output "Credential found but tenantId (username) empty"
    exit 1
}

$tenantId = $cred.UserName

$clientSecret = [System.Net.NetworkCredential]::new("", $cred.Password).Password

if (-not $clientSecret) {
    Write-Output "Client secret conversion failed"
    exit 1
}

# =========================
# PATH
# =========================

if (-not (Test-Path $updatePath)) {
    Write-Output "Update path not found: $updatePath"
    exit 1
}

# =========================
# CHECK FILES
# =========================

Write-Output "Check update files"

$files = Get-ChildItem -Path $updatePath -File -ErrorAction Stop

if ($files.Count -eq 0) {
    Write-Output "No files -> exit"
    exit 0
}

Write-Output "$($files.Count) file(s) found -> sending mail"

# =========================
# TOKEN
# =========================

$tokenUri = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"

$tokenBody = @{
    grant_type    = "client_credentials"
    scope         = "https://graph.microsoft.com/.default"
    client_id     = $clientId
    client_secret = $clientSecret
}

$tokenResponse = Invoke-RestMethod -Method Post -Uri $tokenUri -Body $tokenBody -ErrorAction Stop

$token = $tokenResponse.access_token

if (-not $token) {
    Write-Output "Access token not received"
    exit 1
}

Write-Output "Token acquired"

$headers = @{
    Authorization = "Bearer $token"
    "Content-Type" = "application/json"
}

# =========================
# BUILD MAIL
# =========================

$tableStyle = "border-collapse:collapse;border:1px solid #b3d9ff;background:#ffffff;"
$thStyle    = "border:1px solid #b3d9ff;background:#e6f2fa;color:#0078d4;padding:6px;text-align:left;"
$tdStyle    = "border:1px solid #b3d9ff;padding:6px;"

$tableRows = ""

foreach ($file in $files) {
    $name = [System.Net.WebUtility]::HtmlEncode($file.Name)
    $date = $file.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")

    $tableRows += "<tr><td style='$tdStyle'>$name</td><td style='$tdStyle'>$date</td></tr>"
}

$reportDate = Get-Date -Format "dd/MM/yyyy HH:mm"

$emailContent = @"
<h2>Update bestanden gedetecteerd</h2>

<p><b>Server:</b> $env:COMPUTERNAME</p>
<p><b>Locatie:</b> $updatePath</p>
<p><b>Tijdstip:</b> $reportDate</p>

<p><b>$($files.Count) bestand(en) gevonden</b></p>

<table style='$tableStyle'>
<tr>
    <th style='$thStyle'>Bestand</th>
    <th style='$thStyle'>Laatst gewijzigd</th>
</tr>
$tableRows
</table>
"@

$body = @{
    message = @{
        subject    = "Cevi - Update bestanden gedetecteerd - actie vereist"
        importance = "high"
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

$uri = "https://graph.microsoft.com/v1.0/users/$fromEmail/sendMail"

Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $body -ErrorAction Stop

Write-Output "Mail sent"
exit 0
