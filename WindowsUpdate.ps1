Set-ExecutionPolicy RemoteSigned -Force

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not (Get-PSRepository -Name "PSGallery" -ErrorAction SilentlyContinue)) {
    Write-Host "PSGallery repository not found. Registering PSGallery..." -ForegroundColor Yellow
    Register-PSRepository -Default -ErrorAction Stop
}

if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
    Install-PackageProvider -Name NuGet -Force
    Install-Module PSWindowsUpdate -Force
}
$(Get-WindowsUpdate -NotCategory Drivers -NotTitle Preview) | Select -Property KB,Title | Format-Table -AutoSize

# Ask user if they want to "install and automatically reboot" or "install and reboot at 11pm" or "Go to powershell prompt"
$installOptions = [ordered]@{
    1 = "Get-WindowsUpdate -NotCategory Drivers -NotTitle Preview -Install -AcceptAll -AutoReboot"
    2 = 'Get-WindowsUpdate -NotCategory Drivers -NotTitle Preview -Install -AcceptAll -IgnoreReboot -ScheduleReboot $(Get-Date "23:00")'
    3 = "Go to powershell prompt"
    4 = "Exit"
}

Write-Host "Select an option:" -ForegroundColor Yellow
$installOptions.GetEnumerator() | ForEach-Object { Write-Host "$($_.Key): $($_.Value)" -ForegroundColor White }

Write-Host "Press a key (1-4) to make your choice..." -ForegroundColor Cyan
$choice = [System.Console]::ReadKey($true).KeyChar




switch ($choice) {
    1 {
        Write-Host "Updating and rebooting" -ForegroundColor Cyan
        Get-WindowsUpdate -NotCategory Drivers -NotTitle Preview -Install -AcceptAll -AutoReboot
    }
    2 {
        Write-Host "Updating and scheduling reboot at 11pm" -ForegroundColor Cyan
        Get-WindowsUpdate -NotCategory Drivers -NotTitle Preview -Install -AcceptAll -IgnoreReboot -ScheduleReboot $(Get-Date "23:00")
    }
    3 {
        Write-Host "Type 'exit' to return to the script." -ForegroundColor Cyan
        $Host.EnterNestedPrompt()
    }
    default {
        exit
    }
}