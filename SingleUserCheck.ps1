##
##
##

# Add VB assembly for message box used in logon prompt
Add-Type -AssemblyName Microsoft.VisualBasic

$Path = Get-Item $PSCommandPath
$Title = $Path.Basename

# Get a list of users with session details
Function Get-UserSessions {
    (((quser) -replace '^>', '') -replace '\s{2,}', ',').Trim() | ForEach-Object {
        if ($_.Split(',').Count -eq 5) { $_ -replace '(^[^,]+)', '$1,' } else { $_ }
    } | ConvertFrom-Csv
}


if ($args[0] -eq 'install') {

    New-EventLog -LogName Application -Source 'SingleUser' -ErrorAction 'SilentlyContinue'

    # Create scheduled task for logoff
    $Name = "$Title Logoff"
    # Remove old scheduled task
    Stop-ScheduledTask -TaskName $Name -ea 'SilentlyContinue' 
    Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ea 'SilentlyContinue' 
    $Action = New-ScheduledTaskAction -Execute 'Powershell.exe' -Argument "-NoProfile -ExecutionPolicy ByPass $Path logoff"
    $Trigger = (cimclass MSFT_TaskEventTrigger root/Microsoft/Windows/TaskScheduler) | New-CimInstance -ClientOnly
    $Trigger.Enabled = $True
    $Trigger.Subscription = '<QueryList><Query Id="0" Path="Application"><Select Path="Application">*[System[Provider[@Name=''SingleUser''] and EventID=100]]</Select></Query></QueryList>'
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -ExecutionTimeLimit 0
    $Principal = New-ScheduledTaskPrincipal -GroupId "NT AUTHORITY\SYSTEM"
    $null = Register-ScheduledTask -Action $Action -Trigger $Trigger -Settings $Settings -TaskName $Name -Principal $Principal


    # Create scheduled task for login prompt
    $Name = "$Title Logon"
    # Remove old scheduled task
    Stop-ScheduledTask -TaskName $Name -ea 'SilentlyContinue' 
    Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ea 'SilentlyContinue' 
    $Action = New-ScheduledTaskAction -Execute 'Powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy ByPass $Path logon"
    $Trigger = New-ScheduledTaskTrigger -AtLogOn
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -ExecutionTimeLimit 0
    $Principal = New-ScheduledTaskPrincipal -GroupId "BUILTIN\Users"
    $null = Register-ScheduledTask -Action $Action -Trigger $Trigger -Settings $Settings -TaskName $Name -Principal $Principal
   

}
elseif ($args[0] -eq 'logoff') {
    # Loop each disconnected session and log it off
    Get-UserSessions | Where-Object State -Match Disc | ForEach-Object {
        logoff $_.ID
    }

}
elseif ($args[0] -eq 'logon') {
    # Prompt user if they want to log off disconnected users
    If ((Get-UserSessions | Where-Object State -Match Disc | Measure-Object).Count -gt 0) {
        $msg = [Microsoft.VisualBasic.Interaction]::MsgBox("Another user is logged in on this computer, would you like to log them off?", 'YesNo,SystemModal,Question', $Title)
        if ($msg -eq 'Yes') {
            Write-EventLog -LogName "Application" -Source "SingleUser" -EventID 100 -EntryType Information -Message "$Title - Requesting log off of other users" -Category 0
        }
    }

}