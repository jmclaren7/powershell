$appName = "Application Name"

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
