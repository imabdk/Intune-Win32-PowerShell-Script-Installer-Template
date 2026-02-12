<#
.SYNOPSIS
    Intune Win32 app PowerShell script installer template.
.DESCRIPTION
    Template for deploying applications via the Intune Win32 PowerShell script installer feature.
.NOTES
    Author:   Martin Bengtsson
    Date:     2026-02-11
    Version:  1.0
#>

# === Configuration ===
[string]$AppName         = "Notepad++"
[string]$LogFile         = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\$AppName-Install.log"

# Installer configuration
[string]$InstallerFile   = "npp.8.9.1.Installer.x64.msi"
[string]$InstallerArgs   = "/qn /norestart"
# Examples:
#   MSI: "/qn /norestart"
#   EXE: "/S" or "/silent" or "/VERYSILENT /SUPPRESSMSGBOXES"
[int[]]$SuccessExitCodes = @(0, 3010)

# Files to copy after installation (Source = filename in package, Destination = target folder)
$FilesToCopy = @(
    @{ Source = "imabdk-config.json"; Destination = "$env:APPDATA\Notepad++" }
    # @{ Source = "another-file.xml"; Destination = "C:\ProgramData\MyApp" }
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
#endregion

#region Main
Write-Log "=== Starting installation of $AppName ==="
Write-Log "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Log "Script path: $PSScriptRoot"

try {
    $installerPath = Join-Path -Path $PSScriptRoot -ChildPath $InstallerFile

    Install-Application -InstallerPath $installerPath -Arguments $InstallerArgs -SuccessCodes $SuccessExitCodes
    Copy-FilesToDestination -BasePath $PSScriptRoot -Files $FilesToCopy

    Write-Log "=== Installation of $AppName completed successfully ==="
    exit 0  # Success
}
catch {
    Write-Log "=== Installation of $AppName failed: $($_.Exception.Message) ==="
    exit 1  # Failure
}
#endregion
