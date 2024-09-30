<#
    .SYNOPSIS
    Get-MFAReport.ps1

    .DESCRIPTION
    Display Microsoft 365 per-user MFA report with Microsoft Graph PowerShell.

    .NOTES
    Based on script by: ALI TAJRAN www.alitajran.com
#>

# Connect to Microsoft Graph with the required scopes
Connect-MgGraph -Scopes "User.Read.All", "Policy.ReadWrite.AuthenticationMethod", "UserAuthenticationMethod.Read.All" -NoWelcome

# Get properties
$Properties = @(
    'Id',
    'DisplayName',
    'UserPrincipalName',
    'UserType',
    'Mail',
    'ProxyAddresses',
    'AccountEnabled',
    'CreatedDateTime'
)

# Get all users
[array]$Users = Get-MgUser -All -Property $Properties | Select-Object $Properties

# Initialize the report list
$Report = [System.Collections.Generic.List[PSCustomObject]]::new()

# Check if any users were retrieved
if (-not $Users) {
    Write-Error "No users found. Exiting script."
    return
}

# Initialize progress counter
$counter = 0
$totalUsers = $Users.Count

# Loop through each user and get their MFA settings
foreach ($User in $Users) {
    $counter++

    # Calculate percentage completion
    $percentComplete = [math]::Round(($counter / $totalUsers) * 100)

    # Define progress bar parameters with user principal name
    $progressParams = @{
        Activity        = "Processing Users"
        Status          = "User $($counter) of $totalUsers - $($User.UserPrincipalName) - $percentComplete% Complete"
        PercentComplete = $percentComplete
    }

    Write-Progress @progressParams

    # Get MFA settings
    $MFAStateUri = "https://graph.microsoft.com/beta/users/$($User.Id)/authentication/requirements"
    $Data = Invoke-MgGraphRequest -Uri $MFAStateUri -Method GET

    # Get the default MFA method
    $DefaultMFAUri = "https://graph.microsoft.com/beta/users/$($User.Id)/authentication/signInPreferences"
    $DefaultMFAMethod = Invoke-MgGraphRequest -Uri $DefaultMFAUri -Method GET

    # Determine the MFA default method
    if ($DefaultMFAMethod.userPreferredMethodForSecondaryAuthentication) {
        $MFAMethod = $DefaultMFAMethod.userPreferredMethodForSecondaryAuthentication
        Switch ($MFAMethod) {
            "push" { $MFAMethod = "Microsoft authenticator app" }
            "oath" { $MFAMethod = "Authenticator app or hardware token" }
            "voiceMobile" { $MFAMethod = "Mobile phone" }
            "voiceAlternateMobile" { $MFAMethod = "Alternate mobile phone" }
            "voiceOffice" { $MFAMethod = "Office phone" }
            "sms" { $MFAMethod = "SMS" }
            Default { $MFAMethod = "Unknown method" }
        }
    }
    else {
        $MFAMethod = "Not Enabled"
    }

    # Filter only the aliases
    $Aliases = ($User.ProxyAddresses | Where-Object { $_ -clike "smtp*" } | ForEach-Object { $_ -replace "smtp:", "" }) -join ', '

    # Create a report line for each user
    $ReportLine = [PSCustomObject][ordered]@{
        UserPrincipalName = $User.UserPrincipalName
        DisplayName       = $User.DisplayName
        MFAState          = $Data.PerUserMfaState
        MFADefaultMethod  = $MFAMethod
        PrimarySMTP       = $User.Mail
        Aliases           = $Aliases
        UserType          = $User.UserType
        AccountEnabled    = $User.AccountEnabled
        CreatedDateTime   = $User.CreatedDateTime
    }
    $Report.Add($ReportLine)
}

# Complete the progress bar
Write-Progress -Activity "Processing Users" -Completed

# Return the report
$Report