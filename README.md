# Intune Win32 PowerShell Script Installer Template

Templates for the [PowerShell script installer](https://learn.microsoft.com/en-us/intune/intune-service/apps/apps-win32-app-management#powershell-script-installer) feature in Microsoft Intune Win32 app management. Instead of specifying a command line, you can upload a PowerShell script as the installer. Supports MSI/EXE installation, file copy, and registry settings.

## Files

| File | Purpose |
|------|---------|
| `Intune-Win32-PowerShell-Script-Installer-Template-Install.ps1` | Installation script |
| `Intune-Win32-PowerShell-Script-Installer-Template-Uninstall.ps1` | Uninstallation script |

## Script Requirements

Per Microsoft documentation:
- Scripts are limited to **50 KB** in size
- Scripts run in the same context as the app installer (SYSTEM or user)
- Return codes determine installation success or failure
- Scripts must run silently without user interaction

## Quick Start

1. Copy the template scripts to your package folder
2. Edit the configuration section at the top of each script
3. Package with the [Microsoft Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool)
4. Upload to Intune as a Win32 app

## Configuration

Edit the variables at the top of each script.

### Install Script

```powershell
# App identity
$AppName = "Notepad++"

# Installer (MSI or EXE)
$InstallerFile = "npp.8.9.1.Installer.x64.msi"
$InstallerArgs = "/qn /norestart"

# File copy
$FilesToCopy = @(
    @{ Source = "imabdk-config.json"; Destination = "$env:APPDATA\Notepad++" }
    @{ Source = "license.lic"; Destination = "$env:ProgramFiles\Notepad++" }
)

# Registry additions
$RegistryAdditions = @(
    @{ Path = "HKLM:\SOFTWARE\imab.dk"; Name = "AppVersion"; Value = "1.0"; Type = "String" }
    @{ Path = "HKCU:\SOFTWARE\imab.dk"; Name = "UserSetting"; Value = 1; Type = "DWord" }
)
```

### Uninstall Script

```powershell
# App identity
$AppName = "Notepad++"

# Uninstaller (MSI or EXE)
$UninstallerFile = "npp.8.9.1.Installer.x64.msi"
$UninstallerArgs = "/qn /norestart"
# EXE example: $UninstallerFile = "$env:ProgramFiles\Notepad++\uninstall.exe"

# File removal
$FilesToRemove = @(
    "$env:APPDATA\Notepad++\imabdk-config.json"
    "$env:ProgramFiles\Notepad++\license.lic"
)

# Registry removal
$RegistryRemovals = @(
    @{ Path = "HKLM:\SOFTWARE\imab.dk"; Action = "DeleteKey" }
    @{ Path = "HKCU:\SOFTWARE\imab.dk"; Action = "DeleteKey" }
)
```

## Execution Context

The scripts detect whether they run as **SYSTEM** or as the **current user** and behave differently.

### SYSTEM Context (typical for Intune deployments)

- HKCU registry settings are applied to **all existing user profiles**
- File copy destinations under user profiles target **all users**
- Uses HKU registry hive with user SIDs
- Supports both AD (S-1-5-21-*) and Entra ID (S-1-12-1-*) accounts

### User Context

- HKCU registry settings apply to **current user only**
- File operations target **current user profile only**
- Permission checks prevent failures on protected paths

## Permission Handling

Scripts check for required permissions before attempting operations:

- HKLM registry paths require admin privileges
- Protected filesystem paths (Program Files, Windows, etc.) require elevation

## Logging

Logs are written to:
```
%ProgramData%\Microsoft\IntuneManagementExtension\Logs\<AppName>-Install.log
%ProgramData%\Microsoft\IntuneManagementExtension\Logs\<AppName>-Uninstall.log
```

## Version history

| Version | Changes |
|---------|---------|
| 1.3 | Added `$env:USERPROFILE` path translation, `$env:ProgramW6432` for admin detection, fixed non-user paths looping per profile |
| 1.2 | Added admin privilege detection, file copy/removal support, registry operations for all user profiles |
| 1.0 | Initial release |

## Notes

- Scripts work without admin rights but some operations require elevation
- Test in a non-production environment before deployment
