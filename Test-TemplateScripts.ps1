<#
.SYNOPSIS
    Test script for the Intune Win32 PowerShell script installer template.

.DESCRIPTION
    Validates all template functionality without requiring an actual installer.
    Runs adaptively - HKLM tests are skipped if not running as Administrator.
    
    Tests:
    1. SYSTEM context detection
    2. User profile enumeration (AD + Entra ID support)
    3. Registry operations (HKLM - requires admin, HKCU)
    4. File copy/delete operations
    5. Cleanup

.NOTES
    Author:      Martin Bengtsson
    Created:     2026-02-13
    
    Run as: Any user (HKLM tests skipped without admin)
    To simulate SYSTEM context: Use PsExec -s or run via Intune
#>

param(
    [switch]$SkipCleanup  # Keep test artifacts for inspection
)

$ErrorActionPreference = "Stop"
$TestResults = @()

# Detect if running as Administrator
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Write-TestResult {
    param(
        [string]$TestName,
        [bool]$Passed,
        [string]$Details = ""
    )
    
    $status = if ($Passed) { "[PASS]" } else { "[FAIL]" }
    $color = if ($Passed) { "Green" } else { "Red" }
    
    Write-Host "$status $TestName" -ForegroundColor $color
    if ($Details) { Write-Host "       $Details" -ForegroundColor Gray }
    
    $script:TestResults += [PSCustomObject]@{
        Test    = $TestName
        Passed  = $Passed
        Details = $Details
    }
}

Write-Host "`n=== Intune Win32 PowerShell Script Installer Template - Test Suite ===" -ForegroundColor Cyan
Write-Host "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Host "Administrator: $isAdmin`n"

# ============================================================================
# TEST 1: SYSTEM Context Detection
# ============================================================================
Write-Host "--- Test 1: SYSTEM Context Detection ---" -ForegroundColor Yellow

$currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$isSystem = ($currentSid -eq "S-1-5-18")

Write-TestResult -TestName "SYSTEM detection logic" -Passed $true -Details "SID: $currentSid, IsSystem: $isSystem"

if ($isSystem) {
    Write-Host "       Note: Running as SYSTEM - HKCU operations will target all user profiles" -ForegroundColor Magenta
} else {
    Write-Host "       Note: Running as user - HKCU operations will target current user only" -ForegroundColor Magenta
}

# ============================================================================
# TEST 2: User Profile Enumeration
# ============================================================================
Write-Host "`n--- Test 2: User Profile Enumeration ---" -ForegroundColor Yellow

try {
    $userProfiles = @(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" |
        Where-Object { $_.PSChildName -match "^S-1-(5-21|12-1)-" -and (Test-Path $_.ProfileImagePath) })
    
    $adProfiles = @($userProfiles | Where-Object { $_.PSChildName -match "^S-1-5-21-" })
    $entraProfiles = @($userProfiles | Where-Object { $_.PSChildName -match "^S-1-12-1-" })
    
    Write-TestResult -TestName "Profile enumeration" -Passed ($userProfiles.Count -gt 0) `
        -Details "Found $($userProfiles.Count) profile(s): AD=$($adProfiles.Count), Entra ID=$($entraProfiles.Count)"
    
    foreach ($prof in $userProfiles) {
        Write-Host "       - $($prof.ProfileImagePath) [$($prof.PSChildName.Substring(0,15))...]" -ForegroundColor Gray
    }
}
catch {
    Write-TestResult -TestName "Profile enumeration" -Passed $false -Details $_.Exception.Message
}

# ============================================================================
# TEST 3: Registry Operations - HKLM
# ============================================================================
Write-Host "`n--- Test 3: Registry Operations (HKLM) ---" -ForegroundColor Yellow

$testRegPath = "HKLM:\SOFTWARE\imab.dk-TEST"
$testValues = @(
    @{ Name = "StringTest"; Value = "Hello World"; Type = "String" }
    @{ Name = "DWordTest"; Value = 42; Type = "DWord" }
    @{ Name = "QWordTest"; Value = [int64]9999999999; Type = "QWord" }
)

if ($isAdmin) {
    try {
        # Create key
        if (-not (Test-Path $testRegPath)) {
            New-Item -Path $testRegPath -Force | Out-Null
        }
        Write-TestResult -TestName "HKLM key creation" -Passed $true -Details $testRegPath

        # Set values
        foreach ($val in $testValues) {
            Set-ItemProperty -Path $testRegPath -Name $val.Name -Value $val.Value -Type $val.Type
        }
        Write-TestResult -TestName "HKLM value creation" -Passed $true -Details "$($testValues.Count) values created"

        # Verify values
        $readBack = Get-ItemProperty -Path $testRegPath
        $allMatch = ($readBack.StringTest -eq "Hello World") -and ($readBack.DWordTest -eq 42)
        Write-TestResult -TestName "HKLM value verification" -Passed $allMatch -Details "StringTest=$($readBack.StringTest), DWordTest=$($readBack.DWordTest)"
    }
    catch {
        Write-TestResult -TestName "HKLM operations" -Passed $false -Details $_.Exception.Message
    }
}
else {
    Write-Host "       [SKIP] HKLM tests require Administrator privileges" -ForegroundColor DarkYellow
}

# ============================================================================
# TEST 4: Registry Operations - HKCU (or HKU if SYSTEM)
# ============================================================================
Write-Host "`n--- Test 4: Registry Operations (HKCU/HKU) ---" -ForegroundColor Yellow

$testHkcuPath = "SOFTWARE\imab.dk-TEST"

try {
    if ($isSystem) {
        # Running as SYSTEM - apply to all user hives
        $userProfiles = @(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" |
            Where-Object { $_.PSChildName -match "^S-1-(5-21|12-1)-" -and (Test-Path $_.ProfileImagePath) })
        
        $successCount = 0
        foreach ($userProfile in $userProfiles) {
            $sid = $userProfile.PSChildName
            $hivePath = "Registry::HKEY_USERS\$sid\$testHkcuPath"
            
            if (-not (Test-Path $hivePath)) {
                New-Item -Path $hivePath -Force | Out-Null
            }
            Set-ItemProperty -Path $hivePath -Name "TestValue" -Value "SystemContextTest" -Type String
            $successCount++
        }
        Write-TestResult -TestName "HKU multi-user write" -Passed ($successCount -eq $userProfiles.Count) `
            -Details "Written to $successCount/$($userProfiles.Count) user hives"
    }
    else {
        # Running as user - apply to HKCU only
        $hkcuFullPath = "HKCU:\$testHkcuPath"
        if (-not (Test-Path $hkcuFullPath)) {
            New-Item -Path $hkcuFullPath -Force | Out-Null
        }
        Set-ItemProperty -Path $hkcuFullPath -Name "TestValue" -Value "UserContextTest" -Type String
        
        $readBack = Get-ItemProperty -Path $hkcuFullPath
        Write-TestResult -TestName "HKCU write" -Passed ($readBack.TestValue -eq "UserContextTest") `
            -Details "Value: $($readBack.TestValue)"
    }
}
catch {
    Write-TestResult -TestName "HKCU/HKU operations" -Passed $false -Details $_.Exception.Message
}

# ============================================================================
# TEST 5: File Operations
# ============================================================================
Write-Host "`n--- Test 5: File Operations ---" -ForegroundColor Yellow

$testSourceFile = Join-Path $PSScriptRoot "test-config-temp.json"
$testContent = '{"test": "data", "timestamp": "' + (Get-Date -Format "o") + '"}'

try {
    # Create test source file
    Set-Content -Path $testSourceFile -Value $testContent -Force
    Write-TestResult -TestName "Test file creation" -Passed (Test-Path $testSourceFile) -Details $testSourceFile

    if ($isSystem) {
        # Copy to all user profiles
        $userProfiles = @(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" |
            Where-Object { $_.PSChildName -match "^S-1-(5-21|12-1)-" -and (Test-Path $_.ProfileImagePath) } |
            Select-Object -ExpandProperty ProfileImagePath)
        
        $copyCount = 0
        foreach ($profilePath in $userProfiles) {
            $destPath = "$profilePath\AppData\Local\imab.dk-TEST"
            if (-not (Test-Path $destPath)) {
                New-Item -Path $destPath -ItemType Directory -Force | Out-Null
            }
            Copy-Item -Path $testSourceFile -Destination "$destPath\test-config.json" -Force
            $copyCount++
        }
        Write-TestResult -TestName "Multi-profile file copy" -Passed ($copyCount -eq $userProfiles.Count) `
            -Details "Copied to $copyCount profile(s)"
    }
    else {
        # Copy to current user only
        $destPath = "$env:LOCALAPPDATA\imab.dk-TEST"
        if (-not (Test-Path $destPath)) {
            New-Item -Path $destPath -ItemType Directory -Force | Out-Null
        }
        Copy-Item -Path $testSourceFile -Destination "$destPath\test-config.json" -Force
        Write-TestResult -TestName "User file copy" -Passed (Test-Path "$destPath\test-config.json") `
            -Details "$destPath\test-config.json"
    }
}
catch {
    Write-TestResult -TestName "File operations" -Passed $false -Details $_.Exception.Message
}

# ============================================================================
# TEST 6: Admin-Required Operations (permission handling)
# ============================================================================
Write-Host "`n--- Test 6: Admin-Required Operations ---" -ForegroundColor Yellow

# Test HKLM write without admin
if (-not $isAdmin) {
    try {
        $testAdminRegPath = "HKLM:\SOFTWARE\imab.dk-TEST-NOADMIN"
        New-Item -Path $testAdminRegPath -Force -ErrorAction Stop | Out-Null
        # If we get here, something is wrong - this should fail
        Write-TestResult -TestName "HKLM write (no admin)" -Passed $false -Details "Unexpectedly succeeded - security issue?"
        Remove-Item -Path $testAdminRegPath -Force -ErrorAction SilentlyContinue
    }
    catch {
        $isAccessDenied = $_.Exception.Message -match "Access.*denied|UnauthorizedAccess|PermissionDenied|Requested registry access"
        Write-TestResult -TestName "HKLM write blocked (no admin)" -Passed $isAccessDenied `
            -Details $(if ($isAccessDenied) { "Correctly blocked" } else { $_.Exception.Message })
    }
}
else {
    Write-Host "       [SKIP] Running as admin - cannot test permission denial" -ForegroundColor DarkYellow
}

# Test Program Files write without admin
if (-not $isAdmin) {
    try {
        $testAdminFilePath = "$env:ProgramFiles\imab.dk-TEST"
        New-Item -Path $testAdminFilePath -ItemType Directory -Force -ErrorAction Stop | Out-Null
        # If we get here, something is wrong
        Write-TestResult -TestName "Program Files write (no admin)" -Passed $false -Details "Unexpectedly succeeded"
        Remove-Item -Path $testAdminFilePath -Force -ErrorAction SilentlyContinue
    }
    catch {
        $isAccessDenied = $_.Exception.Message -match "Access.*denied|UnauthorizedAccess|PermissionDenied"
        Write-TestResult -TestName "Program Files write blocked (no admin)" -Passed $isAccessDenied `
            -Details $(if ($isAccessDenied) { "Correctly blocked" } else { $_.Exception.Message })
    }
}
else {
    Write-Host "       [SKIP] Running as admin - cannot test permission denial" -ForegroundColor DarkYellow
}

# ============================================================================
# TEST 7: Template Script Syntax Check
# ============================================================================
Write-Host "`n--- Test 7: Template Script Syntax Check ---" -ForegroundColor Yellow

$installScript = Join-Path $PSScriptRoot "Intune-Win32-PowerShell-Script-Installer-Template-Install.ps1"
$uninstallScript = Join-Path $PSScriptRoot "Intune-Win32-PowerShell-Script-Installer-Template-Uninstall.ps1"

foreach ($scriptPath in @($installScript, $uninstallScript)) {
    if (Test-Path $scriptPath) {
        try {
            $tokens = $null
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
            $scriptName = Split-Path $scriptPath -Leaf
            Write-TestResult -TestName "Syntax: $scriptName" -Passed (@($errors).Count -eq 0) `
                -Details $(if (@($errors).Count -gt 0) { $errors[0].Message } else { "No syntax errors" })
        }
        catch {
            Write-TestResult -TestName "Syntax: $(Split-Path $scriptPath -Leaf)" -Passed $false -Details $_.Exception.Message
        }
    }
    else {
        Write-TestResult -TestName "Syntax: $(Split-Path $scriptPath -Leaf)" -Passed $false -Details "File not found"
    }
}

# ============================================================================
# CLEANUP
# ============================================================================
if (-not $SkipCleanup) {
    Write-Host "`n--- Cleanup ---" -ForegroundColor Yellow
    
    # Remove HKLM test key (only if admin)
    if ($isAdmin -and (Test-Path $testRegPath)) {
        Remove-Item -Path $testRegPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "       Removed: $testRegPath" -ForegroundColor Gray
    }
    
    # Remove HKCU/HKU test keys
    if ($isSystem) {
        $userProfiles = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" |
            Where-Object { $_.PSChildName -match "^S-1-(5-21|12-1)-" -and (Test-Path $_.ProfileImagePath) }
        foreach ($userProfile in $userProfiles) {
            $sid = $userProfile.PSChildName
            $hivePath = "Registry::HKEY_USERS\$sid\$testHkcuPath"
            if (Test-Path $hivePath) {
                Remove-Item -Path $hivePath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        Write-Host "       Removed: HKU\*\$testHkcuPath" -ForegroundColor Gray
    }
    else {
        $hkcuFullPath = "HKCU:\$testHkcuPath"
        if (Test-Path $hkcuFullPath) {
            Remove-Item -Path $hkcuFullPath -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "       Removed: $hkcuFullPath" -ForegroundColor Gray
        }
    }
    
    # Remove test files
    if (Test-Path $testSourceFile) {
        Remove-Item -Path $testSourceFile -Force -ErrorAction SilentlyContinue
        Write-Host "       Removed: $testSourceFile" -ForegroundColor Gray
    }
    
    if ($isSystem) {
        $userProfiles = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" |
            Where-Object { $_.PSChildName -match "^S-1-(5-21|12-1)-" -and (Test-Path $_.ProfileImagePath) } |
            Select-Object -ExpandProperty ProfileImagePath
        foreach ($profilePath in $userProfiles) {
            $testDir = "$profilePath\AppData\Local\imab.dk-TEST"
            if (Test-Path $testDir) {
                Remove-Item -Path $testDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        Write-Host "       Removed: %LOCALAPPDATA%\imab.dk-TEST (all profiles)" -ForegroundColor Gray
    }
    else {
        $testDir = "$env:LOCALAPPDATA\imab.dk-TEST"
        if (Test-Path $testDir) {
            Remove-Item -Path $testDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "       Removed: $testDir" -ForegroundColor Gray
        }
    }
}
else {
    Write-Host "`n--- Cleanup skipped (-SkipCleanup) ---" -ForegroundColor Yellow
}

# ============================================================================
# SUMMARY
# ============================================================================
Write-Host "`n=== Test Summary ===" -ForegroundColor Cyan

$passed = @($TestResults | Where-Object { $_.Passed }).Count
$failed = @($TestResults | Where-Object { -not $_.Passed }).Count
$total = $TestResults.Count

$summaryColor = if ($failed -eq 0) { "Green" } elseif ($failed -lt $total) { "Yellow" } else { "Red" }
Write-Host "Passed: $passed / $total" -ForegroundColor $summaryColor

if ($failed -gt 0) {
    Write-Host "`nFailed tests:" -ForegroundColor Red
    $TestResults | Where-Object { -not $_.Passed } | ForEach-Object {
        Write-Host "  - $($_.Test): $($_.Details)" -ForegroundColor Red
    }
}

Write-Host "`nTo test as SYSTEM context, run:" -ForegroundColor Cyan
Write-Host '  PsExec.exe -s -i powershell.exe -ExecutionPolicy Bypass -File "' + $MyInvocation.MyCommand.Path + '"' -ForegroundColor Gray

exit $(if ($failed -eq 0) { 0 } else { 1 })
