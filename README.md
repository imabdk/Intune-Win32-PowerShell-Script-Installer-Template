# Intune Win32 PowerShell Script Installer Template

PowerShell templates for deploying Win32 applications through Microsoft Intune. Handles MSI/EXE installers, file copy operations, and registry settings.

## Files

| File | Purpose |
|------|---------|
| `Intune-Win32-PowerShell-Script-Installer-Template-Install.ps1` | Installation script |
| `Intune-Win32-PowerShell-Script-Installer-Template-Uninstall.ps1` | Uninstallation script |
| `Test-TemplateScripts.ps1` | Test suite for validation |

## Quick Start

1. Copy the template scripts to your package folder
2. Edit the configuration section at the top of each script
3. Package with the [Microsoft Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool)
4. Upload to Intune as a Win32 app

## Configuration

Edit the variables at the top of each script:

```powershell
$AppName    = "YourAppName"
$AppVersion = "1.0.0"
$LogFile    = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\$AppName.log"
```

### Installer Settings (Install script only)

```powershell
$InstallerFile = "Setup.msi"
$InstallerArgs = "/qn /norestart"
```

### File Copy Settings

```powershell
$FilesToCopy = @(
    @{ Source = "config.xml"; Destination = "$env:ProgramFiles\YourApp" }
)
```

### Registry Settings

```powershell
$RegistrySettings = @(
    @{ Path = "HKLM:\SOFTWARE\YourApp"; Name = "Version"; Value = "1.0.0"; Type = "String" }
    @{ Path = "HKCU:\SOFTWARE\YourApp"; Name = "Configured"; Value = 1; Type = "DWord" }
)
```

## Execution Context

The scripts detect whether they run as **SYSTEM** or as the **current user** and adapt behavior accordingly.

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
- Clear error messages when permissions are insufficient

## Logging

Logs are written to:
```
%ProgramData%\Microsoft\IntuneManagementExtension\Logs\<AppName>.log
```

Each entry includes timestamp and log level (INFO, WARNING, ERROR).

## Testing

Run the test script to validate functionality:

```powershell
.\Test-TemplateScripts.ps1
```

Tests include:
- Syntax validation
- SYSTEM/User context detection
- Registry operations (HKLM and HKCU)
- File copy operations
- Permission handling

## Intune Detection Rules

Example detection rule for registry-based detection:

| Setting | Value |
|---------|-------|
| Rule type | Registry |
| Key path | `HKEY_LOCAL_MACHINE\SOFTWARE\YourApp` |
| Value name | `Version` |
| Detection method | String comparison |
| Value | `1.0.0` |

## Notes

- Scripts work without admin rights but some operations require elevation
- HKCU settings deployed via SYSTEM context persist across user sessions
- Test in a non-production environment before deployment
