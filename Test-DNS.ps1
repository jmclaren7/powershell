<#
.SYNOPSIS
    DNS lookup testing script with support for multiple domains and DNS servers.

.DESCRIPTION
    Performs DNS lookups for specified domains using system DNS or custom DNS servers.
    Can run once or loop continuously with configurable delay.

.PARAMETER Domains
    Comma-separated list of domains to test (e.g., "example.com,google.com")

.PARAMETER DnsServers
    Optional comma-separated list of DNS servers to use (e.g., "8.8.8.8,1.1.1.1")
    If not specified, uses system DNS servers.

.PARAMETER Loop
    If specified, runs continuously. Can optionally specify delay in milliseconds.
    Default delay is 1000ms if not specified.

.EXAMPLE
    .\dns-test.ps1 -Domains "github.com,google.com"
    
.EXAMPLE
    .\dns-test.ps1 -Domains "example.com" -DnsServers "8.8.8.8,1.1.1.1" -Loop
    
.EXAMPLE
    .\dns-test.ps1 -Domains "example.com" -DnsServers "8.8.8.8" -Loop 5000
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Domains,
    
    [Parameter(Mandatory=$false)]
    [string]$DnsServers,
    
    [Parameter(Mandatory=$false)]
    [switch]$Loop,
    
    [Parameter(Mandatory=$false, Position=0)]
    [int]$LoopDelay = 1000
)

# Parse comma-separated domains
$domainList = $Domains -split ',' | ForEach-Object { $_.Trim() }

# Parse comma-separated DNS servers if provided
$dnsServerList = @()
if ($DnsServers) {
    $dnsServerList = $DnsServers -split ',' | ForEach-Object { $_.Trim() }
} else {
    $dnsServerList = @("System DNS")
}

function Test-DnsLookup {
    param(
        [string]$Domain,
        [string]$DnsServer
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    
    try {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        
        # Use QuickTimeout and DnsOnly for faster, more reliable queries
        if ($DnsServer -eq "System DNS") {
            $result = Resolve-DnsName -Name $Domain -QuickTimeout -DnsOnly -ErrorAction Stop
        } else {
            $result = Resolve-DnsName -Name $Domain -Server $DnsServer -QuickTimeout -DnsOnly -ErrorAction Stop
        }
        
        $stopwatch.Stop()
        $elapsed = $stopwatch.ElapsedMilliseconds
        
        # Extract IP addresses or records
        $records = $result | Where-Object { $_.Type -in @('A', 'AAAA', 'CNAME') } | ForEach-Object {
            if ($_.IPAddress) { $_.IPAddress }
            elseif ($_.NameHost) { $_.NameHost }
        }
        
        $recordsStr = ($records -join ', ')
        
        Write-Host "[$timestamp] " -NoNewline -ForegroundColor Gray
        Write-Host "SUCCESS" -NoNewline -ForegroundColor Green
        Write-Host " | Domain: " -NoNewline
        Write-Host $Domain -NoNewline -ForegroundColor Cyan
        Write-Host " | DNS: " -NoNewline
        Write-Host $DnsServer -NoNewline -ForegroundColor Yellow
        Write-Host " | Time: " -NoNewline
        Write-Host "${elapsed}ms" -NoNewline -ForegroundColor Magenta
        Write-Host " | Records: " -NoNewline
        Write-Host $recordsStr -ForegroundColor White
        
    } catch {
        $stopwatch.Stop()
        $elapsed = $stopwatch.ElapsedMilliseconds
        
        Write-Host "[$timestamp] " -NoNewline -ForegroundColor Gray
        Write-Host "FAILED" -NoNewline -ForegroundColor Red
        Write-Host " | Domain: " -NoNewline
        Write-Host $Domain -NoNewline -ForegroundColor Cyan
        Write-Host " | DNS: " -NoNewline
        Write-Host $DnsServer -NoNewline -ForegroundColor Yellow
        Write-Host " | Time: " -NoNewline
        Write-Host "${elapsed}ms" -NoNewline -ForegroundColor Magenta
        Write-Host " | Error: " -NoNewline
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function Invoke-DnsTests {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "DNS Lookup Tests - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    foreach ($domain in $domainList) {
        foreach ($dnsServer in $dnsServerList) {
            Test-DnsLookup -Domain $domain -DnsServer $dnsServer
        }
    }
    
    Write-Host "========================================`n" -ForegroundColor Cyan
}

# Main execution
if ($Loop) {
    Write-Host "Starting continuous DNS testing (Ctrl+C to stop)..." -ForegroundColor Green
    Write-Host "Loop delay: $LoopDelay ms`n" -ForegroundColor Green
    
    while ($true) {
        Invoke-DnsTests
        Start-Sleep -Milliseconds $LoopDelay
    }
} else {
    Invoke-DnsTests
}