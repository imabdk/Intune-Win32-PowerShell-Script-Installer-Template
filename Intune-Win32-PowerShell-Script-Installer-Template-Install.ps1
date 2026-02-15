<#
.SYNOPSIS
    Intune Win32 app PowerShell script installer template - Install.
.DESCRIPTION
    Deploys applications via Intune Win32 PowerShell script installer.
    Supports MSI/EXE, file copy, and registry settings.
    SYSTEM context: applies HKCU/user files to ALL profiles.
    User context: applies to current user only.
.NOTES
    Author:  Martin Bengtsson | imab.dk
    Version: 1.4
    History:
        1.4 - HKU enumeration for registry operations, single-quoted config paths,
              ExpandString for user-context expansion, strict SID regex
        1.3 - Added $env:USERPROFILE translation, $env:ProgramW6432 admin check,
              fixed non-user paths looping through all profiles when running as SYSTEM
        1.2 - Added admin detection, file copy and registry support
        1.0 - Initial release
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
# Use single quotes for $env: paths to preserve variable names for per-user expansion
# SYSTEM context: $env:APPDATA/$env:LOCALAPPDATA/$env:USERPROFILE paths are applied to all user profiles
$FilesToCopy = @(
    @{ Source = "imabdk-config.json"; Destination = '$env:APPDATA\Notepad++' }
    # @{ Source = "another-file.xml"; Destination = "C:\ProgramData\MyApp" }
)

# --- Step 3: Registry Additions ---
# Types: String, DWord, QWord, Binary, MultiString, ExpandString
# SYSTEM context: HKCU paths are applied to all user profiles
$RegistryAdditions = @(
    @{ Path = "HKLM:\SOFTWARE\imab.dk"; Name = "AppVersion"; Value = "1.0"; Type = "String" }
    @{ Path = "HKCU:\SOFTWARE\imab.dk"; Name = "UserSetting"; Value = 1; Type = "DWord" }
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

# Gets all user profiles (AD and Entra ID) - used for file operations
function Get-UserProfiles {
    Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" |
        Where-Object { $_.PSChildName -match "^S-1-(5-21|12-1)-" -and (Test-Path $_.ProfileImagePath) }
}

# Gets user SIDs with loaded registry hives - used for registry operations
function Get-UserSIDs {
    (Get-ChildItem "Registry::HKEY_USERS" -ErrorAction SilentlyContinue).PSChildName |
        Where-Object { $_ -match '^S-1-(5-21|12-1)-\d+-\d+-\d+-\d+$' }
}

# Writes to console and log file
function Write-Log {
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

# Installs application using MSI or EXE
function Install-Application {
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

# Copies files (SYSTEM: to all profiles, User: current only)
function Copy-FilesToDestination {
    param (
        [Parameter(Mandatory)]
        [string]$BasePath,
        [array]$Files
    )

    if ($script:IsSystem) {
        $userProfilePaths = Get-UserProfiles | Select-Object -ExpandProperty ProfileImagePath
    }

    foreach ($file in $Files) {
        $sourcePath = Join-Path -Path $BasePath -ChildPath $file.Source
        if (-not (Test-Path -Path $sourcePath)) {
            throw "File not found in package: $sourcePath"
        }

        $isUserPath = $file.Destination -match '\$env:(APPDATA|LOCALAPPDATA|USERPROFILE)'
        if ($script:IsSystem -and $isUserPath) {
            Write-Log "Copying to $($userProfilePaths.Count) user profile(s)"
            foreach ($profilePath in $userProfilePaths) {
                # Translate user-specific environment paths to actual profile paths
                $destPath = $file.Destination `
                    -replace '\$env:APPDATA', "$profilePath\AppData\Roaming" `
                    -replace '\$env:LOCALAPPDATA', "$profilePath\AppData\Local" `
                    -replace '\$env:USERPROFILE', "$profilePath"

                if (-not (Test-Path -Path $destPath)) {
                    New-Item -Path $destPath -ItemType Directory -Force | Out-Null
                }
                Copy-Item -Path $sourcePath -Destination $destPath -Force
                Write-Log "Copied: $($file.Source) -> $destPath"
            }
        }
        else {
            $destPath = $ExecutionContext.InvokeCommand.ExpandString($file.Destination)
            if ((Test-RequiresAdmin -Path $destPath) -and -not $script:IsAdmin) {
                throw "Access denied: '$destPath' requires administrator privileges"
            }

            if (-not (Test-Path -Path $destPath)) {
                New-Item -Path $destPath -ItemType Directory -Force | Out-Null
            }
            Copy-Item -Path $sourcePath -Destination $destPath -Force
            Write-Log "Copied: $($file.Source) -> $destPath"
        }
    }
}

# Applies registry settings (SYSTEM: to all loaded hives, User: current only)
function Set-RegistryAdditions {
    param (
        [Parameter(Mandatory)]
        [array]$Settings
    )

    $userSIDs = if ($script:IsSystem) { Get-UserSIDs } else { $null }
    if ($userSIDs) {
        Write-Log "Running as SYSTEM - applying HKCU settings to $(@($userSIDs).Count) user(s)"
    }

    foreach ($setting in $Settings) {
        if ($setting.Path -like "HKCU:\*" -and $script:IsSystem) {
            if (-not $userSIDs) {
                Write-Log "No user hives loaded - skipping HKCU settings"
                continue
            }
            foreach ($sid in $userSIDs) {
                $regPath = $setting.Path -replace "^HKCU:\\", "Registry::HKEY_USERS\$sid\"

                if (-not (Test-Path $regPath)) {
                    New-Item -Path $regPath -Force | Out-Null
                }
                Set-ItemProperty -Path $regPath -Name $setting.Name -Value $setting.Value -Type $setting.Type
                Write-Log "Registry: $regPath\$($setting.Name) = $($setting.Value)"
            }
        }
        else {
            if ((Test-RequiresAdmin -Path $setting.Path) -and -not $script:IsAdmin) {
                throw "Access denied: '$($setting.Path)' requires administrator privileges"
            }

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
Write-Log "Context: $(if ($script:IsSystem) { 'SYSTEM' } else { 'User' }), Admin: $($script:IsAdmin)"
Write-Log "Script path: $PSScriptRoot"

try {
    # --- Step 1: Install application ---
    Write-Log "--- Step 1: Installing application ---"
    $installerPath = if ([System.IO.Path]::IsPathRooted($InstallerFile)) { $InstallerFile } else { Join-Path -Path $PSScriptRoot -ChildPath $InstallerFile }
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
    exit 0
}
catch {
    Write-Log "=== Installation of $AppName failed: $($_.Exception.Message) ==="
    exit 1
}
#endregion
