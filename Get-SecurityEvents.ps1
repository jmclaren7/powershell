<#
.SYNOPSIS
    Reports recent security-related Windows events of interest from the Security log.

.DESCRIPTION
    Scans the Windows Security event log for noteworthy security activity and returns
    normalized objects that are easy to read, sort, and export. The script is built as
    an extensible framework: each "category" of interest is implemented as its own
    detection function, and more categories can be added over time.

    Categories currently implemented:

      Elevation - "Run as administrator / run as different user" using ALTERNATE
                  credentials. This captures the case where a logged-on user launches
                  something with a *different* account (e.g. a standard user entering an
                  administrator's username/password at the UAC prompt, RUNAS, or
                  "Run as different user"). Both SUCCESSFUL and FAILED attempts are
                  reported.

                  Detection logic:
                    - 4624 (logon success) + LogonType 2 (interactive) where the
                      account that *requested* the logon (Subject) differs from the
                      account that *logged on* (Target)  => Success
                    - 4625 (logon failure) + LogonType 2 where Subject differs from
                      Target                              => Failure (with reason)
                    - 4648 (explicit credentials) optionally included via
                      -IncludeExplicitCredential          => Attempt

                  When credentials differ, the Subject is the user "at the keyboard"
                  and the Target is the privileged account whose credentials were
                  supplied - exactly the elevate-with-different-credentials pattern.

.PARAMETER ComputerName
    One or more computers to query. Defaults to the local computer. Reading the
    Security log requires local administrator rights (or the "Manage auditing and
    security log" privilege) on the target.

.PARAMETER Days
    How many days back to look. Defaults to 7. Ignored if -StartTime is supplied.

.PARAMETER StartTime
    Explicit start of the time window. Overrides -Days.

.PARAMETER EndTime
    Explicit end of the time window. Defaults to now.

.PARAMETER MaxEvents
    Maximum number of raw events to pull from each computer before filtering.
    Defaults to 5000. Increase for very busy/long windows.

.PARAMETER Category
    Which categories to report. Defaults to All. Valid values: All, Elevation.

.PARAMETER LogonType
    Logon types considered "interactive elevation". Defaults to 2 (interactive),
    which is what the Secondary Logon service and UAC over-the-shoulder elevation
    use. Add 9 (NewCredentials, e.g. 'runas /netonly') if you want those too.

.PARAMETER IncludeExplicitCredential
    Also include 4648 "A logon was attempted using explicit credentials" events as
    informational "Attempt" rows. Useful for catching alternate-credential launches
    that don't produce a Type 2 logon.

.PARAMETER IncludeSameAccount
    By default only events where the initiating account differs from the target
    account are returned (i.e. genuinely *different* credentials). Use this switch to
    also include same-account elevations.

.PARAMETER OutputPath
    Optional path to a CSV file. Results are exported there in addition to being
    returned as objects.

.EXAMPLE
    Get-SecurityEvents.ps1

    Reports the last 7 days of run-as-different-credentials successes and failures on
    the local machine.

.EXAMPLE
    Get-SecurityEvents.ps1 -Days 1 -IncludeExplicitCredential | Format-Table -AutoSize

    Last 24 hours, including explicit-credential (4648) attempts, as a table.

.EXAMPLE
    Get-SecurityEvents.ps1 -ComputerName SRV01 -StartTime (Get-Date).AddHours(-12) -OutputPath C:\Reports\sec.csv

    Queries a remote server for the last 12 hours and exports to CSV.

.NOTES
    Author   : John McLaren
    Date     : 2026-06-21
    Requires : PowerShell 5.1+, and rights to read the Security log on each target.
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]]$ComputerName = $env:COMPUTERNAME,

    [Parameter()]
    [ValidateRange(1, 3650)]
    [int]$Days = 7,

    [Parameter()]
    [datetime]$StartTime,

    [Parameter()]
    [datetime]$EndTime,

    [Parameter()]
    [ValidateRange(1, 1000000)]
    [int]$MaxEvents = 5000,

    [Parameter()]
    [ValidateSet('All', 'Elevation')]
    [string[]]$Category = 'All',

    [Parameter()]
    [int[]]$LogonType = @(2),

    [Parameter()]
    [switch]$IncludeExplicitCredential,

    [Parameter()]
    [switch]$IncludeSameAccount,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath
)

# --- Lookup tables ---

$LogonTypeNames = @{
    2  = 'Interactive'
    3  = 'Network'
    4  = 'Batch'
    5  = 'Service'
    7  = 'Unlock'
    8  = 'NetworkCleartext'
    9  = 'NewCredentials'
    10 = 'RemoteInteractive'
    11 = 'CachedInteractive'
}

# Common 4625 Status / SubStatus failure codes -> human readable reason.
$FailureReasons = @{
    '0xC0000064' = 'User name does not exist'
    '0xC000006A' = 'Wrong password'
    '0xC000006D' = 'Bad user name or password'
    '0xC000006E' = 'Account restriction (hours/workstation/expired)'
    '0xC000006F' = 'Logon outside authorized hours'
    '0xC0000070' = 'Workstation restriction (not allowed to log on here)'
    '0xC0000071' = 'Password expired'
    '0xC0000072' = 'Account disabled'
    '0xC0000133' = 'Clock skew between client and DC'
    '0xC000015B' = 'Logon type not granted to user'
    '0xC0000193' = 'Account expired'
    '0xC0000224' = 'User must change password at next logon'
    '0xC0000234' = 'Account locked out'
    '0xC00002EE' = 'An error occurred during logon'
    '0xC0000413' = 'Authentication firewall prohibits this logon'
}

# --- Helper functions ---

function ConvertTo-EventDataHash {
    # Flatten an event record's EventData section into a Name -> value hashtable.
    # Uses GetElementsByTagName/GetAttribute rather than PowerShell's adaptive dotted
    # XML access, which is namespace-sensitive and can silently return nothing.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Eventing.Reader.EventRecord]$Record
    )

    $hash = @{}
    $doc = [xml]$Record.ToXml()
    foreach ($node in $doc.GetElementsByTagName('Data')) {
        $name = $node.GetAttribute('Name')
        if ($name) { $hash[$name] = [string]$node.InnerText }
    }
    $hash
}

function Test-RealAccount {
    <# True for genuine user accounts; false for blanks, machine accounts ($) and
       well-known service principals that aren't interesting here. #>
    [CmdletBinding()]
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name -eq '-') { return $false }
    if ($Name.EndsWith('$')) { return $false }

    $wellKnown = @(
        'SYSTEM', 'LOCAL SERVICE', 'NETWORK SERVICE', 'ANONYMOUS LOGON'
    )
    if ($wellKnown -contains $Name.ToUpperInvariant()) { return $false }
    if ($Name -match '^(DWM|UMFD)-\d+$') { return $false }

    return $true
}

function Format-Account {
    param([string]$Domain, [string]$User)
    if ([string]::IsNullOrWhiteSpace($Domain) -or $Domain -eq '-') { return $User }
    "$Domain\$User"
}

function Test-IsRemote {
    param([string]$Computer)
    return ($Computer -and
            $Computer -ne $env:COMPUTERNAME -and
            $Computer -ne 'localhost' -and
            $Computer -ne '.')
}

function Test-SecurityLogAccess {
    <# Probe read access to a log. NOTE: Get-WinEvent -FilterHashtable masks an
       access-denied as "No events were found", so we probe with a plain -LogName
       read, which DOES raise UnauthorizedAccessException when blocked. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Computer,
        [string]$LogName = 'Security'
    )

    $probe = @{ LogName = $LogName; MaxEvents = 1; ErrorAction = 'Stop' }
    if (Test-IsRemote $Computer) { $probe['ComputerName'] = $Computer }

    try {
        $null = Get-WinEvent @probe
        return $true
    }
    catch [System.UnauthorizedAccessException] {
        Write-Warning ("Access denied reading the '$LogName' log on '$Computer'. " +
            "Re-run elevated (Run as administrator), or use an account holding the " +
            "'Manage auditing and security log' right on the target.")
        return $false
    }
    catch {
        # An accessible-but-empty log reports "No events were found" - treat as OK.
        if ($_.Exception.Message -match 'No events were found') { return $true }
        Write-Warning "Cannot read the '$LogName' log on '$Computer': $($_.Exception.Message)"
        return $false
    }
}

function Resolve-FailureReason {
    param([string]$Status, [string]$SubStatus)

    foreach ($code in @($SubStatus, $Status)) {
        if ([string]::IsNullOrWhiteSpace($code)) { continue }
        $key = $code.ToUpperInvariant() -replace '^0X', '0x'
        if ($FailureReasons.ContainsKey($key)) {
            return "$($FailureReasons[$key]) ($key)"
        }
    }

    $shown = if ($SubStatus) { $SubStatus } else { $Status }
    if ($shown) { "Unknown ($shown)" } else { $null }
}

# --- Detection: Elevation / run-as with alternate credentials ---

function Get-ElevationEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Computer,
        [Parameter(Mandatory)] [datetime]$Start,
        [datetime]$End,
        [int]$Max,
        [int[]]$AllowedLogonType,
        [switch]$WithExplicit,
        [switch]$AllowSameAccount
    )

    $ids = @(4624, 4625)
    if ($WithExplicit) { $ids += 4648 }

    $filter = @{
        LogName   = 'Security'
        Id        = $ids
        StartTime = $Start
    }
    if ($End) { $filter['EndTime'] = $End }

    $getParams = @{
        FilterHashtable = $filter
        MaxEvents       = $Max
        ErrorAction     = 'Stop'
    }
    if (Test-IsRemote $Computer) {
        $getParams['ComputerName'] = $Computer
    }

    try {
        $events = Get-WinEvent @getParams
    }
    catch [System.UnauthorizedAccessException] {
        Write-Warning "Access denied reading the Security log on '$Computer'. Run elevated / with rights to that log."
        return
    }
    catch {
        if ($_.Exception.Message -match 'No events were found') {
            Write-Verbose "No matching events on '$Computer'."
            return
        }
        Write-Warning "Failed to query '$Computer': $($_.Exception.Message)"
        return
    }

    foreach ($rec in $events) {
        $d = ConvertTo-EventDataHash -Record $rec

        $subjectUser = $d['SubjectUserName']
        $subjectDom  = $d['SubjectDomainName']
        $targetUser  = $d['TargetUserName']
        $targetDom   = $d['TargetDomainName']

        # We need a real initiating user; for 4648 the explicit creds are the target.
        if (-not (Test-RealAccount $subjectUser)) { continue }
        if (-not (Test-RealAccount $targetUser))  { continue }

        # Only "different credentials" unless the caller asked for everything.
        $sameAccount = ($subjectUser -eq $targetUser) -and
                       ((($subjectDom)  -eq ($targetDom)) -or [string]::IsNullOrWhiteSpace($targetDom))
        if ($sameAccount -and -not $AllowSameAccount) { continue }

        $id = [int]$rec.Id

        # 4624/4625 carry a LogonType; honor the filter before classifying.
        # ('continue' here belongs to the foreach - it must NOT live inside the switch.)
        if (($id -eq 4624 -or $id -eq 4625) -and
            ($AllowedLogonType -notcontains [int]$d['LogonType'])) {
            continue
        }

        $source = if ($d['IpAddress'] -and $d['IpAddress'] -ne '-') {
            $d['IpAddress']
        }
        elseif ($d['WorkstationName']) {
            $d['WorkstationName']
        }
        else {
            $d['TargetServerName']
        }

        switch ($id) {
            4648 {
                $result    = 'Attempt (explicit creds)'
                $reason    = $null
                $logonText = 'n/a'
            }
            4624 {
                $result    = 'Success'
                $reason    = if ($d['ElevatedToken'] -eq '%%1842') { 'Elevated token' } else { $null }
                $logonText = '{0} ({1})' -f $d['LogonType'], $LogonTypeNames[[int]$d['LogonType']]
            }
            4625 {
                $result    = 'Failure'
                $reason    = Resolve-FailureReason -Status $d['Status'] -SubStatus $d['SubStatus']
                $logonText = '{0} ({1})' -f $d['LogonType'], $LogonTypeNames[[int]$d['LogonType']]
            }
        }

        $process = $d['ProcessName']

        [PSCustomObject]([ordered]@{
            Computer       = $rec.MachineName
            TimeCreated    = $rec.TimeCreated
            Category       = 'Elevation / Alternate Credentials'
            Result         = $result
            EventId        = [int]$rec.Id
            InitiatingUser = Format-Account -Domain $subjectDom -User $subjectUser
            TargetUser     = Format-Account -Domain $targetDom -User $targetUser
            LogonType      = $logonText
            Process        = $process
            Source         = $source
            Detail         = $reason
        })
    }
}

# --- Main ---

if ($PSBoundParameters.ContainsKey('StartTime')) {
    $start = $StartTime
}
else {
    $start = (Get-Date).AddDays(-$Days)
}
$end = if ($PSBoundParameters.ContainsKey('EndTime')) { $EndTime } else { $null }

$runAll      = $Category -contains 'All'
$results     = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($computer in $ComputerName) {
    Write-Verbose "Scanning '$computer' from $start$(if ($end) { " to $end" })..."

    # Gate on log access so a non-elevated run fails loudly instead of looking "clean".
    if (-not (Test-SecurityLogAccess -Computer $computer)) { continue }

    if ($runAll -or $Category -contains 'Elevation') {
        $elevationParams = @{
            Computer         = $computer
            Start            = $start
            Max              = $MaxEvents
            AllowedLogonType = $LogonType
            WithExplicit     = $IncludeExplicitCredential
            AllowSameAccount = $IncludeSameAccount
        }
        if ($end) { $elevationParams['End'] = $end }

        Get-ElevationEvent @elevationParams | ForEach-Object { $results.Add($_) }
    }
}

# Most recent first.
$sorted = $results | Sort-Object TimeCreated -Descending

if ($OutputPath) {
    try {
        $outputDir = Split-Path -Path $OutputPath -Parent
        if ($outputDir -and -not (Test-Path -Path $outputDir)) {
            New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
        }
        $sorted | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
        Write-Verbose "Exported $($sorted.Count) row(s) to: $OutputPath"
    }
    catch {
        Write-Error "Failed to export CSV to '$OutputPath': $_"
    }
}

if (-not $sorted) {
    Write-Verbose "No events of interest found in the specified window."
}

$sorted
