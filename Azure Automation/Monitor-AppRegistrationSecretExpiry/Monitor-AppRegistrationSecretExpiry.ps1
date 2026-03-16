<#
.SYNOPSIS
    Monitors client secret expiration dates across all App Registrations in the tenant.

.DESCRIPTION
    Authenticates via System Assigned Managed Identity.
    Fetches all App Registrations, checks their client secrets,
    calculates days until expiry and sends a color-coded HTML email report.

    Secrets are categorized as:
        Red    : Expired secrets
        Yellow : Expiring within 30 days
        Green  : Healthy (more than 30 days remaining)

    When a secret has no display name, the fallback is: "App name (hint)"
    Email priority is set to High when expired or expiring secrets are detected.

    Required Graph API permissions on the Managed Identity:
        - Application.Read.All
        - Mail.Send

.NOTES
    Author      : Kris De Pril
    Version     : 1.3
    Date        : 16/03/2026
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

#endregion

#region Fetch All App Registrations

Write-Output "Fetching App Registrations..."

$allApps    = @()
$currentUri = "https://graph.microsoft.com/v1.0/applications?`$select=id,displayName,appId,passwordCredentials"

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

$reportRows = @()

foreach ($app in $allApps) {
    if (-not $app.passwordCredentials -or $app.passwordCredentials.Count -eq 0) { continue }

    foreach ($secret in $app.passwordCredentials) {
        $expiryDate = [datetime]$secret.endDateTime
        $daysLeft   = ($expiryDate - $today).Days

        switch ($daysLeft) {
            { $_ -lt 0 } {
                $status = "Expired"
                $color  = "#ffd6d6"
                $text   = "#c00000"
                $icon   = "<span style='color:#c00000;font-size:16px;'>&#9679;</span>"
                break
            }
            { $_ -le 30 } {
                $status = "Expiring Soon"
                $color  = "#fff3cd"
                $text   = "#856404"
                $icon   = "<span style='color:#856404;font-size:16px;'>&#9679;</span>"
                break
            }
            default {
                $status = "Healthy"
                $color  = "#d4edda"
                $text   = "#155724"
                $icon   = "<span style='color:#155724;font-size:16px;'>&#9679;</span>"
            }
        }

        $reportRows += [PSCustomObject]@{
            Icon       = $icon
            AppName    = ConvertTo-HtmlEncoded ($app.displayName ?? "(no name)")
            AppId      = $app.appId
            SecretName = ConvertTo-HtmlEncoded ($secret.displayName ?? "$($app.displayName) ($($secret.hint))")
            ExpiryDate = $expiryDate.ToString("dd/MM/yyyy")
            DaysLeft   = $daysLeft
            Status     = $status
            RowColor   = $color
            TextColor  = $text
        }
    }
}

$reportRows = $reportRows | Sort-Object DaysLeft

$expired  = ($reportRows | Where-Object { $_.Status -eq "Expired" }).Count
$expiring = ($reportRows | Where-Object { $_.Status -eq "Expiring Soon" }).Count
$healthy  = ($reportRows | Where-Object { $_.Status -eq "Healthy" }).Count
$urgent   = ($expired -gt 0) -or ($expiring -gt 0)

Write-Output "Total secrets     : $($reportRows.Count)"
Write-Output "Expired           : $expired"
Write-Output "Expiring soon     : $expiring"
Write-Output "Healthy           : $healthy"

#endregion

#region Build HTML Email

$reportDate = Get-Date -Format "dd/MM/yyyy HH:mm"

$tableRows = ""
foreach ($row in $reportRows) {
    $tableRows += @"
<tr style="background:$($row.RowColor);color:$($row.TextColor);">
    <td style="padding:8px;border:1px solid #dee2e6;text-align:center;">$($row.Icon)</td>
    <td style="padding:8px;border:1px solid #dee2e6;font-weight:600;">$($row.AppName)</td>
    <td style="padding:8px;border:1px solid #dee2e6;font-family:monospace;font-size:12px;">$($row.AppId)</td>
    <td style="padding:8px;border:1px solid #dee2e6;">$($row.SecretName)</td>
    <td style="padding:8px;border:1px solid #dee2e6;">$($row.ExpiryDate)</td>
    <td style="padding:8px;border:1px solid #dee2e6;text-align:center;font-weight:700;">$($row.DaysLeft)</td>
    <td style="padding:8px;border:1px solid #dee2e6;font-weight:600;">$($row.Status)</td>
</tr>
"@
}

$alertIcon  = if ($urgent) { "&#9888;" } else { "&#10003;" }
$alertColor = if ($urgent) { "#856404" } else { "#155724" }
$alertBg    = if ($urgent) { "#fff3cd" } else { "#d4edda" }
$alertText  = if ($urgent) { "Action required" } else { "All clear" }

$subject = if ($urgent) {
    "[ACTION REQUIRED] App Registration Secrets - $reportDate"
} else {
    "[OK] App Registration Secrets - $reportDate"
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
          App Registration Secret Expiry Report
        </h1>
        <p style="margin:4px 0;"><strong>Date &amp; Time:</strong> $reportDate</p>
        <p style="margin:4px 0;">Overview of all client secrets of App Registrations in the tenant.</p>
      </td>
      <td style="text-align:right;vertical-align:middle;">
        <span style="background:$alertBg;color:$alertColor;border:1px solid $alertColor;
                     padding:8px 16px;border-radius:4px;font-weight:700;font-size:14px;">
          $alertIcon $alertText
        </span>
      </td>
    </tr>
  </table>

  <!-- SUMMARY COUNTERS -->
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

  <!-- DETAIL TABLE -->
  <table border="0" cellpadding="0" cellspacing="0" width="100%">
    <thead>
      <tr style="background:#0078d4;color:#ffffff;">
        <th style="padding:10px;border:1px solid #0063b1;text-align:center;width:40px;"></th>
        <th style="padding:10px;border:1px solid #0063b1;text-align:left;">App name</th>
        <th style="padding:10px;border:1px solid #0063b1;text-align:left;">App ID</th>
        <th style="padding:10px;border:1px solid #0063b1;text-align:left;">Secret name</th>
        <th style="padding:10px;border:1px solid #0063b1;text-align:left;">Expiry date</th>
        <th style="padding:10px;border:1px solid #0063b1;text-align:center;">Days remaining</th>
        <th style="padding:10px;border:1px solid #0063b1;text-align:left;">Status</th>
      </tr>
    </thead>
    <tbody>
      $tableRows
    </tbody>
  </table>

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
