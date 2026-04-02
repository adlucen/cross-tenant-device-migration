# Cross-Tenant Device Migration — Sample

A PowerShell 7 snippet demonstrating how an Azure Automation runbook accepts a webhook payload from a device-side Win32 app, wipes the Windows device from the source Entra ID tenant, and imports it into the target tenant's Autopilot using the Microsoft Graph beta API.

## What it shows
- Parsing a webhook payload inside an Azure Automation runbook
- Certificate-based Graph authentication against two separate tenants
- Locating a managed device in source tenant Intune by device name + serial number
- Triggering a remote wipe via Graph
- Removing the device from source tenant Autopilot
- Importing the hardware hash into target tenant Autopilot (Graph beta)

## Part of a larger solution
This snippet is extracted from a full **cross-tenant migration platform** used to move Windows devices between Entra ID tenants with zero user friction. The complete solution includes an Azure Table Storage audit trail, device rename logic aligned to the target tenant's naming convention, failure notifications, and a Win32 app that users trigger from Company Portal to initiate their own migration.

## Stack
`PowerShell 7` · `Azure Automation` · `Microsoft Graph API` · `Entra ID` · `Microsoft Intune` · `Windows Autopilot` · `Azure Table Storage` · `Win32 App packaging` · `Webhook`
