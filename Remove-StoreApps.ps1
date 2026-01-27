$apps = @(
    "#Microsoft.WindowsStore"
    "Clipchamp.Clipchamp"#CT
    "Microsoft.3DBuilder"
    "Microsoft.549981C3F5F10"#Cortana
    "Microsoft.BingFinance"
    "Microsoft.BingFoodAndDrink"
    "Microsoft.BingHealthAndFitness"
    "Microsoft.BingNews"
    "Microsoft.BingSearch"#CT
    "Microsoft.BingSports"
    "Microsoft.BingTranslator"
    "Microsoft.BingTravel"
    "Microsoft.BingWeather"
    "Microsoft.CommsPhone"
    "Microsoft.Edge.GameAssist"#Testing
    "Microsoft.GamingApp"#CT
    "Microsoft.GetHelp"
    "Microsoft.Getstarted"
    "Microsoft.Microsoft3DViewer"#CT
    "Microsoft.MicrosoftOfficeHub"
    "Microsoft.MicrosoftSolitaireCollection"
    "Microsoft.MicrosoftStickyNotes"#CT
    "Microsoft.MixedReality.Portal"
    "Microsoft.MSPaint"#CT
    "Microsoft.Office.OneNote"#CT
    "Microsoft.OutlookForWindows"#CT
    "Microsoft.Paint"#Testing
    "Microsoft.People"
    "Microsoft.PowerAutomateDesktop"#CT
    "Microsoft.ScreenSketch"#Testing
    "Microsoft.SkypeApp"#CT
    "Microsoft.Todos"#CT
    "Microsoft.Windows.DevHome"#CT
    "Microsoft.WindowsAlarms"#CT
    "Microsoft.WindowsCalculator"#Testing
    "Microsoft.WindowsCamera"#CT
    "microsoft.windowscommunicationsapps"#Mail
    "Microsoft.Copilot"#Testing
    "Microsoft.WindowsFeedbackHub"
    "Microsoft.WindowsMaps"
    "Microsoft.WindowsNotepad"#CT
    "Microsoft.WindowsPhone"
    "Microsoft.Windows.Photos"#Testing
    "Microsoft.WindowsSoundRecorder"#CT
    "Microsoft.Xbox.TCUI"#CT
    "Microsoft.XboxApp"#CT
    "Microsoft.XboxGameOverlay"#CT
    "Microsoft.XboxGamingOverlay"#CT
    "Microsoft.XboxSpeechToTextOverlay"#CT
    "Microsoft.YourPhone"
    "Microsoft.ZuneMusic"#Groove Music
    "Microsoft.ZuneVideo"#Movies & TV
    "MicrosoftCorporationII.MicrosoftFamily"#CT
    "MicrosoftCorporationII.QuickAssist"#CT
    "MSTeams"#CT
)

# Special case for OneDrive
Write-Host "Uninstalling OneDrive"
try {
    $oneDriveExe = Join-Path $env:WinDir 'System32\OneDriveSetup.exe'
    Write-Host "    Uninstalling OneDrive using $oneDriveExe"
    $proc = Start-Process -FilePath $oneDriveExe -ArgumentList '/uninstall' -NoNewWindow -Wait -PassThru -ErrorAction Stop
    if ($proc.ExitCode -eq 0) {
        Write-Host "    OneDrive uninstalled" -ForegroundColor Green
    }
    else {
        Write-Host "    OneDrive uninstall exited with code $($proc.ExitCode)" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "    Failed to uninstall OneDrive: $($_.Exception.Message -replace '\s+', ' ')" -ForegroundColor Red
}


# Remove Store Apps
foreach ($app in $apps) {
    Write-Host "Removing $app"

    # Remove AppxPackage
    try {
        $package = Get-AppxPackage -Name $app -AllUsers -ErrorAction Stop
    }
    catch {
        Write-Host "    Error retrieving AppxPackage: $($_.Exception.Message -replace '\s+', ' ')" -ForegroundColor Yellow
    }

    if ($package) {
        try {
            $package | Remove-AppxPackage -AllUsers -ErrorAction Stop
            Write-Host "    Removed AppxPackage" -ForegroundColor Green
        }
        catch {
            Write-Host "    Failed to remove AppxPackage: $($_.Exception.Message -replace '\s+', ' ')" -ForegroundColor Red
        }
    }
    else {
        Write-Host "    AppxPackage not found"
    }

    # Remove AppxProvisionedPackage
    try {
        $provisioned = Get-AppXProvisionedPackage -Online -ErrorAction Stop | Where-Object DisplayName -Match $app
    }
    catch {
        Write-Host "    Error retrieving AppxProvisionedPackage: $($_.Exception.Message -replace '\s+', ' ')" -ForegroundColor Yellow
    }
    
    if ($provisioned) {
        try {
            $provisioned | Remove-AppxProvisionedPackage -Online -ErrorAction Stop
            Write-Host "    Removed AppxProvisionedPackage" -ForegroundColor Green
        }
        catch {
            Write-Host "    Failed to remove AppxProvisionedPackage: $($_.Exception.Message -replace '\s+', ' ')" -ForegroundColor Red
        }
    }
    else {
        Write-Host "    AppxProvisionedPackage not found"
    }
}







$appName = "Microsoft OneDrive"

$Paths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
$App = Get-ItemProperty $Paths -EA SilentlyContinue | Where-Object { $_.DisplayName -match $appName } | Select-Object -First 1
If ($App) { 
    cmd /c $App.UninstallString /passive /norestart 
} else { 
    Write-Output "$appName is not installed." 
}
