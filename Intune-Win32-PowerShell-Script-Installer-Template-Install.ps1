#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Intune Win32 app PowerShell script installer template - Install.

.DESCRIPTION
    Template for deploying applications via the Intune Win32 PowerShell script installer feature.
    
    Features:
    - Supports both MSI and EXE installers
    - Copies configuration files to user profiles (supports SYSTEM context)
    - Works with both AD and Entra ID joined devices
    - Comprehensive logging for troubleshooting
    
    Note: This script is designed to run in SYSTEM context via Intune.
    
.NOTES
    Author:      Martin Bengtsson
    Twitter:     @mwbengtsson
    LinkedIn:    linkedin.com/in/martin-bengtsson
    Website:     https://www.imab.dk
    Created:     2026-02-11
    Updated:     2026-02-12
    Version:     1.1
    
    Changelog:
    1.1 - Added registry settings support with SYSTEM context awareness
    1.0 - Initial release

.LINK
    https://github.com/imabdk/Intune-Win32-PowerShell-Script-Installer-Template

.LINK
    https://learn.microsoft.com/intune/intune-service/apps/apps-win32-app-management
#>

# === Configuration ===

# --- App Identity ---
[string]$AppName = "Notepad++"
[string]$LogFile = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\$AppName-Install.log"

# --- Step 1: Installer ---
[string]$InstallerFile   = "npp.8.9.1.Installer.x64.msi"
[string]$InstallerArgs   = "/qn /norestart"
[int[]]$SuccessExitCodes = @(0, 3010)
# Examples:
#   MSI: "/qn /norestart"
#   EXE: "/S" or "/silent" or "/VERYSILENT /SUPPRESSMSGBOXES"

# --- Step 2: Copy Files ---
# Source = filename in package, Destination = target folder
# SYSTEM context: $env:APPDATA/$env:LOCALAPPDATA paths are applied to all user profiles
$FilesToCopy = @(
    @{ Source = "imabdk-config.json"; Destination = "$env:APPDATA\Notepad++" }
    # @{ Source = "another-file.xml"; Destination = "C:\ProgramData\MyApp" }
)

# --- Step 3: Registry Additions ---
# Types: String, DWord, QWord, Binary, MultiString, ExpandString
# SYSTEM context: HKCU paths are automatically applied to all user profiles
$RegistryAdditions = @(
    # Machine-wide settings (HKLM)
    @{
        Path  = "HKLM:\SOFTWARE\imab.dk"
        Name  = "BlogURL"
        Value = "https://www.imab.dk"
        Type  = "String"
    }
    @{
        Path  = "HKLM:\SOFTWARE\imab.dk"
        Name  = "Author"
        Value = "Martin Bengtsson"
        Type  = "String"
    }
    @{
        Path  = "HKLM:\SOFTWARE\imab.dk"
        Name  = "AwesomeLevel"
        Value = 100
        Type  = "DWord"
    }
    # Per-user settings (HKCU - applied to all user profiles when running as SYSTEM)
    @{
        Path  = "HKCU:\SOFTWARE\imab.dk"
        Name  = "BlogURL"
        Value = "https://www.imab.dk"
        Type  = "String"
    }
    @{
        Path  = "HKCU:\SOFTWARE\imab.dk"
        Name  = "Author"
        Value = "Martin Bengtsson"
        Type  = "String"
    }
    @{
        Path  = "HKCU:\SOFTWARE\imab.dk"
        Name  = "AwesomeLevel"
        Value = 100
        Type  = "DWord"
    }
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

    Write-Output "[$AppName] [INSTALL] $Message"
    if ([string]::IsNullOrWhiteSpace($Message)) { return }

    try {
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length / 1MB) -ge $MaxLogSizeMB) {
            Move-Item -Path $LogFile -Destination "$LogFile.old" -Force -ErrorAction SilentlyContinue
        }
        Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$AppName] [INSTALL] $Message" -ErrorAction SilentlyContinue
    }
    catch { }
}

function Install-Application {
    <#
    .SYNOPSIS
        Installs the application using MSI or EXE installer.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$InstallerPath,
        [string]$Arguments,
        [int[]]$SuccessCodes = @(0, 3010)
    )

    $installerExt = [System.IO.Path]::GetExtension($InstallerPath).ToLower()

    if (-not (Test-Path -Path $InstallerPath)) {
        throw "Installer not found: $InstallerPath"
    }

    switch ($installerExt) {
        ".msi" {
            $msiLogPath = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\$AppName-MSI.log"
            $msiArgs    = "/i `"$InstallerPath`" $Arguments /l*v `"$msiLogPath`""
            Write-Log "Installing MSI: msiexec.exe $msiArgs"
            $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
        }
        ".exe" {
            Write-Log "Installing EXE: $InstallerPath $Arguments"
            $process = Start-Process -FilePath $InstallerPath -ArgumentList $Arguments -Wait -PassThru
        }
        default {
            throw "Unsupported installer type: $installerExt"
        }
    }

    Write-Log "Installer finished with exit code: $($process.ExitCode)"
    if ($process.ExitCode -notin $SuccessCodes) {
        throw "Installation failed with exit code: $($process.ExitCode)"
    }
}

function Copy-FilesToDestination {
    <#
    .SYNOPSIS
        Copies files from the package to their destinations.
        When running as SYSTEM, copies to all existing user profiles.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$BasePath,
        [array]$Files
    )

    # Detect if running as SYSTEM (S-1-5-18)
    $isSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq "S-1-5-18")

    foreach ($file in $Files) {
        $sourcePath = Join-Path -Path $BasePath -ChildPath $file.Source
        if (-not (Test-Path -Path $sourcePath)) {
            throw "File not found in package: $sourcePath"
        }

        if ($isSystem) {
            # Get all real user profiles from registry (excludes system accounts)
            # Supports both traditional AD (S-1-5-21-*) and Entra ID (S-1-12-1-*) joined devices
            $userProfiles = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" |
                Where-Object { $_.PSChildName -match "^S-1-(5-21|12-1)-" -and (Test-Path $_.ProfileImagePath) } |
                Select-Object -ExpandProperty ProfileImagePath

            Write-Log "Running as SYSTEM - copying to $($userProfiles.Count) user profile(s)"

            foreach ($profilePath in $userProfiles) {
                # Translate user-specific environment paths to actual profile paths
                $destPath = $file.Destination `
                    -replace '\$env:APPDATA', "$profilePath\AppData\Roaming" `
                    -replace '\$env:LOCALAPPDATA', "$profilePath\AppData\Local"

                if (-not (Test-Path -Path $destPath)) {
                    New-Item -Path $destPath -ItemType Directory -Force | Out-Null
                }
                Copy-Item -Path $sourcePath -Destination $destPath -Force
                Write-Log "Copied: $($file.Source) -> $destPath"
            }
        }
        else {
            # Running as user - copy to current user only
            if (-not (Test-Path -Path $file.Destination)) {
                New-Item -Path $file.Destination -ItemType Directory -Force | Out-Null
            }
            Copy-Item -Path $sourcePath -Destination $file.Destination -Force
            Write-Log "Copied: $($file.Source) -> $($file.Destination)"
        }
    }
}

function Set-RegistryAdditions {
    <#
    .SYNOPSIS
        Applies registry settings. HKCU paths are applied to all user profiles when running as SYSTEM.
    #>
    param (
        [Parameter(Mandatory)]
        [array]$Settings
    )

    $isSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq "S-1-5-18")

    foreach ($setting in $Settings) {
        if ($setting.Path -like "HKCU:\*" -and $isSystem) {
            # Get all real user profiles and apply to each user's registry hive
            $userProfiles = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" |
                Where-Object { $_.PSChildName -match "^S-1-(5-21|12-1)-" -and (Test-Path $_.ProfileImagePath) }

            Write-Log "Running as SYSTEM - applying HKCU setting to $($userProfiles.Count) user profile(s)"

            foreach ($profile in $userProfiles) {
                $sid = $profile.PSChildName
                $hivePath = "Registry::HKEY_USERS\$sid"
                $regPath = $setting.Path -replace "^HKCU:\\", "$hivePath\"

                if (-not (Test-Path $regPath)) {
                    New-Item -Path $regPath -Force | Out-Null
                }
                Set-ItemProperty -Path $regPath -Name $setting.Name -Value $setting.Value -Type $setting.Type
                Write-Log "Registry: $regPath\$($setting.Name) = $($setting.Value)"
            }
        }
        else {
            # HKLM or running as user
            if (-not (Test-Path $setting.Path)) {
                New-Item -Path $setting.Path -Force | Out-Null
            }
            Set-ItemProperty -Path $setting.Path -Name $setting.Name -Value $setting.Value -Type $setting.Type
            Write-Log "Registry: $($setting.Path)\$($setting.Name) = $($setting.Value)"
        }
    }
}
#endregion

#region Main
Write-Log "=== Starting installation of $AppName ==="
Write-Log "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Log "Script path: $PSScriptRoot"

try {
    # --- Step 1: Install application ---
    Write-Log "--- Step 1: Installing application ---"
    $installerPath = Join-Path -Path $PSScriptRoot -ChildPath $InstallerFile
    Install-Application -InstallerPath $installerPath -Arguments $InstallerArgs -SuccessCodes $SuccessExitCodes

    # --- Step 2: Copy configuration files ---
    if ($FilesToCopy.Count -gt 0) {
        Write-Log "--- Step 2: Copying configuration files ---"
        Copy-FilesToDestination -BasePath $PSScriptRoot -Files $FilesToCopy
    }

    # --- Step 3: Apply registry settings ---
    if ($RegistryAdditions.Count -gt 0) {
        Write-Log "--- Step 3: Applying registry additions ---"
        Set-RegistryAdditions -Settings $RegistryAdditions
    }

    Write-Log "=== Installation of $AppName completed successfully ==="
    exit 0  # Success
}
catch {
    Write-Log "=== Installation of $AppName failed: $($_.Exception.Message) ==="
    exit 1  # Failure
}
#endregion
