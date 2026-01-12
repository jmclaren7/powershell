#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Analyzes Windows Event Log to calculate system reboot durations.
.DESCRIPTION
    Retrieves shutdown and startup events from the Windows Event Log and calculates
    the time elapsed between reboot initiation and system boot completion.
.PARAMETER Days
    Number of days of history to analyze. Default is 30.
.EXAMPLE
    .\RebootTimer.ps1 -Days 60
#>

param(
    [int]$Days = 30
)

$startDate = (Get-Date).AddDays(-30)

# Get shutdown events (Event ID 1074 from User32 - shutdown initiated)
$shutdownEvents = Get-WinEvent -FilterHashtable @{
    LogName = 'System'
    ProviderName = 'User32'
    Id = 1074
    StartTime = $startDate
} -ErrorAction SilentlyContinue | ForEach-Object {
    [PSCustomObject]@{
        Time = $_.TimeCreated
        Type = 'Shutdown'
        Message = $_.Message
    }
}

# Get startup events (Event ID 12 from Kernel-General - OS started)
$startupEvents = Get-WinEvent -FilterHashtable @{
    LogName = 'System'
    ProviderName = 'Microsoft-Windows-Kernel-General'
    Id = 12
    StartTime = $startDate
} -ErrorAction SilentlyContinue | ForEach-Object {
    [PSCustomObject]@{
        Time = $_.TimeCreated
        Type = 'Startup'
    }
}

# Also check Event ID 6005 (EventLog service started) as backup
$eventLogStartEvents = Get-WinEvent -FilterHashtable @{
    LogName = 'System'
    ProviderName = 'EventLog'
    Id = 6005
    StartTime = $startDate
} -ErrorAction SilentlyContinue | ForEach-Object {
    [PSCustomObject]@{
        Time = $_.TimeCreated
        Type = 'Startup'
    }
}

# Combine and sort all events
$allEvents = @()
if ($shutdownEvents) { $allEvents += $shutdownEvents }
if ($startupEvents) { $allEvents += $startupEvents }
if ($eventLogStartEvents) { $allEvents += $eventLogStartEvents }

$allEvents = $allEvents | Sort-Object Time

# Find shutdown/startup pairs and calculate duration
$rebootHistory = @()
$lastShutdown = $null

foreach ($event in $allEvents) {
    if ($event.Type -eq 'Shutdown') {
        $lastShutdown = $event
    }
    elseif ($event.Type -eq 'Startup' -and $lastShutdown) {
        $duration = $event.Time - $lastShutdown.Time
        
        # Only include reasonable reboot times (less than 1 hour, more than 5 seconds)
        if ($duration.TotalSeconds -gt 5 -and $duration.TotalHours -lt 1) {
            $rebootHistory += [PSCustomObject]@{
                ShutdownTime = $lastShutdown.Time
                StartupTime = $event.Time
                Duration = $duration
                DurationFormatted = '{0:mm\:ss}' -f $duration
            }
        }
        $lastShutdown = $null
    }
}

# Remove duplicates (in case both Kernel-General and EventLog startup events matched)
$rebootHistory = $rebootHistory | 
    Sort-Object ShutdownTime -Unique | 
    Sort-Object ShutdownTime -Descending

if ($rebootHistory.Count -eq 0) {
    Write-Host "No reboot events found in the last $Days days." -ForegroundColor Yellow
    return
}

Write-Host "`n=== System Reboot History (Last $Days Days) ===" -ForegroundColor Cyan
Write-Host ""

$rebootHistory | ForEach-Object {
    $color = switch ($true) {
        ($_.Duration.TotalSeconds -lt 60) { 'Green' }
        ($_.Duration.TotalSeconds -lt 180) { 'Yellow' }
        default { 'Red' }
    }
    
    Write-Host ("Shutdown: {0:yyyy-MM-dd HH:mm:ss}  |  Startup: {1:yyyy-MM-dd HH:mm:ss}  |  Duration: " -f $_.ShutdownTime, $_.StartupTime) -NoNewline
    Write-Host ("{0}" -f $_.DurationFormatted) -ForegroundColor $color
}

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan

$avgDuration = [TimeSpan]::FromSeconds(($rebootHistory | Measure-Object -Property { $_.Duration.TotalSeconds } -Average).Average)
$minDuration = $rebootHistory | Sort-Object { $_.Duration.TotalSeconds } | Select-Object -First 1
$maxDuration = $rebootHistory | Sort-Object { $_.Duration.TotalSeconds } -Descending | Select-Object -First 1

Write-Host ("Total Reboots:    {0}" -f $rebootHistory.Count)
Write-Host ("Average Duration: {0:mm\:ss}" -f $avgDuration)
Write-Host ("Fastest Reboot:   {0} ({1:yyyy-MM-dd})" -f $minDuration.DurationFormatted, $minDuration.ShutdownTime)
Write-Host ("Slowest Reboot:   {0} ({1:yyyy-MM-dd})" -f $maxDuration.DurationFormatted, $maxDuration.ShutdownTime)
Write-Host ""

# Trigger Reboot
#Start-Sleep -Seconds 15
#Restart-Computer -Force
