<#
.SYNOPSIS
    Retrieves local administrator members from one or more computers and exports to CSV.

.DESCRIPTION
    Queries specified computers (or all enabled domain computers) for their local
    Administrators group members. Supports OU-based discovery, custom computer lists,
    and CSV export.

.PARAMETER ComputerName
    Specifies one or more computer names. Accepts wildcards.

.PARAMETER SearchBase
    The Distinguished Name of the OU to search for domain computers. If omitted,
    queries the entire domain.

.PARAMETER OutputPath
    Path to the output CSV file. If specified, results are exported to the file
    in addition to being returned as objects.

.PARAMETER UseADSI
    Forces the use of ADSI (WinNT) method instead of Get-LocalGroupMember. Useful
    for cross-version compatibility or when CIM/WMI is blocked.

.PARAMETER ErrorLog
    Path to a text file that will record errors for computers that could not be queried.

.EXAMPLE
    Get-LocalAdminToCsv.ps1

    Queries all enabled domain computers and outputs results to the console.

.EXAMPLE
    Get-LocalAdminToCsv.ps1 -ComputerName "SRV01", "SRV02" -OutputPath "C:\Reports\LocalAdmins.csv"

    Queries specific servers and exports the results to CSV.

.EXAMPLE
    Get-LocalAdminToCsv.ps1 -SearchBase "OU=Servers,DC=contoso,DC=com" -ErrorLog "C:\Reports\errors.log"

    Queries computers in a specific OU and logs errors.

.NOTES
    Author   : Mahdi Tehrani (original)
    Modified : Refactored for reliability and best practices
    Date     : 2017-02-18 (original)
    Requires : ActiveDirectory module (when no -ComputerName provided)
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, Position = 0)]
    [string[]]$ComputerName,

    [Parameter(Mandatory = $false, Position = 1)]
    [ValidateNotNullOrEmpty()]
    [string]$SearchBase,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [switch]$UseADSI,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ErrorLog
)

function Invoke-LocalAdminQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [switch]$UseADSI
    )

    try {
        $localAdmins = $null

        if ($UseADSI) {
            # ADSI method - works across all Windows versions
            $members = [ADSI]"WinNT://$Name/Administrators"
            $memberObjects = @($members.psbase.Invoke("Members"))

            $localAdmins = $memberObjects | ForEach-Object {
                $_.GetType().InvokeMember("Name", 'GetProperty', $null, $_, $null)
            }
        }
        else {
            # Get-LocalGroupMember - preferred method, requires PS 5.1+
            $localAdmins = Get-LocalGroupMember -Name Administrators -ComputerName $Name -ErrorAction Stop |
                Select-Object -ExpandProperty Name
        }

        [PSCustomObject]@{
            ComputerName = $Name
            LocalAdmins  = ($localAdmins -join "; ")
            Success      = $true
            Error        = $null
        }
    }
    catch {
        [PSCustomObject]@{
            ComputerName = $Name
            LocalAdmins  = $null
            Success      = $false
            Error        = $_.Exception.Message
        }
    }
}

function Get-DomainComputers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SearchBase
    )

    $adParams = @{
        Filter      = "*"
        Properties  = "Name", "Enabled"
        SearchBase  = $SearchBase
        ErrorAction = "Stop"
    }

    Get-ADComputer @adParams |
        Where-Object { $_.Enabled -eq $true } |
        Select-Object -ExpandProperty Name
}

# --- Main ---

# Load ActiveDirectory module (needed when ComputerName is not provided)
if (-not $ComputerName) {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Error "The ActiveDirectory module is not available. Install RSAT or provide -ComputerName."
        exit 1
    }

    $domainDNS = (Get-ADDomain).DNSRoot
    $domainDN  = (Get-ADDomain).DistinguishedName

    if ($SearchBase) {
        $searchBase = $SearchBase
    }
    else {
        $searchBase = $domainDN
    }

    Write-Verbose "Querying domain computers in: $searchBase"
    $ComputerName = Get-DomainComputers -SearchBase $searchBase

    if (-not $ComputerName) {
        Write-Error "No enabled computers found in the specified scope. Exiting."
        exit 1
    }

    Write-Verbose "Found $($ComputerName.Count) enabled computers."
}

# Collect results
$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$errorRecords = @()
$totalComputers = $ComputerName.Count
$counter = 0

foreach ($computer in $ComputerName) {
    $counter++
    $percent = [math]::Round(($counter / $totalComputers) * 100)

    Write-Progress -Activity "Enumerating Local Administrators" `
        -Status "Processing computer $counter of $totalComputers ($computer)" `
        -PercentComplete $percent

    $result = Invoke-LocalAdminQuery -Name $computer -UseADSI:$UseADSI
    $results.Add($result)

    if (-not $result.Success) {
        $errorRecords += $result.Error
        Write-Verbose "Failed to query $computer : $($result.Error)"
    }
}

# Export to CSV if requested
if ($OutputPath) {
    try {
        $successfulResults = $results | Where-Object { $_.Success }

        # Ensure directory exists
        $outputDir = Split-Path $OutputPath -Parent
        if (-not (Test-Path $outputDir)) {
            New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
        }

        $successfulResults | Select-Object ComputerName, LocalAdmins |
            Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

        Write-Verbose "Report exported to: $OutputPath"
    }
    catch {
        Write-Error "Failed to export CSV to $OutputPath : $_"
    }
}

# Write error log if any failures occurred
if ($errorRecords.Count -gt 0 -and $ErrorLog) {
    try {
        $outputDir = Split-Path $ErrorLog -Parent
        if (-not (Test-Path $outputDir)) {
            New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
        }

        $results |
            Where-Object { -not $_.Success } |
            Select-Object ComputerName, Error |
            Out-File -FilePath $ErrorLog -Encoding UTF8

        Write-Verbose "Error log written to: $ErrorLog ($($errorRecords.Count) failures)"
    }
    catch {
        Write-Error "Failed to write error log: $_"
    }
}

# Return all results
$results
