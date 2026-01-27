<#
.SYNOPSIS
    Disables Active Directory users who have been inactive for a specified number of days.

.DESCRIPTION
    This script identifies and disables AD users who haven't logged in for X days,
    while protecting users who are members of specified exclusion groups.
    
    Features:
    - Configurable inactivity threshold (days)
    - Group-based exclusion list to protect specific users
    - Dry-run mode to preview changes without making them
    - Optional OU targeting to limit scope
    - Comprehensive logging to file
    - Email notification support
    - Scheduled task installation option

.PARAMETER InactiveDays
    Number of days of inactivity before a user is considered for disabling. Default: 90

.PARAMETER ExcludedGroups
    Array of AD group names whose members should NOT be disabled. Default: Domain Admins, Enterprise Admins

.PARAMETER SearchBase
    Optional OU distinguished name to limit the search scope

.PARAMETER WhatIf
    Run in dry-run mode - shows what would happen without making changes

.PARAMETER LogPath
    Path to the log file. Default: Script directory\Disable-InactiveUsers.log

.PARAMETER SendEmail
    Enable email notifications for disabled users

.PARAMETER SmtpServer
    SMTP server for sending email notifications

.PARAMETER EmailFrom
    Sender email address for notifications

.PARAMETER EmailTo
    Recipient email address(es) for notifications

.PARAMETER Install
    Creates a scheduled task to run this script daily at the specified time

.PARAMETER Uninstall
    Removes the scheduled task created by -Install

.PARAMETER TaskTime
    Time to run the scheduled task. Default: 21:00 (9 PM)

.EXAMPLE
    .\Disable-InactiveUsers.ps1 -InactiveDays 90 -WhatIf
    Preview users that would be disabled after 90 days of inactivity

.EXAMPLE
    .\Disable-InactiveUsers.ps1 -InactiveDays 60 -ExcludedGroups "Domain Admins","VIP Users","Service Accounts"
    Disable users inactive for 60 days, excluding members of specified groups

.EXAMPLE
    .\Disable-InactiveUsers.ps1 -Install -TaskTime "21:00"
    Install scheduled task to run daily at 9 PM

.NOTES
    Author: Generated Script
    Requires: ActiveDirectory PowerShell module
    Requires: Run as administrator for scheduled task installation
#>

[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Run')]
param(
    # Number of days of inactivity before disabling a user
    [Parameter(ParameterSetName = 'Run')]
    [ValidateRange(1, 365)]
    [int]$InactiveDays = 90,

    # Groups whose members should be excluded from being disabled
    [Parameter(ParameterSetName = 'Run')]
    [string[]]$ExcludedGroups = @("Domain Admins", "Enterprise Admins"),

    # Optional: Limit search to specific OU
    [Parameter(ParameterSetName = 'Run')]
    [string]$SearchBase,

    # Path for log file output
    [Parameter(ParameterSetName = 'Run')]
    [string]$LogPath = (Join-Path $PSScriptRoot "Disable-InactiveUsers.log"),

    # Enable email notifications
    [Parameter(ParameterSetName = 'Run')]
    [switch]$SendEmail,

    # SMTP server for email notifications
    [Parameter(ParameterSetName = 'Run')]
    [string]$SmtpServer,

    # Email sender address
    [Parameter(ParameterSetName = 'Run')]
    [string]$EmailFrom,

    # Email recipient address(es)
    [Parameter(ParameterSetName = 'Run')]
    [string[]]$EmailTo,

    # Install as a scheduled task
    [Parameter(ParameterSetName = 'Install')]
    [switch]$Install,

    # Uninstall the scheduled task
    [Parameter(ParameterSetName = 'Uninstall')]
    [switch]$Uninstall,

    # Time to run the scheduled task (default 9 PM)
    [Parameter(ParameterSetName = 'Install')]
    [string]$TaskTime = "21:00",

    # Additional arguments to pass to the scheduled task
    [Parameter(ParameterSetName = 'Install')]
    [string]$TaskArguments = ""
)

#region Helper Functions

function Write-Log {
    <#
    .SYNOPSIS
        Writes a message to both console and log file with timestamp
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    
    # Create timestamp for log entry
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Write to console with appropriate color
    switch ($Level) {
        'Info'    { Write-Host $logMessage -ForegroundColor Cyan }
        'Warning' { Write-Host $logMessage -ForegroundColor Yellow }
        'Error'   { Write-Host $logMessage -ForegroundColor Red }
        'Success' { Write-Host $logMessage -ForegroundColor Green }
    }
    
    # Append to log file
    try {
        Add-Content -Path $LogPath -Value $logMessage -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to write to log file: $_"
    }
}

function Get-ExcludedUsersList {
    <#
    .SYNOPSIS
        Retrieves all users who are members of the excluded groups
    #>
    param(
        [string[]]$Groups
    )
    
    $excludedUsers = @()
    
    foreach ($groupName in $Groups) {
        try {
            # Get all members of the exclusion group (including nested groups)
            $members = Get-ADGroupMember -Identity $groupName -Recursive -ErrorAction Stop |
                       Where-Object { $_.objectClass -eq 'user' }
            
            $excludedUsers += $members.SamAccountName
            Write-Log "Found $($members.Count) users in exclusion group: $groupName" -Level Info
        }
        catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
            Write-Log "Exclusion group not found: $groupName" -Level Warning
        }
        catch {
            Write-Log "Error retrieving members from group '$groupName': $_" -Level Error
        }
    }
    
    # Return unique list of excluded users
    return $excludedUsers | Select-Object -Unique
}

function Send-NotificationEmail {
    <#
    .SYNOPSIS
        Sends an email notification with the list of disabled users
    #>
    param(
        [array]$DisabledUsers,
        [string]$Server,
        [string]$From,
        [string[]]$To
    )
    
    if ($DisabledUsers.Count -eq 0) {
        return
    }
    
    # Build the email body with a summary table
    $body = @"
<html>
<head>
<style>
    body { font-family: Arial, sans-serif; }
    table { border-collapse: collapse; width: 100%; }
    th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
    th { background-color: #4472C4; color: white; }
    tr:nth-child(even) { background-color: #f2f2f2; }
    .summary { background-color: #E7E6E6; padding: 10px; margin-bottom: 20px; }
</style>
</head>
<body>
<h2>Inactive User Account Disablement Report</h2>
<div class="summary">
    <p><strong>Date:</strong> $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</p>
    <p><strong>Total Users Disabled:</strong> $($DisabledUsers.Count)</p>
</div>
<table>
<tr>
    <th>Username</th>
    <th>Display Name</th>
    <th>Last Logon</th>
    <th>Days Inactive</th>
</tr>
$(foreach ($user in $DisabledUsers) {
    "<tr><td>$($user.SamAccountName)</td><td>$($user.DisplayName)</td><td>$($user.LastLogonDate)</td><td>$($user.DaysInactive)</td></tr>"
})
</table>
</body>
</html>
"@

    try {
        $mailParams = @{
            SmtpServer = $Server
            From       = $From
            To         = $To
            Subject    = "Inactive Users Disabled - $(Get-Date -Format 'yyyy-MM-dd') - $($DisabledUsers.Count) accounts"
            Body       = $body
            BodyAsHtml = $true
        }
        
        Send-MailMessage @mailParams
        Write-Log "Email notification sent successfully to: $($To -join ', ')" -Level Success
    }
    catch {
        Write-Log "Failed to send email notification: $_" -Level Error
    }
}

function Install-ScheduledTask {
    <#
    .SYNOPSIS
        Creates a scheduled task to run this script automatically
    #>
    param(
        [string]$ScriptPath,
        [string]$Time,
        [string]$Arguments
    )
    
    $taskName = "Disable-InactiveUsers"
    
    # Check if running as administrator
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    
    if (-not $isAdmin) {
        Write-Log "Administrator privileges required to install scheduled task. Please run as administrator." -Level Error
        return $false
    }
    
    try {
        # Remove existing task if it exists
        $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existingTask) {
            Write-Log "Removing existing scheduled task: $taskName" -Level Info
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }
        
        # Build the PowerShell command to execute the script
        $scriptArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
        if ($Arguments) {
            $scriptArgs += " $Arguments"
        }
        
        # Create the scheduled task action
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $scriptArgs
        
        # Create a daily trigger at the specified time
        $trigger = New-ScheduledTaskTrigger -Daily -At $Time
        
        # Set the task to run with highest privileges using SYSTEM account
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        
        # Configure task settings
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable
        
        # Register the scheduled task
        Register-ScheduledTask -TaskName $taskName `
                               -Action $action `
                               -Trigger $trigger `
                               -Principal $principal `
                               -Settings $settings `
                               -Description "Automatically disables AD users who have been inactive for the configured number of days."
        
        Write-Log "Scheduled task '$taskName' created successfully!" -Level Success
        Write-Log "Task will run daily at $Time" -Level Info
        Write-Log "Script path: $ScriptPath" -Level Info
        
        return $true
    }
    catch {
        Write-Log "Failed to create scheduled task: $_" -Level Error
        return $false
    }
}

function Uninstall-ScheduledTask {
    <#
    .SYNOPSIS
        Removes the scheduled task created by Install-ScheduledTask
    #>
    
    $taskName = "Disable-InactiveUsers"
    
    # Check if running as administrator
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    
    if (-not $isAdmin) {
        Write-Log "Administrator privileges required to uninstall scheduled task. Please run as administrator." -Level Error
        return $false
    }
    
    try {
        $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        
        if ($existingTask) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-Log "Scheduled task '$taskName' removed successfully!" -Level Success
            return $true
        }
        else {
            Write-Log "Scheduled task '$taskName' not found." -Level Warning
            return $false
        }
    }
    catch {
        Write-Log "Failed to remove scheduled task: $_" -Level Error
        return $false
    }
}

#endregion

#region Main Script Logic

# Handle Install parameter set
if ($Install) {
    $scriptPath = $MyInvocation.MyCommand.Path
    Write-Log "Installing scheduled task..." -Level Info
    Install-ScheduledTask -ScriptPath $scriptPath -Time $TaskTime -Arguments $TaskArguments
    exit
}

# Handle Uninstall parameter set
if ($Uninstall) {
    Write-Log "Uninstalling scheduled task..." -Level Info
    Uninstall-ScheduledTask
    exit
}

# Verify Active Directory module is available
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Log "ActiveDirectory PowerShell module is not installed. Please install RSAT tools." -Level Error
    exit 1
}

# Import the Active Directory module
try {
    Import-Module ActiveDirectory -ErrorAction Stop
    Write-Log "ActiveDirectory module loaded successfully" -Level Info
}
catch {
    Write-Log "Failed to import ActiveDirectory module: $_" -Level Error
    exit 1
}

# Initialize script execution
Write-Log "========================================" -Level Info
Write-Log "Starting Inactive User Cleanup Process" -Level Info
Write-Log "========================================" -Level Info
Write-Log "Inactivity Threshold: $InactiveDays days" -Level Info
Write-Log "Excluded Groups: $($ExcludedGroups -join ', ')" -Level Info

if ($WhatIf) {
    Write-Log "*** RUNNING IN WHATIF MODE - NO CHANGES WILL BE MADE ***" -Level Warning
}

# Calculate the cutoff date for inactivity
$cutoffDate = (Get-Date).AddDays(-$InactiveDays)
Write-Log "Cutoff date for last logon: $($cutoffDate.ToString('yyyy-MM-dd'))" -Level Info

# Build the list of users to exclude (members of protected groups)
Write-Log "Building exclusion list from protected groups..." -Level Info
$excludedUsers = Get-ExcludedUsersList -Groups $ExcludedGroups
Write-Log "Total excluded users: $($excludedUsers.Count)" -Level Info

# Build AD search parameters
$adParams = @{
    Filter     = { Enabled -eq $true -and LastLogonDate -lt $cutoffDate }
    Properties = @('LastLogonDate', 'DisplayName', 'Description', 'WhenCreated', 'DistinguishedName')
}

# Add SearchBase if specified
if ($SearchBase) {
    $adParams.SearchBase = $SearchBase
    Write-Log "Search scope limited to: $SearchBase" -Level Info
}

# Query for inactive users
Write-Log "Searching for inactive users..." -Level Info
try {
    $inactiveUsers = Get-ADUser @adParams
    Write-Log "Found $($inactiveUsers.Count) users inactive for more than $InactiveDays days" -Level Info
}
catch {
    Write-Log "Failed to query Active Directory: $_" -Level Error
    exit 1
}

# Process each inactive user
$disabledUsers = @()
$skippedUsers = @()

foreach ($user in $inactiveUsers) {
    # Check if user is in the exclusion list
    if ($excludedUsers -contains $user.SamAccountName) {
        Write-Log "SKIPPED (protected): $($user.SamAccountName) - Member of excluded group" -Level Warning
        $skippedUsers += $user
        continue
    }
    
    # Calculate days since last logon
    $daysInactive = if ($user.LastLogonDate) {
        [math]::Round(((Get-Date) - $user.LastLogonDate).TotalDays)
    } else {
        "Never"
    }
    
    # Attempt to disable the user
    if ($PSCmdlet.ShouldProcess($user.SamAccountName, "Disable user account (inactive for $daysInactive days)")) {
        try {
            # Disable the user account
            Disable-ADAccount -Identity $user.SamAccountName -ErrorAction Stop
            
            # Update the user's description to document the disablement
            $newDescription = "Disabled by automation on $(Get-Date -Format 'yyyy-MM-dd') - Inactive for $daysInactive days. Previous: $($user.Description)"
            Set-ADUser -Identity $user.SamAccountName -Description $newDescription -ErrorAction Stop
            
            Write-Log "DISABLED: $($user.SamAccountName) ($($user.DisplayName)) - Inactive for $daysInactive days" -Level Success
            
            # Add to disabled users list for reporting
            $disabledUsers += [PSCustomObject]@{
                SamAccountName = $user.SamAccountName
                DisplayName    = $user.DisplayName
                LastLogonDate  = $user.LastLogonDate
                DaysInactive   = $daysInactive
                DN             = $user.DistinguishedName
            }
        }
        catch {
            Write-Log "FAILED to disable $($user.SamAccountName): $_" -Level Error
        }
    }
    else {
        # WhatIf mode - just log what would happen
        Write-Log "WOULD DISABLE: $($user.SamAccountName) ($($user.DisplayName)) - Inactive for $daysInactive days" -Level Info
        
        $disabledUsers += [PSCustomObject]@{
            SamAccountName = $user.SamAccountName
            DisplayName    = $user.DisplayName
            LastLogonDate  = $user.LastLogonDate
            DaysInactive   = $daysInactive
            DN             = $user.DistinguishedName
        }
    }
}

# Summary
Write-Log "========================================" -Level Info
Write-Log "Processing Complete" -Level Info
Write-Log "========================================" -Level Info
Write-Log "Users Disabled: $($disabledUsers.Count)" -Level Info
Write-Log "Users Skipped (Protected): $($skippedUsers.Count)" -Level Info

# Send email notification if configured
if ($SendEmail -and $SmtpServer -and $EmailFrom -and $EmailTo) {
    if (-not $WhatIf) {
        Send-NotificationEmail -DisabledUsers $disabledUsers -Server $SmtpServer -From $EmailFrom -To $EmailTo
    }
    else {
        Write-Log "Email notification skipped in WhatIf mode" -Level Info
    }
}

# Output disabled users to pipeline for further processing
if ($disabledUsers.Count -gt 0) {
    $disabledUsers
}

#endregion
