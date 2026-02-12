# Intune Win32 PowerShell Installer Blog Post - Planning Notes

**Date:** February 10, 2026

## Documentation Source
https://learn.microsoft.com/en-us/intune/intune-service/apps/apps-win32-app-management

## Project Overview
Planning a blog post about the new PowerShell script installer feature for Win32 apps in Microsoft Intune.

## Initial Idea
Write about using PowerShell to:
- Install a given app
- Copy a file to the user profile (e.g., a config file)

## Key Feature Details from Documentation

### PowerShell Script Installer
When adding a Win32 app, you can upload a PowerShell script to serve as the installer instead of specifying a command line. Intune packages the script with the app content and runs it in the same context as the app installer.

**Script Requirements:**
- Scripts are limited to 50 KB in size
- Scripts run in the same context as the app installer (system or user context)
- Return codes from the script determine installation success or failure status
- Scripts should run silently without user interaction

**When to use script installers:**
- Your app requires prerequisite validation before installation
- You need to perform configuration changes alongside app installation
- The installation process requires conditional logic
- Post-installation actions are needed (like registry modifications or service configuration)

### Multi-Admin Approval (MAA) Note
If Multi-Admin Approval is enabled for your tenant, you can't upload PowerShell scripts during app creation. You must first create the app, then add or modify scripts afterward.

## Blog Post Content Suggestions

### 1. Core PowerShell Installer Concepts
- Script requirements (50KB limit, silent execution, return codes)
- Context awareness (system vs user context)
- When to use script installers vs traditional command-line installers

### 2. Practical Use Cases & Examples

Beyond the config file idea:
- **Prerequisite validation** - Check if required .NET version, disk space, or dependencies exist before installation
- **Conditional installation logic** - Install different components based on device properties (laptop vs desktop, OS version, domain membership)
- **Post-installation configuration** - Registry modifications, service configuration, creating scheduled tasks
- **Custom logging** - Enhanced logging beyond standard installer logs for troubleshooting
- **Cleanup operations** - Remove conflicting software or legacy configurations before installing

### 3. Real-World Scenarios
- **Multi-step installations** requiring specific sequencing
- **Custom MSI transformations** or modifications during deployment
- **Installing portable applications** that don't have traditional installers
- **Deploying configuration alongside applications** (like the user profile config example)

### 4. Best Practices Section
- Return code handling for proper status reporting to Intune
- Error handling and rollback strategies
- Testing scripts in different contexts (System vs User)
- Script signing considerations (especially with Multi-Admin Approval enabled)

### 5. Comparison Content
- **Script installer vs traditional install command** - When to choose which
- **Advantages over packaging everything in setup.exe**
- Migration path from Configuration Manager scripts

### 6. Troubleshooting & Limitations
- The 50KB script size limitation and workarounds
- Silent installation requirements (no user interaction)
- Multi-Admin Approval (MAA) considerations
- IME agent behavior and timing

### 7. Integration Topics
- Using with **dependency and supersedence features**
- Combining with **detection rules** for validation
- Interaction with **delivery optimization**

### 8. Code Examples to Include
```powershell
# Environment validation before installation
# Installing and configuring in one workflow
# Registry configuration post-install
# User profile customization (original idea)
# Dynamic parameter passing based on device context
```

## Recommended Blog Structure

1. **Introduction** to the feature & why it matters
2. **Technical overview** & requirements
3. **3-4 practical examples** (including the config file scenario)
4. **Best practices** & pitfalls to avoid
5. **Troubleshooting** common issues
6. **Conclusion** with use case recommendations

## Why the User Profile Configuration Example is Valuable
The user profile configuration example is particularly valuable since it's a common real-world need that was previously difficult to handle elegantly in traditional app deployment scenarios.

## Next Steps
- Draft specific sections
- Create example PowerShell scripts
- Test examples in lab environment
- Gather screenshots from Intune admin center
