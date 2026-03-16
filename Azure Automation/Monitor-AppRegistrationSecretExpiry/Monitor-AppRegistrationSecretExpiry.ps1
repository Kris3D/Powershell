<#
.SYNOPSIS
    Monitors client secret and certificate expiration dates across all App Registrations in the tenant.

.DESCRIPTION
    Authenticates via System Assigned Managed Identity.
    Fetches all App Registrations, checks their client secrets and certificates,
    calculates days until expiry and sends a color-coded HTML email report.

    Secrets and certificates are categorized as:
        Red    : Expired
        Yellow : Expiring within 30 days
        Green  : Healthy (more than 30 days remaining)

    When a secret has no display name, the fallback is: "App name (hint)"
    Email priority is set to High when expired or expiring items are detected.

    Required Graph API permissions on the Managed Identity:
        - Application.Read.All
        - Mail.Send

.NOTES
    Author      : Kris De Pril
    Version     : 1.4
    Date        : 16/03/2026
    Authentication  : System Assigned Managed Identity
    Runtime     : PowerShell 7.2 or higher (uses ?? null-coalescing operator)

.EXAMPLE
    Run as an Azure Automation Runbook with a System Assigned Managed Identity.
    Schedule daily at 08:00 AM or as needed.
#>

#region Authentication via Managed Identity

Connect-AzAccount -Identity | Out-Null

$tokenObj = Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com"
$token    = $tokenObj.Token

$Headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

Write-Output "Token retrieved. Expires: $($tokenObj.ExpiresOn)"

#endregion

#region Configuration

$fromEmail = "no-reply@contoso.com"
$toEmail   = "ict@contoso.com"
$today     = Get-Date

#endregion

#region Functions

function ConvertTo-HtmlEncoded([string]$text) {
    $text -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;'
}

function Get-StatusProperties([int]$daysLeft) {
    switch ($daysLeft) {
        { $_ -lt 0 } {
            return @{
                Status = "Expired"
                Color  = "#ffd6d6"
                Text   = "#c00000"
                Icon   = "<span style='color:#c00000;font-size:16px;'>&#9679;</span>"
            }
        }
        { $_ -le 30 } {
            return @{
                Status = "Expiring Soon"
                Color  = "#fff3cd"
                Text   = "#856404"
                Icon   = "<span style='color:#856404;font-size:16px;'>&#9679;</span>"
            }
        }
        default {
            return @{
                Status = "Healthy"
                Color  = "#d4edda"
                Text   = "#155724"
                Icon   = "<span style='color:#155724;font-size:16px;'>&#9679;</span>"
            }
        }
    }
}

#endregion

#region Fetch All App Registrations

Write-Output "Fetching App Registrations..."

$allApps    = @()
$currentUri = "https://graph.microsoft.com/v1.0/applications?`$select=id,displayName,appId,passwordCredentials,keyCredentials"

try {
    do {
        $response    = Invoke-RestMethod -Method GET -Uri $currentUri -Headers $Headers -ErrorAction Stop
        $allApps    += $response.value
        Write-Output "  Page retrieved. Total so far: $($allApps.Count)"
        $currentUri  = $response.'@odata.nextLink'
    } while ($currentUri)

    Write-Output "All apps retrieved. Total: $($allApps.Count)"
}
catch {
    Write-Output "Error fetching apps: $($_.ErrorDetails.Message ?? $_.Exception.Message)"
    exit 1
}

#endregion

#region Build Report Data

Write-Output "Processing secrets..."

$secretRows = @()

foreach ($app in $allApps) {
    if (-not $app.passwordCredentials -or $app.passwordCredentials.Count -eq 0) { continue }

    foreach ($secret in $app.passwordCredentials) {
        $expiryDate = [datetime]$secret.endDateTime
        $daysLeft   = ($expiryDate - $today).Days
        $props      = Get-StatusProperties $daysLeft

        $secretRows += [PSCustomObject]@{
            Icon       = $props.Icon
            AppName    = ConvertTo-HtmlEncoded ($app.displayName ?? "(no name)")
            AppId      = $app.appId
            Name       = ConvertTo-HtmlEncoded ($secret.displayName ?? "$($app.displayName) ($($secret.hint))")
            ExpiryDate = $expiryDate.ToString("dd/MM/yyyy")
            DaysLeft   = $daysLeft
            Status     = $props.Status
            RowColor   = $props.Color
            TextColor  = $props.Text
        }
    }
}

$secretRows = $secretRows | Sort-Object DaysLeft

$secretsExpired  = ($secretRows | Where-Object { $_.Status -eq "Expired" }).Count
$secretsExpiring = ($secretRows | Where-Object { $_.Status -eq "Expiring Soon" }).Count
$secretsHealthy  = ($secretRows | Where-Object { $_.Status -eq "Healthy" }).Count

Write-Output "Total secrets     : $($secretRows.Count)"
Write-Output "Expired           : $secretsExpired"
Write-Output "Expiring soon     : $secretsExpiring"
Write-Output "Healthy           : $secretsHealthy"

Write-Output "Processing certificates..."

$certRows = @()

foreach ($app in $allApps) {
    if (-not $app.keyCredentials -or $app.keyCredentials.Count -eq 0) { continue }

    foreach ($cert in $app.keyCredentials) {
        $expiryDate = [datetime]$cert.endDateTime
        $daysLeft   = ($expiryDate - $today).Days
        $props      = Get-StatusProperties $daysLeft

        $certRows += [PSCustomObject]@{
            Icon       = $props.Icon
            AppName    = ConvertTo-HtmlEncoded ($app.displayName ?? "(no name)")
            AppId      = $app.appId
            Name       = ConvertTo-HtmlEncoded ($cert.displayName ?? "$($app.displayName) ($($cert.keyId))")
            ExpiryDate = $expiryDate.ToString("dd/MM/yyyy")
            DaysLeft   = $daysLeft
            Status     = $props.Status
            RowColor   = $props.Color
            TextColor  = $props.Text
        }
    }
}

$certRows = $certRows | Sort-Object DaysLeft

$certsExpired  = ($certRows | Where-Object { $_.Status -eq "Expired" }).Count
$certsExpiring = ($certRows | Where-Object { $_.Status -eq "Expiring Soon" }).Count
$certsHealthy  = ($certRows | Where-Object { $_.Status -eq "Healthy" }).Count

Write-Output "Total certificates: $($certRows.Count)"
Write-Output "Expired           : $certsExpired"
Write-Output "Expiring soon     : $certsExpiring"
Write-Output "Healthy           : $certsHealthy"

$urgent = ($secretsExpired -gt 0) -or ($secretsExpiring -gt 0) -or ($certsExpired -gt 0) -or ($certsExpiring -gt 0)

#endregion

#region Build HTML Email

$reportDate = Get-Date -Format "dd/MM/yyyy HH:mm"

function Build-TableRows($rows) {
    $html = ""
    foreach ($row in $rows) {
        $html += @"
<tr style="background:$($row.RowColor);color:$($row.TextColor);">
    <td style="padding:8px;border:1px solid #dee2e6;text-align:center;">$($row.Icon)</td>
    <td style="padding:8px;border:1px solid #dee2e6;font-weight:600;">$($row.AppName)</td>
    <td style="padding:8px;border:1px solid #dee2e6;font-family:monospace;font-size:12px;">$($row.AppId)</td>
    <td style="padding:8px;border:1px solid #dee2e6;">$($row.Name)</td>
    <td style="padding:8px;border:1px solid #dee2e6;">$($row.ExpiryDate)</td>
    <td style="padding:8px;border:1px solid #dee2e6;text-align:center;font-weight:700;">$($row.DaysLeft)</td>
    <td style="padding:8px;border:1px solid #dee2e6;font-weight:600;">$($row.Status)</td>
</tr>
"@
    }
    return $html
}

function Build-SummaryCounters($expired, $expiring, $healthy) {
    return @"
<table border="0" cellpadding="0" cellspacing="8" width="100%" style="margin-bottom:16px;">
  <tr>
    <td width="32%" style="background:#ffd6d6;border:1px solid #f5c6cb;padding:12px;text-align:center;border-radius:4px;">
      <div style="font-size:28px;font-weight:700;color:#c00000;">$expired</div>
      <div style="color:#c00000;font-weight:600;">&#9679; Expired</div>
    </td>
    <td width="4%"></td>
    <td width="32%" style="background:#fff3cd;border:1px solid #ffeeba;padding:12px;text-align:center;border-radius:4px;">
      <div style="font-size:28px;font-weight:700;color:#856404;">$expiring</div>
      <div style="color:#856404;font-weight:600;">&#9679; Expiring within 30 days</div>
    </td>
    <td width="4%"></td>
    <td width="32%" style="background:#d4edda;border:1px solid #c3e6cb;padding:12px;text-align:center;border-radius:4px;">
      <div style="font-size:28px;font-weight:700;color:#155724;">$healthy</div>
      <div style="color:#155724;font-weight:600;">&#9679; Healthy</div>
    </td>
  </tr>
</table>
"@
}

function Build-DetailTable($rows, $title) {
    $tableRows = Build-TableRows $rows
    return @"
<h2 style="color:#0078d4;font-size:16px;margin:24px 0 8px 0;">$title</h2>
<table border="0" cellpadding="0" cellspacing="0" width="100%">
  <thead>
    <tr style="background:#0078d4;color:#ffffff;">
      <th style="padding:10px;border:1px solid #0063b1;text-align:center;width:40px;"></th>
      <th style="padding:10px;border:1px solid #0063b1;text-align:left;">App name</th>
      <th style="padding:10px;border:1px solid #0063b1;text-align:left;">App ID</th>
      <th style="padding:10px;border:1px solid #0063b1;text-align:left;">Name</th>
      <th style="padding:10px;border:1px solid #0063b1;text-align:left;">Expiry date</th>
      <th style="padding:10px;border:1px solid #0063b1;text-align:center;">Days remaining</th>
      <th style="padding:10px;border:1px solid #0063b1;text-align:left;">Status</th>
    </tr>
  </thead>
  <tbody>
    $tableRows
  </tbody>
</table>
"@
}

$secretSummary  = Build-SummaryCounters $secretsExpired $secretsExpiring $secretsHealthy
$secretTable    = Build-DetailTable $secretRows "Client Secrets"
$certSummary    = Build-SummaryCounters $certsExpired $certsExpiring $certsHealthy
$certTable      = Build-DetailTable $certRows "Certificates"

$alertIcon  = if ($urgent) { "&#9888;" } else { "&#10003;" }
$alertColor = if ($urgent) { "#856404" } else { "#155724" }
$alertBg    = if ($urgent) { "#fff3cd" } else { "#d4edda" }
$alertText  = if ($urgent) { "Action required" } else { "All clear" }

$subject = if ($urgent) {
    "[ACTION REQUIRED] App Registration Secrets & Certificates - $reportDate"
} else {
    "[OK] App Registration Secrets & Certificates - $reportDate"
}

$emailContent = @"
<html>
<body style="font-family:Arial,sans-serif;color:#333;max-width:960px;margin:0 auto;">

  <!-- HEADER -->
  <table border="0" cellpadding="12" cellspacing="0" width="100%"
         style="background:#e6f2fa;border:1px solid #b3d9ff;margin-bottom:16px;">
    <tr>
      <td>
        <h1 style="color:#0078d4;font-size:20px;margin:0 0 6px 0;">
          App Registration Secret &amp; Certificate Expiry Report
        </h1>
        <p style="margin:4px 0;"><strong>Date &amp; Time:</strong> $reportDate</p>
        <p style="margin:4px 0;">Overview of all client secrets and certificates of App Registrations in the tenant.</p>
      </td>
      <td style="text-align:right;vertical-align:middle;">
        <span style="background:$alertBg;color:$alertColor;border:1px solid $alertColor;
                     padding:8px 16px;border-radius:4px;font-weight:700;font-size:14px;">
          $alertIcon $alertText
        </span>
      </td>
    </tr>
  </table>

  <!-- SECRETS -->
  <h2 style="color:#0078d4;font-size:16px;margin:0 0 8px 0;">Client Secrets</h2>
  $secretSummary
  $secretTable

  <!-- CERTIFICATES -->
  <h2 style="color:#0078d4;font-size:16px;margin:24px 0 8px 0;">Certificates</h2>
  $certSummary
  $certTable

</body>
</html>
"@

#endregion

#region Send Email

$messageBody = @{
    message = @{
        subject    = $subject
        importance = if ($urgent) { "high" } else { "normal" }
        body       = @{
            contentType = "HTML"
            content     = $emailContent
        }
        from         = @{ emailAddress = @{ address = $fromEmail } }
        toRecipients = @( @{ emailAddress = @{ address = $toEmail } } )
    }
    saveToSentItems = $true
} | ConvertTo-Json -Depth 10

try {
    Write-Output "Sending email..."
    Invoke-RestMethod -Method POST `
        -Uri     "https://graph.microsoft.com/v1.0/users/$fromEmail/sendMail" `
        -Headers $Headers `
        -Body    $messageBody
    Write-Output "Email sent successfully."
}
catch {
    Write-Output "Failed to send email."
    Write-Output ($_.ErrorDetails.Message ?? $_.Exception.Message)
}

#endregion

Write-Output "Script completed."
