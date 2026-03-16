# PowerShell

A collection of PowerShell scripts for Microsoft 365, Azure, Intune,
and on-premises environments.

## Structure

| Folder | Description |
|---|---|
| [`Azure Automation`](./Azure%20Automation/) | Runbook scripts for Azure Automation using Managed Identity |
| [`Remediation`](./Remediation/) | Remediation scripts for Intune or other platforms |
| [`PDQ`](./PDQ/) | PowerShell scanners and deployment scripts for PDQ |
| [`Server`](./Server/) | Scripts for use on on-premises servers |
| [`Client`](./Client/) | Scripts for use on client computers |

## General Requirements

- PowerShell 5.1 or higher
- PowerShell 7.2 or higher for Azure Automation scripts
- Appropriate permissions depending on the script and environment

## Authentication

| Context | Method |
|---|---|
| Azure Automation | System Assigned Managed Identity |
| On-premises / Client | Executing user or service account |
| Intune Remediation | SYSTEM account (limited permissions) |
| PDQ | Executing user or PDQ service account |

## Contributing

Each script lives in its own subfolder and includes:
- The `.ps1` script
- A `README.md` with description, requirements, and usage instructions
