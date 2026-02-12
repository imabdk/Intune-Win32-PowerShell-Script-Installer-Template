#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Intune Win32 app PowerShell script installer template - Uninstall.

.DESCRIPTION
    Template for uninstalling applications via the Intune Win32 PowerShell script installer feature.
    
    Features:
    - Supports both MSI and EXE uninstallers
    - Removes configuration files from user profiles (supports SYSTEM context)
    - Works with both AD and Entra ID joined devices
    - Comprehensive logging for troubleshooting
    
    Note: This script is designed to run in SYSTEM context via Intune.
    
.NOTES
    Author:      Martin Bengtsson
    Twitter:     @mwbengtsson
    LinkedIn:    linkedin.com/in/martin-bengtsson
    Website:     https://www.imab.dk
    Created:     2026-02-12
    Updated:     2026-02-12
    Version:     1.1
    
    Changelog:
    1.1 - Added registry removal support with SYSTEM context awareness
    1.0 - Initial release

.LINK
    https://github.com/imabdk/Intune-Win32-PowerShell-Script-Installer-Template

.LINK
    https://learn.microsoft.com/intune/intune-service/apps/apps-win32-app-management
#>

# === Configuration ===

# --- App Identity ---
[string]$AppName = "Notepad++"
[string]$LogFile = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\$AppName-Uninstall.log"

# --- Step 1: Uninstaller ---
[string]$UninstallerFile = "npp.8.9.1.Installer.x64.msi"
[string]$UninstallerArgs = "/qn /norestart"
[int[]]$SuccessExitCodes = @(0, 3010)
# Examples:
#   MSI: "/qn /norestart"
#   EXE: "/S" or "/silent" or "/VERYSILENT /SUPPRESSMSGBOXES"

# --- Step 2: Delete Files ---
# SYSTEM context: $env:APPDATA/$env:LOCALAPPDATA paths are applied to all user profiles
$FilesToDelete = @(
    "$env:APPDATA\Notepad++\imabdk-config.json"
    # "$env:LOCALAPPDATA\MyApp\settings.xml"
)

# --- Step 3: Remove Registry Settings ---
# Action: "DeleteValue" removes a single value, "DeleteKey" removes entire key and subkeys
# SYSTEM context: HKCU paths are automatically applied to all user profiles
$RegistryRemovals = @(
    @{
        Path   = "HKLM:\SOFTWARE\imab.dk"
        Action = "DeleteKey"
    }
    # @{
    #     Path   = "HKLM:\SOFTWARE\MyApp"
    #     Name   = "SettingName"
    #     Action = "DeleteValue"
    # }
)

#region Functions
function Write-Log {
    <#
    .SYNOPSIS
        Writes to both console (for Intune portal) and local log file.
    #>
    param(
        [string]$Message,
        [int]$MaxLogSizeMB = 5
    )

    Write-Output "[$AppName] [UNINSTALL] $Message"
    if ([string]::IsNullOrWhiteSpace($Message)) { return }

    try {
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length / 1MB) -ge $MaxLogSizeMB) {
            Move-Item -Path $LogFile -Destination "$LogFile.old" -Force -ErrorAction SilentlyContinue
        }
        Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$AppName] [UNINSTALL] $Message" -ErrorAction SilentlyContinue
    }
    catch { }
}

function Uninstall-Application {
    <#
    .SYNOPSIS
        Uninstalls the application using MSI or EXE uninstaller.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$UninstallerPath,
        [string]$Arguments,
        [int[]]$SuccessCodes = @(0, 3010)
    )

    $uninstallerExt = [System.IO.Path]::GetExtension($UninstallerPath).ToLower()

    if (-not (Test-Path -Path $UninstallerPath)) {
        throw "Uninstaller not found: $UninstallerPath"
    }

    switch ($uninstallerExt) {
        ".msi" {
            $msiLogPath = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\$AppName-MSI-Uninstall.log"
            $msiArgs    = "/x `"$UninstallerPath`" $Arguments /l*v `"$msiLogPath`""
            Write-Log "Uninstalling MSI: msiexec.exe $msiArgs"
            $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
        }
        ".exe" {
            Write-Log "Uninstalling EXE: $UninstallerPath $Arguments"
            $process = Start-Process -FilePath $UninstallerPath -ArgumentList $Arguments -Wait -PassThru
        }
        default {
            throw "Unsupported uninstaller type: $uninstallerExt"
        }
    }

    Write-Log "Uninstaller finished with exit code: $($process.ExitCode)"
    if ($process.ExitCode -notin $SuccessCodes) {
        throw "Uninstallation failed with exit code: $($process.ExitCode)"
    }
}

function Remove-FilesFromDestination {
    <#
    .SYNOPSIS
        Deletes files from their destinations.
        When running as SYSTEM, deletes from all existing user profiles.
    #>
    param (
        [array]$Files
    )

    # Detect if running as SYSTEM (S-1-5-18)
    $isSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq "S-1-5-18")

    foreach ($file in $Files) {
        if ($isSystem) {
            # Get all real user profiles from registry (excludes system accounts)
            # Supports both traditional AD (S-1-5-21-*) and Entra ID (S-1-12-1-*) joined devices
            $userProfiles = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" |
                Where-Object { $_.PSChildName -match "^S-1-(5-21|12-1)-" -and (Test-Path $_.ProfileImagePath) } |
                Select-Object -ExpandProperty ProfileImagePath

            Write-Log "Running as SYSTEM - deleting from $($userProfiles.Count) user profile(s)"

            foreach ($profilePath in $userProfiles) {
                # Translate user-specific environment paths to actual profile paths
                $filePath = $file `
                    -replace '\$env:APPDATA', "$profilePath\AppData\Roaming" `
                    -replace '\$env:LOCALAPPDATA', "$profilePath\AppData\Local"

                if (Test-Path -Path $filePath) {
                    Remove-Item -Path $filePath -Force
                    Write-Log "Deleted: $filePath"
                }
            }
        }
        else {
            # Running as user - delete from current user only
            if (Test-Path -Path $file) {
                Remove-Item -Path $file -Force
                Write-Log "Deleted: $file"
            }
        }
    }
}

function Remove-RegistrySettings {
    <#
    .SYNOPSIS
        Removes registry values or keys. HKCU paths are applied to all user profiles when running as SYSTEM.
    #>
    param (
        [Parameter(Mandatory)]
        [array]$Settings
    )

    $isSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq "S-1-5-18")

    foreach ($setting in $Settings) {
        $paths = @()

        if ($setting.Path -like "HKCU:\*" -and $isSystem) {
            # Get all real user profiles and build paths for each
            $userProfiles = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" |
                Where-Object { $_.PSChildName -match "^S-1-(5-21|12-1)-" -and (Test-Path $_.ProfileImagePath) }

            Write-Log "Running as SYSTEM - removing from $($userProfiles.Count) user profile(s)"

            foreach ($profile in $userProfiles) {
                $sid = $profile.PSChildName
                $paths += $setting.Path -replace "^HKCU:\\", "Registry::HKEY_USERS\$sid\"
            }
        }
        else {
            $paths += $setting.Path
        }

        foreach ($regPath in $paths) {
            switch ($setting.Action) {
                "DeleteValue" {
                    if (Test-Path $regPath) {
                        Remove-ItemProperty -Path $regPath -Name $setting.Name -Force -ErrorAction SilentlyContinue
                        Write-Log "Removed value: $regPath\$($setting.Name)"
                    }
                }
                "DeleteKey" {
                    if (Test-Path $regPath) {
                        Remove-Item -Path $regPath -Recurse -Force -ErrorAction SilentlyContinue
                        Write-Log "Removed key: $regPath"
                    }
                }
            }
        }
    }
}
#endregion

#region Main
Write-Log "=== Starting uninstallation of $AppName ==="
Write-Log "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Log "Script path: $PSScriptRoot"

try {
    # --- Step 1: Uninstall application ---
    Write-Log "--- Step 1: Uninstalling application ---"
    $uninstallerPath = Join-Path -Path $PSScriptRoot -ChildPath $UninstallerFile
    Uninstall-Application -UninstallerPath $uninstallerPath -Arguments $UninstallerArgs -SuccessCodes $SuccessExitCodes

    # --- Step 2: Delete configuration files ---
    if ($FilesToDelete.Count -gt 0) {
        Write-Log "--- Step 2: Deleting configuration files ---"
        Remove-FilesFromDestination -Files $FilesToDelete
    }

    # --- Step 3: Remove registry settings ---
    if ($RegistryRemovals.Count -gt 0) {
        Write-Log "--- Step 3: Removing registry settings ---"
        Remove-RegistrySettings -Settings $RegistryRemovals
    }

    Write-Log "=== Uninstallation of $AppName completed successfully ==="
    exit 0  # Success
}
catch {
    Write-Log "=== Uninstallation of $AppName failed: $($_.Exception.Message) ==="
    exit 1  # Failure
}
#endregion
