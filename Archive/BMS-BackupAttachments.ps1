Remove-Variable * -ErrorAction SilentlyContinue
$ProgressPreference = 'SilentlyContinue'

$API = "https://api.bms.kaseya.com/v2"
$API_Tenant = ""
$API_UserName = ""
$API_Password = ""
$API_GrantType = "password"

# Use TLS 1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# Set location to script path
Set-Location $PSScriptRoot

While ($true) {

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
    try {
        $Request = Invoke-RestMethod @Params
    }
    catch {
        Write-Host -ForegroundColor Red "Error at line $($_.InvocationInfo.ScriptLineNumber): $_" 
        Exit
    }
    $Token = $($Request.result).accessToken | ConvertTo-SecureString -AsPlainText -Force


    # =================================================================================================
    # =================================================================================================

    $TicketList = Get-Content -Raw '_tickets_basic.json' | ConvertFrom-Json

    # For each TicketList
    $TicketList | ForEach-Object {
        $Ticket = $_.id   #  13650090 # 13650090 is our test ticket
        "Trying $Ticket" 


        $Params = @{
            Method         = "GET"
            Uri            = "$API/system/attachments/22/$Ticket" # 22 is ticket/help desk module
            Authentication = "Bearer"
            Token          = $Token
        }
        try {
            $Attachments = Invoke-RestMethod @Params
        
        }
        catch {
            Write-Host -ForegroundColor Red "Error at line $($_.InvocationInfo.ScriptLineNumber): $_" 
            #Exit
        }
    
        # =================================================================================================
        # =================================================================================================
    
        # Loop $Request2.result
        $Attachments.result | ForEach-Object {

            $DownloadFilePath = "Attachments/$Ticket-$($_.id)-$($_.objectId).$($_.fileType)"
        
            # If file already exists, skip
            if (Test-Path $DownloadFilePath) {
                "File already exists: $DownloadFilePath"
            }
            else {
                "Trying Download: $DownloadFilePath"
                $Params = @{
                    Method          = "GET"
                    Uri             = "$API/$($_.url)"
                    Authentication  = "Bearer"
                    Token           = $Token
                    ContentType     = ''
                    UseBasicParsing = $true
                    OutFile         = $DownloadFilePath
                }
                try {
                    $Download = Invoke-RestMethod @Params
            
                }
                catch {
                    Write-Host -ForegroundColor Red "Error at line $($_.InvocationInfo.ScriptLineNumber): $_" 
                    #Exit
                }
                "Download Complete"

            }
        }
    }
}







