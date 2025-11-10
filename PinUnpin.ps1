


$Pin_QuickAccess = @( # Folders/drives to pin to Quick Access
    "C:\"
)

$Unpin_QuickAccess = @( # Folders/drives to unpin from Quick Access
    "C:\"
)

$SearchBoxTaskbarMode = 0 # 0=hidden, 1=icon, 2=large



$Pin_Taskbar_Win32 = @( # Win32 apps to pin to taskbar using the full path
    #"C:\Program Files\Google\Chrome\Application\chrome.exe"
)

$Unpin_Taskbar = @( # App or executable name (no extension) to unpin from taskbar
    "Microsoft Store",
    "Microsoft Edge",
    "grepWin"
)

# Set Search Bar Mode
Set-ItemProperty -Path HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search -Name SearchBoxTaskbarMode -Value $SearchBoxTaskbarMode -Type DWord -Force

# Set up
$shellApplication = New-Object -ComObject Shell.Application
$QuickAccessNamespaceId = 'shell:::{679f85cb-0220-4080-b29b-5540cc05aab6}'
$quickAccess = $shellApplication.Namespace($QuickAccessNamespaceId)

# Pin To Quick Access
Foreach ($thisApp in $Pin_QuickAccess){
    If(Test-Path -Path $thisApp -PathType Container){
        # If not already pinned
        If(-Not ($quickAccess.Items() | Where-Object { $_.Path -eq $thisApp -or $_.Name -eq $thisApp })) {
            Write-Host "Pinning $thisApp to Quick Access"
            $shellApplication.Namespace($thisApp).Self.InvokeVerb("pintohome")
        }
    }
}

# Unpin From Quick Access
Foreach ($thisApp in $Unpin_QuickAccess){
    foreach ($item in $quickAccess.Items() | Where-Object { $_.Path -eq $thisApp -or $_.Name -eq $thisApp }){
        Write-Host "Unpinning $thisApp from Quick Access"
        $item.InvokeVerb("unpinfromhome")
    }
}

# Pin Win32 To Taskbar (requires pttb.exe)
$PTTB_Exe = "$PSScriptRoot\pttb.exe"
if (Get-Item -Path $PTTB_Exe -ErrorAction Ignore) {
    Foreach ($thisApp in $Pin_Taskbar_Win32){
        If(Test-Path -Path $thisApp -PathType Leaf){
            $Desc = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($thisApp).FileDescription
            If(-Not (Test-Path -Path $env:APPDATA"\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\$Desc.lnk" -PathType Leaf)){
                &$PTTB_Exe $thisApp
            }
        }
     }
}

# Unpin App From Taskbar
$TaskbarNamespaceId = 'shell:::{4234d49b-0245-4df3-b780-3893943456e1}'
$taskbarNamespace = $shellApplication.NameSpace($TaskbarNamespaceId)
if ($taskbarNamespace) {
    foreach ($thisApp in $Unpin_Taskbar) {
        $thisApp
        $taskbarItems = $taskbarNamespace.Items() |
            Where-Object { $_.Name -eq $thisApp }

        foreach ($item in $taskbarItems) {
            $item.Verbs()
            $item.Verbs() |
                Where-Object { $_.Name.Replace('&', '') -match 'Unpin from taskbar' } |
                ForEach-Object {
                    $_.DoIt()
                    $script:exec = $true
                }
        }
    }
}