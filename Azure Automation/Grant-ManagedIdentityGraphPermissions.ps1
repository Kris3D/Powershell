<#
.SYNOPSIS
    Grants Microsoft Graph API app role assignments to a System Assigned Managed Identity.

.DESCRIPTION
    Assigns the required Microsoft Graph application permissions to an Azure Automation
    Managed Identity using direct REST calls via the Microsoft Graph API.
    No Microsoft.Graph module required — runs directly in Azure Cloud Shell.

    The following app roles are assigned by default:
        - User.Read.All
        - Mail.Send
        - Application.Read.All
        - DeviceManagementManagedDevices.ReadWrite.All

    To add or remove permissions, edit the $roles array in the Configuration region.

.NOTES
    Author          : ICT Contoso
    Version         : 1.0
    Date            : 16/03/2026
    Runtime         : Azure Cloud Shell (PowerShell)
    Authentication  : Azure CLI (az login already handled by Cloud Shell)
    Prerequisite    : Global Admin or Privileged Role Administrator role required

.EXAMPLE
    Run directly in Azure Cloud Shell after updating $miObjectId.
    To add a permission: add the role name to the $roles array.
    To remove a permission: remove the role name from the $roles array.
#>

#region Configuration

# Object ID of the System Assigned Managed Identity
# Found in: Azure Portal -> Automation Account -> Identity -> System assigned -> Object ID
$miObjectId = "<ObjectId of your Managed Identity>"

# Microsoft Graph service principal app ID (always the same across all tenants)
$graphAppId = "00000003-0000-0000-c000-000000000000"

# App roles to assign
$roles = @(
    "User.Read.All",
    "Mail.Send",
    "Application.Read.All",
    "DeviceManagementManagedDevices.ReadWrite.All"
)

#endregion

#region Authentication via Azure CLI (Cloud Shell)

Write-Output "Retrieving access token via Azure CLI..."

$token   = (az account get-access-token --resource https://graph.microsoft.com | ConvertFrom-Json).accessToken
$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

Write-Output "Token retrieved."

#endregion

#region Fetch Microsoft Graph Service Principal

Write-Output "Fetching Microsoft Graph service principal..."

$graphSp = (Invoke-RestMethod `
    -Uri     "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$graphAppId'" `
    -Headers $headers).value[0]

Write-Output "Graph service principal found: $($graphSp.displayName)"

#endregion

#region Assign App Roles

Write-Output "Assigning app roles to Managed Identity ($miObjectId)..."

foreach ($roleName in $roles) {
    $role = $graphSp.appRoles | Where-Object { $_.value -eq $roleName }

    if (-not $role) {
        Write-Output "  [SKIP] Role not found: $roleName"
        continue
    }

    $body = @{
        principalId = $miObjectId
        resourceId  = $graphSp.id
        appRoleId   = $role.id
    } | ConvertTo-Json

    try {
        Invoke-RestMethod -Method POST `
            -Uri     "https://graph.microsoft.com/v1.0/servicePrincipals/$miObjectId/appRoleAssignments" `
            -Headers $headers `
            -Body    $body | Out-Null
        Write-Output "  [OK] $roleName"
    }
    catch {
        $err = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($err.error.code -eq "Permission_Duplicate") {
            Write-Output "  [SKIP] Already assigned: $roleName"
        }
        else {
            Write-Output "  [FAIL] $roleName : $($err.error.message ?? $_.Exception.Message)"
        }
    }
}

#endregion

#region Verify

Write-Output ""
Write-Output "Verifying assigned roles..."

$assigned = (Invoke-RestMethod `
    -Uri     "https://graph.microsoft.com/v1.0/servicePrincipals/$miObjectId/appRoleAssignments" `
    -Headers $headers).value

foreach ($assignment in $assigned) {
    $name = ($graphSp.appRoles | Where-Object { $_.id -eq $assignment.appRoleId }).value
    Write-Output "  [CONFIRMED] $name"
}

#endregion

Write-Output ""
Write-Output "Done."
