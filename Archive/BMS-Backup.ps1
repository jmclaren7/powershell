$API = "https://api.bms.kaseya.com/v2"
$API_Tenant = ""
$API_UserName = ""
$API_Password = ""
$API_GrantType = "password"

# Use TLS 1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# Set location to script path
Set-Location $PSScriptRoot

# Authenticate to the API
"Authenticating"
$Body = @{
    grantType = $API_GrantType
    tenant    = $API_Tenant
    userName  = $API_UserName
    password  = $API_Password
}
$Params = @{
    Method          = "POST"
    Uri             = "$API/security/authenticate"
    Body            = $Body
    ContentType     = "application/x-www-form-urlencoded"
    UseBasicParsing = $true
}
try{
    $Request = Invoke-RestMethod @Params
}catch{
    Write-Host -ForegroundColor Red "Error at line $($_.InvocationInfo.ScriptLineNumber): $_" 
    Exit
}
$Token = $($Request.result).accessToken | ConvertTo-SecureString -AsPlainText -Force


# =================================================================================================
# =================================================================================================

# Get users
$Params = @{
    Method         = "GET"
    Uri            = "$API/hr/assignees/lookup"
    Authentication = "Bearer"
    Token          = $Token
}
try{
    $Request = Invoke-RestMethod @Params
}catch{
    Write-Host -ForegroundColor Red "Error at line $($_.InvocationInfo.ScriptLineNumber): $_" 
    Exit
}
$Users = $Request.result
"$($Users.Count) users"

# =================================================================================================
# =================================================================================================

# Get accounts
$Params = @{
    Method         = "GET"
    Uri            = "$API/crm/accounts/lookup"
    Authentication = "Bearer"
    Token          = $Token
}
try {
    $Request = Invoke-RestMethod @Params
}
catch {
    Write-Host -ForegroundColor Red "Error at line $($_.InvocationInfo.ScriptLineNumber): $_" 
    Exit
}
$Accounts = $Request.result
"$($Accounts.Count) accounts"
#$Accounts | Format-List -Property *

# =================================================================================================
# =================================================================================================

# Get summary of tickets for each account
$Tickets_Basic = @()
$PageSize = 100

$Accounts | ForEach-Object {
    $Account = $_
    "Getting tickets for $($Account.name)"

    $PageNumber = 1
    do {
        $Body = @{
            "Filter.AccountId" = $Account.id #249099 #458465
            PageSize           = $PageSize
            PageNumber         = $PageNumber
        }
        $Params = @{
            Method         = "GET"
            Uri            = "$API/servicedesk/tickets/summary"
            Body           = $Body
            Authentication = "Bearer"
            Token          = $Token
        }
        try {
            $Request = Invoke-RestMethod @Params
        }
        Catch {
            Write-Host -ForegroundColor Red "Error at line $($_.InvocationInfo.ScriptLineNumber): $_" 
            Exit
        }
        "  $($Request.result.Count) tickets found on page $PageNumber with success being $($Request.success)"
        # Add to the array
        $Tickets_Basic += $Request.result
    
        $PageNumber++

    } until (
        $Request.success -ne "true" -or $Request.result.Count -lt $PageSize
    )
    #Break # For testing
}
"  $($Tickets_Basic.Count) tickets total"
#$Tickets_Basic | Format-Table -Property *
$Tickets_Basic | ConvertTo-Json -depth 100 | Out-File "Tickets\_tickets_basic.json"


# =================================================================================================
# =================================================================================================

# For each ticket, get the details
"Getting details for $($Tickets_Basic.Count) tickets"

$Tickets_Basic | ForEach-Object -ThrottleLimit 1 -Parallel {
    $TicketFile = "tickets\$($_.id).json"

    # If file exists, skip
    if (Test-Path $TicketFile) {
        "  Skipping $($_.id)"
        return
    }

    # Get general ticket details
    $Params = @{
        Method         = "GET"
        Uri            = "$using:API/servicedesk/tickets/$($_.id)"
        Authentication = "Bearer"
        Token          = $using:Token
    }
    try {
        $Request = Invoke-RestMethod @Params
    }
    catch {
        Write-Host -ForegroundColor Red "Error at line $($_.InvocationInfo.ScriptLineNumber): $_"
        Return
    } 

    # Get ticket notes
    $Params = @{
        Method         = "GET"
        Uri            = "$using:API/servicedesk/tickets/$($_.id)/notes"
        Authentication = "Bearer"
        Token          = $using:Token
        UseBasicParsing = $true
    }
    try {
        $Request_Notes = Invoke-RestMethod @Params
    }
    catch {
        Write-Host -ForegroundColor Red "Error at line $($_.InvocationInfo.ScriptLineNumber): $_"
        Return
    }
    $Notes_JSON = $Request_Notes.result # | ConvertTo-Json -Depth 10
    $Request.result | Add-Member -NotePropertyName "Notes" -NotePropertyValue $Notes_JSON

    # Get ticket time logs
    $Params = @{
        Method         = "GET"
        Uri            = "$using:API/servicedesk/tickets/$($_.id)/timelogs"
        Authentication = "Bearer"
        Token          = $using:Token
        UseBasicParsing = $true
    }
    try {
        $Request_TimeLogs = Invoke-RestMethod @Params
    }
    catch {
        Write-Host -ForegroundColor Red "Error at line $($_.InvocationInfo.ScriptLineNumber): $_"
        Return
    }
    $TimeLogs_JSON = $Request_TimeLogs.result # | ConvertTo-Json -Depth 10
    $Request.result | Add-Member -NotePropertyName "TimeLogs" -NotePropertyValue $TimeLogs_JSON
    

    # Create json file to store ticket information
    $Request.result | ConvertTo-Json -depth 100 | Out-File $TicketFile
    "Saved $TicketFile"
}