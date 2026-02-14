<#
.SYNOPSIS
    Intune Win32 app PowerShell script installer template - Uninstall.
.DESCRIPTION
    Uninstalls applications via Intune Win32 PowerShell script installer.
    Supports MSI/EXE, file removal, and registry cleanup.
    SYSTEM context: removes HKCU/user files from ALL profiles.
    User context: removes from current user only.
.NOTES
    Author:  Martin Bengtsson | imab.dk
    Version: 1.3
    History:
        1.3 - Added $env:USERPROFILE translation, $env:ProgramW6432 admin check,
              fixed non-user paths looping through all profiles when running as SYSTEM
        1.2 - Added admin detection, file removal and registry cleanup support
        1.0 - Initial release
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

# --- Step 2: Remove Files ---
# Full path(s) to files to remove
# SYSTEM context: $env:APPDATA/$env:LOCALAPPDATA/$env:USERPROFILE paths are applied to all user profiles
$FilesToRemove = @(
    "$env:APPDATA\Notepad++\imabdk-config.json"
    # "$env:LOCALAPPDATA\MyApp\settings.xml"
)

# --- Step 3: Remove Registry Settings ---
# Action: "DeleteValue" or "DeleteKey" (removes entire key)
# SYSTEM context: HKCU paths are applied to all user profiles
$RegistryRemovals = @(
    @{ Path = "HKLM:\SOFTWARE\imab.dk"; Action = "DeleteKey" }
    @{ Path = "HKCU:\SOFTWARE\imab.dk"; Action = "DeleteKey" }
)

# === Runtime Detection ===
$script:IsSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq "S-1-5-18")
$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

#region Functions
# Tests if path requires administrator privileges
function Test-RequiresAdmin {
    param([string]$Path)
    if ($Path -match "^HKLM:|^Registry::HKEY_LOCAL_MACHINE") { return $true }
    $adminPaths = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432, $env:SystemRoot, $env:ProgramData)
    foreach ($adminPath in $adminPaths) {
        if ($adminPath -and $Path -like "$adminPath*") { return $true }
    }
    return $false
}

# Gets all user profiles (AD and Entra ID)
function Get-UserProfiles {
    Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" |
        Where-Object { $_.PSChildName -match "^S-1-(5-21|12-1)-" -and (Test-Path $_.ProfileImagePath) }
}

# Writes to console and log file
function Write-Log {
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

# Uninstalls application using MSI or EXE
function Uninstall-Application {
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

# Removes files (SYSTEM: from all profiles, User: current only)
function Remove-FilesFromDestination {
    param (
        [array]$Files
    )

    if ($script:IsSystem) {
        $userProfilePaths = Get-UserProfiles | Select-Object -ExpandProperty ProfileImagePath
    }

    foreach ($file in $Files) {
        $isUserPath = $file -match '\$env:(APPDATA|LOCALAPPDATA|USERPROFILE)'
        if ($script:IsSystem -and $isUserPath) {
            Write-Log "Removing from $($userProfilePaths.Count) user profile(s)"
            foreach ($profilePath in $userProfilePaths) {
                # Translate user-specific environment paths to actual profile paths
                $filePath = $file `
                    -replace '\$env:APPDATA', "$profilePath\AppData\Roaming" `
                    -replace '\$env:LOCALAPPDATA', "$profilePath\AppData\Local" `
                    -replace '\$env:USERPROFILE', "$profilePath"

                if (Test-Path -Path $filePath) {
                    Remove-Item -Path $filePath -Force
                    Write-Log "Removed: $filePath"
                }
            }
        }
        else {
            if ((Test-RequiresAdmin -Path $file) -and -not $script:IsAdmin) {
                throw "Access denied: '$file' requires administrator privileges"
            }

            if (Test-Path -Path $file) {
                Remove-Item -Path $file -Force
                Write-Log "Removed: $file"
            }
        }
    }
}

# Removes registry values/keys (SYSTEM: from all profiles, User: current only)
function Remove-RegistrySettings {
    param (
        [Parameter(Mandatory)]
        [array]$Settings
    )

    $userProfiles = if ($script:IsSystem) { Get-UserProfiles } else { $null }
    if ($userProfiles) {
        Write-Log "Running as SYSTEM - removing from $($userProfiles.Count) user profile(s)"
    }

    foreach ($setting in $Settings) {
        $paths = @()

        if ($setting.Path -like "HKCU:\*" -and $script:IsSystem) {
            foreach ($userProfile in $userProfiles) {
                $sid = $userProfile.PSChildName
                $paths += $setting.Path -replace "^HKCU:\\", "Registry::HKEY_USERS\$sid\"
            }
        }
        else {
            if ((Test-RequiresAdmin -Path $setting.Path) -and -not $script:IsAdmin) {
                throw "Access denied: '$($setting.Path)' requires administrator privileges"
            }
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
Write-Log "Context: $(if ($script:IsSystem) { 'SYSTEM' } else { 'User' }), Admin: $($script:IsAdmin)"
Write-Log "Script path: $PSScriptRoot"

try {
    # --- Step 1: Uninstall application ---
    Write-Log "--- Step 1: Uninstalling application ---"
    $uninstallerPath = if ([System.IO.Path]::IsPathRooted($UninstallerFile)) { $UninstallerFile } else { Join-Path -Path $PSScriptRoot -ChildPath $UninstallerFile }
    Uninstall-Application -UninstallerPath $uninstallerPath -Arguments $UninstallerArgs -SuccessCodes $SuccessExitCodes

    # --- Step 2: Remove configuration files ---
    if ($FilesToRemove.Count -gt 0) {
        Write-Log "--- Step 2: Removing configuration files ---"
        Remove-FilesFromDestination -Files $FilesToRemove
    }

    # --- Step 3: Remove registry settings ---
    if ($RegistryRemovals.Count -gt 0) {
        Write-Log "--- Step 3: Removing registry settings ---"
        Remove-RegistrySettings -Settings $RegistryRemovals
    }

    Write-Log "=== Uninstallation of $AppName completed successfully ==="
    exit 0
}
catch {
    Write-Log "=== Uninstallation of $AppName failed: $($_.Exception.Message) ==="
    exit 1
}
#endregion
