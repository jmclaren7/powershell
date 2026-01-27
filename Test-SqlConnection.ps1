#Requires -Version 5.1

<#
.SYNOPSIS
    Tests MS SQL Server connection and user login credentials.

.PARAMETER ServerInstance
    SQL Server instance name (e.g., "localhost", "server\instance", "server,port")

.PARAMETER Database
    Database name to connect to (default: master)

.PARAMETER Username
    SQL login username (omit for Windows Authentication)

.PARAMETER Password
    SQL login password (omit for Windows Authentication)

.PARAMETER Timeout
    Connection timeout in seconds (default: 30)

.EXAMPLE
    .\Test-SqlConnection.ps1 -ServerInstance "localhost" -Database "MyDB"
    
.EXAMPLE
    .\Test-SqlConnection.ps1 -ServerInstance "server\instance" -Username "sa" -Password "MyPass123"
#>

param(
    [Parameter(Mandatory)]
    [string]$ServerInstance,
    
    [string]$Database = "master",
    
    [string]$Username,
    
    [string]$Password,
    
    [int]$Timeout = 30
)

function Test-SqlConnection {
    param(
        [string]$ConnectionString
    )
    
    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = $ConnectionString
    
    $result = [PSCustomObject]@{
        Success       = $false
        ServerVersion = $null
        Database      = $null
        User          = $null
        Message       = $null
        ResponseTime  = $null
    }
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    
    try {
        $connection.Open()
        $stopwatch.Stop()
        
        $result.Success = $true
        $result.ServerVersion = $connection.ServerVersion
        $result.Database = $connection.Database
        $result.ResponseTime = "$($stopwatch.ElapsedMilliseconds) ms"
        
        # Get current user context
        $command = $connection.CreateCommand()
        $command.CommandText = "SELECT SUSER_SNAME() AS LoginName, USER_NAME() AS UserName, @@SERVERNAME AS ServerName"
        $reader = $command.ExecuteReader()
        
        if ($reader.Read()) {
            $result.User = $reader["LoginName"]
            $result | Add-Member -NotePropertyName "ServerName" -NotePropertyValue $reader["ServerName"]
        }
        $reader.Close()
        
        $result.Message = "Connection successful"
    }
    catch {
        $stopwatch.Stop()
        $result.Message = $_.Exception.Message
        $result.ResponseTime = "$($stopwatch.ElapsedMilliseconds) ms"
    }
    finally {
        if ($connection.State -eq 'Open') {
            $connection.Close()
        }
        $connection.Dispose()
    }
    
    return $result
}

function Get-SqlPermissions {
    param(
        [string]$ConnectionString
    )
    
    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = $ConnectionString
    
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        
        # Check server roles
        $command.CommandText = @"
SELECT 
    sp.name AS LoginName,
    sp.type_desc AS LoginType,
    sp.is_disabled AS IsDisabled,
    STUFF((
        SELECT ', ' + srm.name
        FROM sys.server_role_members AS rm
        JOIN sys.server_principals AS srm ON rm.role_principal_id = srm.principal_id
        WHERE rm.member_principal_id = sp.principal_id
        FOR XML PATH('')
    ), 1, 2, '') AS ServerRoles
FROM sys.server_principals AS sp
WHERE sp.name = SUSER_SNAME()
"@
        
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($command)
        $table = New-Object System.Data.DataTable
        $adapter.Fill($table) | Out-Null
        
        return $table
    }
    catch {
        Write-Warning "Could not retrieve permissions: $($_.Exception.Message)"
        return $null
    }
    finally {
        if ($connection.State -eq 'Open') {
            $connection.Close()
        }
        $connection.Dispose()
    }
}

# Build connection string
$connectionStringBuilder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
$connectionStringBuilder["Data Source"] = $ServerInstance
$connectionStringBuilder["Initial Catalog"] = $Database
$connectionStringBuilder["Connection Timeout"] = $Timeout

if ($Username -and $Password) {
    $connectionStringBuilder["User ID"] = $Username
    $connectionStringBuilder["Password"] = $Password
    $authType = "SQL Authentication"
}
else {
    $connectionStringBuilder["Integrated Security"] = $true
    $authType = "Windows Authentication"
}

$connectionString = $connectionStringBuilder.ToString()

# Display test info
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  SQL Server Connection Test" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Server:     $ServerInstance"
Write-Host "Database:   $Database"
Write-Host "Auth Type:  $authType"
Write-Host "Timeout:    $Timeout seconds"
Write-Host "----------------------------------------" -ForegroundColor Gray

# Run connection test
Write-Host "`nTesting connection..." -ForegroundColor Yellow
$result = Test-SqlConnection -ConnectionString $connectionString

if ($result.Success) {
    Write-Host "`n[SUCCESS] Connection established!" -ForegroundColor Green
    Write-Host "  Server Name:    $($result.ServerName)"
    Write-Host "  SQL Version:    $($result.ServerVersion)"
    Write-Host "  Database:       $($result.Database)"
    Write-Host "  Login:          $($result.User)"
    Write-Host "  Response Time:  $($result.ResponseTime)"
    
    # Get permissions
    Write-Host "`nRetrieving login information..." -ForegroundColor Yellow
    $permissions = Get-SqlPermissions -ConnectionString $connectionString
    
    if ($permissions -and $permissions.Rows.Count -gt 0) {
        Write-Host "`n[LOGIN INFO]" -ForegroundColor Cyan
        foreach ($row in $permissions.Rows) {
            Write-Host "  Login Type:   $($row.LoginType)"
            Write-Host "  Is Disabled:  $($row.IsDisabled)"
            Write-Host "  Server Roles: $(if ($row.ServerRoles) { $row.ServerRoles } else { 'None' })"
        }
    }
}
else {
    Write-Host "`n[FAILED] Connection failed!" -ForegroundColor Red
    Write-Host "  Error: $($result.Message)" -ForegroundColor Red
    Write-Host "  Response Time: $($result.ResponseTime)"
}

Write-Host "`n========================================" -ForegroundColor Cyan

# Return result object for pipeline use
$result
