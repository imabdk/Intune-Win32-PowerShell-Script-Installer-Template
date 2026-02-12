<#
.SYNOPSIS
    Intune Win32 app PowerShell script uninstaller template.
.DESCRIPTION
    Template for uninstalling applications via the Intune Win32 PowerShell script installer feature.
.NOTES
    Author:   Martin Bengtsson
    Date:     2026-02-12
    Version:  1.0
#>

# === Configuration ===
[string]$AppName         = "Notepad++"
[string]$LogFile         = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\$AppName-Uninstall.log"

# Uninstaller configuration
[string]$UninstallerFile = "npp.8.9.1.Installer.x64.msi"
[string]$UninstallerArgs = "/qn /norestart"
# Examples:
#   MSI: "/qn /norestart"
#   EXE: "/S" or "/silent" or "/VERYSILENT /SUPPRESSMSGBOXES"
[int[]]$SuccessExitCodes = @(0, 3010)

# Files to delete during uninstallation
$FilesToDelete = @(
    "$env:APPDATA\Notepad++\imabdk-config.json"
    # "$env:LOCALAPPDATA\MyApp\settings.xml"
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
#endregion

#region Main
Write-Log "=== Starting uninstallation of $AppName ==="
Write-Log "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Log "Script path: $PSScriptRoot"

try {
    $uninstallerPath = Join-Path -Path $PSScriptRoot -ChildPath $UninstallerFile

    Uninstall-Application -UninstallerPath $uninstallerPath -Arguments $UninstallerArgs -SuccessCodes $SuccessExitCodes
    Remove-FilesFromDestination -Files $FilesToDelete

    Write-Log "=== Uninstallation of $AppName completed successfully ==="
    exit 0  # Success
}
catch {
    Write-Log "=== Uninstallation of $AppName failed: $($_.Exception.Message) ==="
    exit 1  # Failure
}
#endregion
