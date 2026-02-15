# Intune Win32 PowerShell Script Installer Template

Ready-to-use templates for the [PowerShell script installer](https://learn.microsoft.com/en-us/intune/intune-service/apps/apps-win32-app-management#powershell-script-installer) in Microsoft Intune. Instead of specifying a traditional command line for your Win32 app, you upload a PowerShell script as the installer and uninstaller. These templates handle MSI/EXE installation, file copy, and registry settings out of the box.

Read the full blog post here: [Template for the Win32 PowerShell script installer in Microsoft Intune](https://www.imab.dk/template-for-the-win32-powershell-script-installer-in-microsoft-intune/)

## Getting started

1. Edit the configuration section at the top of each script (see examples below)
2. Package your application and any files you need copied with the [Microsoft Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool)
3. In Intune, create a new Win32 app and upload the `.intunewin` package
4. Under **Program**, select **PowerShell script** as the installer type and upload the install and uninstall scripts

The scripts themselves are **not** part of the `.intunewin` package. They are uploaded separately in Intune when you select the PowerShell script installer option.

**Good to know:** Scripts are limited to 50 KB, must run silently, and run in the same context as the app installer (SYSTEM or user).

## Configuration

All configuration lives at the top of each script. Here's what you typically change:

### Install script

```powershell
# App identity
$AppName = "Notepad++"

# Installer (MSI or EXE)
$InstallerFile = "npp.8.9.1.Installer.x64.msi"
$InstallerArgs = "/qn /norestart"

# File copy (use single quotes for $env: paths)
$FilesToCopy = @(
    @{ Source = "imabdk-config.json"; Destination = '$env:APPDATA\Notepad++' }
    @{ Source = "license.lic"; Destination = '$env:ProgramW6432\Notepad++' }
)

# Registry additions
$RegistryAdditions = @(
    @{ Path = "HKLM:\SOFTWARE\imab.dk"; Name = "AppVersion"; Value = "1.0"; Type = "String" }
    @{ Path = "HKCU:\SOFTWARE\imab.dk"; Name = "UserSetting"; Value = 1; Type = "DWord" }
)
```

### Uninstall script

```powershell
# App identity
$AppName = "Notepad++"

# Uninstaller (MSI or EXE)
$UninstallerFile = "npp.8.9.1.Installer.x64.msi"
$UninstallerArgs = "/qn /norestart"
# EXE example: $UninstallerFile = "$env:ProgramW6432\Notepad++\uninstall.exe"

# File removal (use single quotes for $env: paths)
$FilesToRemove = @(
    '$env:APPDATA\Notepad++\imabdk-config.json'
    '$env:ProgramW6432\Notepad++\license.lic'
)

# Registry removal
$RegistryRemovals = @(
    @{ Path = "HKLM:\SOFTWARE\imab.dk"; Action = "DeleteKey" }
    @{ Path = "HKCU:\SOFTWARE\imab.dk"; Action = "DeleteKey" }
    # Remove a single value instead of the entire key:
    # @{ Path = "HKCU:\SOFTWARE\imab.dk"; Name = "UserSetting"; Action = "DeleteValue" }
)
```

## How SYSTEM vs user context works

The scripts detect whether they run as **SYSTEM** or as the **current user** and adjust automatically.

When running as **SYSTEM** (typical for Intune deployments):
- HKCU registry settings are applied to all existing user profiles via the HKU hive
- File copy destinations under user profiles (like `$env:APPDATA`) target all users
- Both AD (S-1-5-21-\*) and Entra ID (S-1-12-1-\*) accounts are picked up

When running as the **current user**:
- HKCU registry settings apply to the current user only
- File operations target the current user profile only
- The scripts check permissions before attempting operations on protected paths

## Logging

Log files are written to the Intune log folder:
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

- The scripts work without admin rights, but operations on protected paths (Program Files, HKLM, etc.) require elevation
- Always test in a non-production environment first
