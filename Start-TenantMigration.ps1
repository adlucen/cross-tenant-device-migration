#Requires -Version 7.0
<#
.SYNOPSIS
    Sample: Cross-Tenant Device Migration via Webhook
.DESCRIPTION
    Demonstrates how an Azure Automation Runbook accepts a webhook payload
    from a device-side Win32 app, wipes the device from the source tenant,
    and imports it into the target tenant's Autopilot using the Graph beta API.

    NOTE: Illustrative snippet. Production runbook includes:
    - Azure Table Storage audit trail with per-step status updates
    - Device rename logic aligned to target tenant naming convention
    - Full error branching with failure notifications and rollback guards
    - Client-specific naming convention validation
    All tenant IDs, app credentials, and table connection strings are
    stored as encrypted Automation Account variables — never hardcoded.

.INPUTS (webhook JSON body)
    {
        "DeviceName":     "SOURCE-PC-001",
        "Username":       "user@source.com",
        "SerialNumber":   "PF3XXXXX",
        "HardwareHash":   "<4k base64 hash>"
    }

.REQUIREMENTS
    - Source tenant app reg: DeviceManagementManagedDevices.ReadWrite.All,
      WindowsAutopilotDeploymentProfile.ReadWrite.All
    - Target tenant app reg: DeviceManagementServiceConfig.ReadWrite.All
    - PowerShell 7.2 on Azure Automation (webhook-triggered runbook)
#>

param (
    [object]$WebhookData
)

# ── Parse webhook payload ──────────────────────────────────────────────────────
if (-not $WebhookData.RequestBody) { throw "No webhook payload received." }
$payload      = $WebhookData.RequestBody | ConvertFrom-Json
$deviceName   = $payload.DeviceName
$serialNumber = $payload.SerialNumber
$hardwareHash = $payload.HardwareHash

Write-Output "Migration triggered for device: $deviceName (S/N: $serialNumber)"

# ── Helper: get Graph token for a given tenant ────────────────────────────────
function Get-GraphToken {
    param([string]$TenantId, [string]$ClientId, [string]$CertThumb)
    $cert      = Get-Item "Cert:\LocalMachine\My\$CertThumb"
    $tokenBody = @{
        grant_type            = 'client_credentials'
        client_id             = $ClientId
        client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        client_assertion      = (New-GraphJwtAssertion -Certificate $cert -ClientId $ClientId -TenantId $TenantId)
        scope                 = 'https://graph.microsoft.com/.default'
    }
    (Invoke-RestMethod "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Method Post -Body $tokenBody).access_token
}

# ── Source tenant credentials (Automation variables) ──────────────────────────
$srcTenantId  = Get-AutomationVariable -Name 'SourceTenantId'
$srcClientId  = Get-AutomationVariable -Name 'SourceAppClientId'
$srcCertThumb = Get-AutomationVariable -Name 'SourceCertThumbprint'
$srcToken     = Get-GraphToken -TenantId $srcTenantId -ClientId $srcClientId -CertThumb $srcCertThumb
$srcHeaders   = @{ Authorization = "Bearer $srcToken"; 'Content-Type' = 'application/json' }

# ── Step 1: Locate the managed device in source tenant ────────────────────────
$deviceSearch = Invoke-RestMethod "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=deviceName eq '$deviceName'" -Headers $srcHeaders
$managedDevice = $deviceSearch.value | Where-Object { $_.serialNumber -eq $serialNumber } | Select-Object -First 1

if (-not $managedDevice) { throw "Device '$deviceName' not found in source tenant Intune." }
Write-Output "Found managed device ID: $($managedDevice.id)"

# ── Step 2: Trigger remote wipe on source tenant ──────────────────────────────
$wipeBody = @{ keepEnrollmentData = $false; keepUserData = $false } | ConvertTo-Json
Invoke-RestMethod "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($managedDevice.id)/wipe" `
    -Method Post -Headers $srcHeaders -Body $wipeBody | Out-Null
Write-Output "Wipe command sent to source device."

# ── Step 3: Remove from source Autopilot ─────────────────────────────────────
$apSearch  = Invoke-RestMethod "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=serialNumber eq '$serialNumber'" -Headers $srcHeaders
$apDevice  = $apSearch.value | Select-Object -First 1
if ($apDevice) {
    Invoke-RestMethod "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$($apDevice.id)" `
        -Method Delete -Headers $srcHeaders | Out-Null
    Write-Output "Removed from source Autopilot."
}

# ── Target tenant credentials ─────────────────────────────────────────────────
$tgtTenantId  = Get-AutomationVariable -Name 'TargetTenantId'
$tgtClientId  = Get-AutomationVariable -Name 'TargetAppClientId'
$tgtCertThumb = Get-AutomationVariable -Name 'TargetCertThumbprint'
$tgtToken     = Get-GraphToken -TenantId $tgtTenantId -ClientId $tgtClientId -CertThumb $tgtCertThumb
$tgtHeaders   = @{ Authorization = "Bearer $tgtToken"; 'Content-Type' = 'application/json' }

# ── Step 4: Import hardware hash into target Autopilot ────────────────────────
$importBody = @{
    '@odata.type'  = '#microsoft.graph.importedWindowsAutopilotDeviceIdentity'
    serialNumber   = $serialNumber
    hardwareIdentifier = $hardwareHash
    groupTag       = 'Migrated'
} | ConvertTo-Json

$importResult = Invoke-RestMethod "https://graph.microsoft.com/beta/deviceManagement/importedWindowsAutopilotDeviceIdentities" `
    -Method Post -Headers $tgtHeaders -Body $importBody
Write-Output "Autopilot import submitted. Import ID: $($importResult.id)"

Write-Output "Migration pipeline complete for $deviceName."
