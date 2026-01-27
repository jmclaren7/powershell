<#
.SYNOPSIS
    Generates a visual HTML report mapping Users -> Groups -> NTFS Folder Permissions.

.DESCRIPTION
    This script collects NTFS permissions from folders, users from a specified OU, 
    and groups from a specified OU. It then constructs a visual HTML report showing 
    how groups connect users to folders, including nested group membership resolution.

.PARAMETER DataPath
    The root path to scan for NTFS permissions.

.PARAMETER Depth
    How many levels deep to scan for folders (default: 2).

.PARAMETER UserOU
    The Distinguished Name of the OU containing users to analyze.

.PARAMETER GroupOU
    The Distinguished Name of the OU containing groups to analyze.

.PARAMETER OutputPath
    Path for the HTML report output (default: script directory).

.PARAMETER IncludeEmptyUsers
    Include users with no folder access in the report.

.EXAMPLE
    .\UserGroupFile-AccessMap.ps1 -DataPath "D:\Shares\Data" -Depth 3 -UserOU "OU=Users,DC=domain,DC=com" -GroupOU "OU=Groups,DC=domain,DC=com"

.NOTES
    Author: Generated Script
    Requires: ActiveDirectory module, appropriate permissions to read AD and NTFS ACLs
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DataPath,

    [Parameter(Mandatory = $false)]
    [int]$Depth = 2,

    [Parameter(Mandatory = $true)]
    [string]$UserOU,

    [Parameter(Mandatory = $true)]
    [string]$GroupOU,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = $PSScriptRoot,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeEmptyUsers
)

#Requires -Modules ActiveDirectory

# Load System.Web assembly for HTML encoding
Add-Type -AssemblyName System.Web

# ============================================================================
# CONFIGURATION
# ============================================================================
$Script:Config = @{
    PermissionColors = @{
        'FullControl'      = '#dc3545'  # Red - highest privilege
        'Modify'           = '#fd7e14'  # Orange
        'Write'            = '#ffc107'  # Yellow
        'ReadAndExecute'   = '#28a745'  # Green
        'Read'             = '#20c997'  # Teal
        'ListDirectory'    = '#17a2b8'  # Cyan
        'Deny'             = '#6f42c1'  # Purple - for deny permissions
    }
    PermissionPriority = @{
        'FullControl'      = 1
        'Modify'           = 2
        'Write'            = 3
        'ReadAndExecute'   = 4
        'Read'             = 5
        'ListDirectory'    = 6
    }
}

# ============================================================================
# FUNCTIONS
# ============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARNING" { "Yellow" }
        "SUCCESS" { "Green" }
        default   { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Get-ADUsersFromOU {
    param([string]$OU)
    
    Write-Log "Retrieving users from OU: $OU"
    try {
        $users = Get-ADUser -SearchBase $OU -Filter * -Properties MemberOf, DisplayName, SamAccountName |
            Select-Object SamAccountName, DisplayName, DistinguishedName, 
                @{N='DirectGroups'; E={$_.MemberOf}}
        Write-Log "Found $($users.Count) users" -Level "SUCCESS"
        return $users
    }
    catch {
        Write-Log "Failed to retrieve users: $_" -Level "ERROR"
        throw
    }
}

function Get-ADGroupsFromOU {
    param([string]$OU)
    
    Write-Log "Retrieving groups from OU: $OU"
    try {
        $groups = Get-ADGroup -SearchBase $OU -Filter * -Properties Members, MemberOf, Description |
            Select-Object Name, SamAccountName, DistinguishedName, Description,
                @{N='DirectMembers'; E={$_.Members}},
                @{N='MemberOfGroups'; E={$_.MemberOf}}
        Write-Log "Found $($groups.Count) groups" -Level "SUCCESS"
        return $groups
    }
    catch {
        Write-Log "Failed to retrieve groups: $_" -Level "ERROR"
        throw
    }
}

function Get-NestedGroupMembership {
    param(
        [array]$Groups,
        [hashtable]$GroupLookup
    )
    
    Write-Log "Resolving nested group memberships..."
    
    # Build a hashtable of group DN to group object
    $groupByDN = @{}
    foreach ($group in $Groups) {
        $groupByDN[$group.DistinguishedName] = $group
    }
    
    # For each group, find all groups it's a member of (recursively)
    $groupMemberships = @{}
    
    foreach ($group in $Groups) {
        $allParentGroups = @()
        $toProcess = [System.Collections.Queue]::new()
        $processed = @{}
        
        # Add direct parent groups
        foreach ($parentDN in $group.MemberOfGroups) {
            if ($groupByDN.ContainsKey($parentDN) -and -not $processed.ContainsKey($parentDN)) {
                $toProcess.Enqueue($parentDN)
                $processed[$parentDN] = $true
            }
        }
        
        # Process queue for nested memberships
        while ($toProcess.Count -gt 0) {
            $currentDN = $toProcess.Dequeue()
            $allParentGroups += $currentDN
            
            if ($groupByDN.ContainsKey($currentDN)) {
                foreach ($parentDN in $groupByDN[$currentDN].MemberOfGroups) {
                    if ($groupByDN.ContainsKey($parentDN) -and -not $processed.ContainsKey($parentDN)) {
                        $toProcess.Enqueue($parentDN)
                        $processed[$parentDN] = $true
                    }
                }
            }
        }
        
        $groupMemberships[$group.DistinguishedName] = $allParentGroups
    }
    
    return $groupMemberships
}

function Get-UserEffectiveGroups {
    param(
        [object]$User,
        [array]$Groups,
        [hashtable]$GroupMemberships
    )
    
    $effectiveGroups = @{}
    $groupByDN = @{}
    foreach ($group in $Groups) {
        $groupByDN[$group.DistinguishedName] = $group
    }
    
    # Check direct group memberships
    foreach ($groupDN in $User.DirectGroups) {
        if ($groupByDN.ContainsKey($groupDN)) {
            $group = $groupByDN[$groupDN]
            if (-not $effectiveGroups.ContainsKey($groupDN)) {
                $effectiveGroups[$groupDN] = @{
                    Group = $group
                    Path = @($group.Name)
                    IsDirect = $true
                }
            }
            
            # Add all parent groups this group is a member of
            if ($GroupMemberships.ContainsKey($groupDN)) {
                foreach ($parentDN in $GroupMemberships[$groupDN]) {
                    if ($groupByDN.ContainsKey($parentDN) -and -not $effectiveGroups.ContainsKey($parentDN)) {
                        $parentGroup = $groupByDN[$parentDN]
                        $effectiveGroups[$parentDN] = @{
                            Group = $parentGroup
                            Path = @($group.Name, "->", $parentGroup.Name)
                            IsDirect = $false
                        }
                    }
                }
            }
        }
    }
    
    return $effectiveGroups
}

function Get-FolderPermissions {
    param(
        [string]$Path,
        [int]$Depth
    )
    
    Write-Log "Scanning folder permissions at: $Path (Depth: $Depth)"
    
    $folders = @()
    
    try {
        # Get root folder
        $folders += Get-Item -Path $Path -ErrorAction Stop
        
        # Get subfolders based on depth
        if ($Depth -gt 0) {
            $folders += Get-ChildItem -Path $Path -Directory -Recurse -Depth ($Depth - 1) -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-Log "Error accessing path: $_" -Level "ERROR"
        throw
    }
    
    Write-Log "Found $($folders.Count) folders to analyze"
    
    $folderPermissions = @()
    
    foreach ($folder in $folders) {
        try {
            $acl = Get-Acl -Path $folder.FullName -ErrorAction Stop
            
            foreach ($access in $acl.Access) {
                # Skip inherited permissions
                if ($access.IsInherited) { continue }
                
                # Get the identity (could be user or group)
                $identity = $access.IdentityReference.Value
                
                # Skip built-in accounts
                if ($identity -match '^(NT AUTHORITY|BUILTIN|CREATOR|S-1-)') { continue }
                
                # Extract just the account name (remove domain prefix)
                $accountName = $identity
                if ($identity -match '\\') {
                    $accountName = $identity.Split('\')[1]
                }
                
                $folderPermissions += [PSCustomObject]@{
                    FolderPath      = $folder.FullName
                    RelativePath    = $folder.FullName.Replace($Path, '').TrimStart('\')
                    FolderName      = $folder.Name
                    Identity        = $identity
                    AccountName     = $accountName
                    AccessType      = $access.AccessControlType.ToString()
                    Rights          = $access.FileSystemRights.ToString()
                    SimplifiedRight = Get-SimplifiedRight -Rights $access.FileSystemRights.ToString()
                }
            }
        }
        catch {
            Write-Log "Could not read ACL for: $($folder.FullName) - $_" -Level "WARNING"
        }
    }
    
    Write-Log "Collected $($folderPermissions.Count) permission entries" -Level "SUCCESS"
    return $folderPermissions
}

function Get-SimplifiedRight {
    param([string]$Rights)
    
    if ($Rights -match 'FullControl') { return 'FullControl' }
    if ($Rights -match 'Modify') { return 'Modify' }
    if ($Rights -match 'Write') { return 'Write' }
    if ($Rights -match 'ReadAndExecute') { return 'ReadAndExecute' }
    if ($Rights -match 'Read') { return 'Read' }
    if ($Rights -match 'ListDirectory') { return 'ListDirectory' }
    
    return $Rights
}

function Build-AccessMap {
    param(
        [array]$Users,
        [array]$Groups,
        [array]$FolderPermissions,
        [hashtable]$GroupMemberships
    )
    
    Write-Log "Building access map..."
    
    $accessMap = @()
    $groupByName = @{}
    
    foreach ($group in $Groups) {
        $groupByName[$group.SamAccountName] = $group
        $groupByName[$group.Name] = $group
    }
    
    foreach ($user in $Users) {
        # Get all groups this user is effectively a member of
        $effectiveGroups = Get-UserEffectiveGroups -User $user -Groups $Groups -GroupMemberships $GroupMemberships
        
        $userAccess = @{
            User = $user
            FolderAccess = @{}
        }
        
        # Check each folder permission
        foreach ($perm in $FolderPermissions) {
            $folderKey = $perm.FolderPath
            
            # Check if this permission applies to any of the user's groups
            foreach ($groupEntry in $effectiveGroups.Values) {
                $group = $groupEntry.Group
                
                if ($perm.AccountName -eq $group.SamAccountName -or $perm.AccountName -eq $group.Name) {
                    if (-not $userAccess.FolderAccess.ContainsKey($folderKey)) {
                        $userAccess.FolderAccess[$folderKey] = @{
                            Permission = $perm
                            ViaGroups = @()
                        }
                    }
                    
                    $userAccess.FolderAccess[$folderKey].ViaGroups += @{
                        GroupName = $group.Name
                        Path = $groupEntry.Path
                        IsDirect = $groupEntry.IsDirect
                    }
                    
                    # Update permission if this one is higher priority
                    $currentPriority = $Script:Config.PermissionPriority[$userAccess.FolderAccess[$folderKey].Permission.SimplifiedRight]
                    $newPriority = $Script:Config.PermissionPriority[$perm.SimplifiedRight]
                    
                    if ($null -eq $currentPriority) { $currentPriority = 99 }
                    if ($null -eq $newPriority) { $newPriority = 99 }
                    
                    if ($newPriority -lt $currentPriority) {
                        $userAccess.FolderAccess[$folderKey].Permission = $perm
                    }
                }
            }
            
            # Also check if the permission is directly assigned to the user
            if ($perm.AccountName -eq $user.SamAccountName) {
                if (-not $userAccess.FolderAccess.ContainsKey($folderKey)) {
                    $userAccess.FolderAccess[$folderKey] = @{
                        Permission = $perm
                        ViaGroups = @()
                    }
                }
                
                $userAccess.FolderAccess[$folderKey].ViaGroups += @{
                    GroupName = "(Direct)"
                    Path = @("Direct Assignment")
                    IsDirect = $true
                }
            }
        }
        
        $accessMap += $userAccess
    }
    
    Write-Log "Access map built for $($accessMap.Count) users" -Level "SUCCESS"
    return $accessMap
}

function Generate-HTMLReport {
    param(
        [array]$AccessMap,
        [array]$FolderPermissions,
        [array]$Groups,
        [string]$DataPath,
        [string]$OutputFile
    )
    
    Write-Log "Generating HTML report..."
    
    # Get unique folders
    $folders = $FolderPermissions | Select-Object -Property FolderPath, RelativePath, FolderName -Unique | Sort-Object FolderPath
    
    # Build HTML
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>User-Group-Folder Access Map</title>
    <style>
        :root {
            --bg-primary: #1a1a2e;
            --bg-secondary: #16213e;
            --bg-tertiary: #0f3460;
            --text-primary: #eaeaea;
            --text-secondary: #a0a0a0;
            --border-color: #2a2a4a;
            --hover-color: #2a3f5f;
        }
        
        * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
        }
        
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background-color: var(--bg-primary);
            color: var(--text-primary);
            line-height: 1.6;
            padding: 20px;
        }
        
        .container {
            max-width: 100%;
            margin: 0 auto;
        }
        
        header {
            background: linear-gradient(135deg, var(--bg-secondary), var(--bg-tertiary));
            padding: 30px;
            border-radius: 10px;
            margin-bottom: 30px;
            box-shadow: 0 4px 6px rgba(0, 0, 0, 0.3);
        }
        
        h1 {
            font-size: 2rem;
            margin-bottom: 10px;
        }
        
        .meta-info {
            color: var(--text-secondary);
            font-size: 0.9rem;
        }
        
        .legend {
            background: var(--bg-secondary);
            padding: 20px;
            border-radius: 10px;
            margin-bottom: 30px;
            display: flex;
            flex-wrap: wrap;
            gap: 15px;
        }
        
        .legend-item {
            display: flex;
            align-items: center;
            gap: 8px;
        }
        
        .legend-color {
            width: 20px;
            height: 20px;
            border-radius: 4px;
        }
        
        .tabs {
            display: flex;
            gap: 10px;
            margin-bottom: 20px;
            flex-wrap: wrap;
        }
        
        .tab-btn {
            padding: 10px 20px;
            background: var(--bg-secondary);
            border: 1px solid var(--border-color);
            border-radius: 5px;
            color: var(--text-primary);
            cursor: pointer;
            transition: all 0.3s;
        }
        
        .tab-btn:hover, .tab-btn.active {
            background: var(--bg-tertiary);
            border-color: #4a90d9;
        }
        
        .tab-content {
            display: none;
        }
        
        .tab-content.active {
            display: block;
        }
        
        .search-box {
            padding: 10px 15px;
            background: var(--bg-secondary);
            border: 1px solid var(--border-color);
            border-radius: 5px;
            color: var(--text-primary);
            width: 300px;
            margin-bottom: 20px;
        }
        
        .search-box:focus {
            outline: none;
            border-color: #4a90d9;
        }
        
        /* User Cards View */
        .user-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(400px, 1fr));
            gap: 20px;
        }
        
        .user-card {
            background: var(--bg-secondary);
            border-radius: 10px;
            overflow: hidden;
            box-shadow: 0 2px 4px rgba(0, 0, 0, 0.2);
        }
        
        .user-card-header {
            background: var(--bg-tertiary);
            padding: 15px 20px;
            border-bottom: 1px solid var(--border-color);
        }
        
        .user-name {
            font-size: 1.1rem;
            font-weight: 600;
        }
        
        .user-account {
            color: var(--text-secondary);
            font-size: 0.85rem;
        }
        
        .user-card-body {
            padding: 15px 20px;
            max-height: 400px;
            overflow-y: auto;
        }
        
        .folder-access {
            margin-bottom: 15px;
            padding: 10px;
            background: var(--bg-primary);
            border-radius: 5px;
            border-left: 4px solid;
        }
        
        .folder-name {
            font-weight: 500;
            margin-bottom: 5px;
            word-break: break-all;
        }
        
        .folder-path {
            font-size: 0.8rem;
            color: var(--text-secondary);
            margin-bottom: 8px;
        }
        
        .permission-badge {
            display: inline-block;
            padding: 2px 8px;
            border-radius: 3px;
            font-size: 0.75rem;
            font-weight: 600;
            color: white;
        }
        
        .group-chain {
            font-size: 0.85rem;
            color: var(--text-secondary);
            margin-top: 5px;
        }
        
        .group-chain .group-name {
            color: #4a90d9;
        }
        
        .group-chain .arrow {
            margin: 0 5px;
            color: #666;
        }
        
        /* Matrix View */
        .matrix-container {
            overflow-x: auto;
            background: var(--bg-secondary);
            border-radius: 10px;
            padding: 20px;
        }
        
        .matrix-table {
            border-collapse: collapse;
            width: 100%;
            min-width: 800px;
        }
        
        .matrix-table th, .matrix-table td {
            border: 1px solid var(--border-color);
            padding: 8px 12px;
            text-align: center;
            font-size: 0.85rem;
        }
        
        .matrix-table th {
            background: var(--bg-tertiary);
            position: sticky;
            top: 0;
            z-index: 10;
        }
        
        .matrix-table th.user-header {
            text-align: left;
            min-width: 150px;
        }
        
        .matrix-table th.folder-header {
            writing-mode: vertical-rl;
            text-orientation: mixed;
            transform: rotate(180deg);
            max-width: 40px;
            height: 200px;
            white-space: nowrap;
        }
        
        .matrix-table td.user-cell {
            text-align: left;
            background: var(--bg-tertiary);
            position: sticky;
            left: 0;
            z-index: 5;
        }
        
        .matrix-table td.access-cell {
            cursor: pointer;
            transition: all 0.2s;
        }
        
        .matrix-table td.access-cell:hover {
            transform: scale(1.1);
            box-shadow: 0 0 10px rgba(74, 144, 217, 0.5);
        }
        
        .matrix-table td.no-access {
            background: var(--bg-primary);
        }
        
        /* Group Analysis View */
        .group-card {
            background: var(--bg-secondary);
            border-radius: 10px;
            margin-bottom: 20px;
            overflow: hidden;
        }
        
        .group-header {
            background: var(--bg-tertiary);
            padding: 15px 20px;
            cursor: pointer;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        
        .group-header:hover {
            background: var(--hover-color);
        }
        
        .group-body {
            padding: 20px;
            display: none;
        }
        
        .group-body.expanded {
            display: block;
        }
        
        .group-section {
            margin-bottom: 15px;
        }
        
        .group-section h4 {
            color: var(--text-secondary);
            margin-bottom: 10px;
            font-size: 0.9rem;
            text-transform: uppercase;
        }
        
        .member-list, .folder-list {
            display: flex;
            flex-wrap: wrap;
            gap: 8px;
        }
        
        .member-tag, .folder-tag {
            background: var(--bg-primary);
            padding: 5px 10px;
            border-radius: 4px;
            font-size: 0.85rem;
        }
        
        .tooltip {
            position: fixed;
            background: var(--bg-tertiary);
            border: 1px solid var(--border-color);
            padding: 10px 15px;
            border-radius: 5px;
            box-shadow: 0 4px 6px rgba(0, 0, 0, 0.3);
            z-index: 1000;
            max-width: 300px;
            display: none;
        }
        
        .no-access-msg {
            text-align: center;
            padding: 40px;
            color: var(--text-secondary);
        }
        
        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        
        .stat-card {
            background: var(--bg-secondary);
            padding: 20px;
            border-radius: 10px;
            text-align: center;
        }
        
        .stat-value {
            font-size: 2.5rem;
            font-weight: 700;
            color: #4a90d9;
        }
        
        .stat-label {
            color: var(--text-secondary);
            font-size: 0.9rem;
        }
        
        @media (max-width: 768px) {
            .user-grid {
                grid-template-columns: 1fr;
            }
            
            .matrix-table th.folder-header {
                height: 150px;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>&#128272; User-Group-Folder Access Map</h1>
            <div class="meta-info">
                <p><strong>Data Path:</strong> $DataPath</p>
                <p><strong>Generated:</strong> $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</p>
                <p><strong>Total Users:</strong> $($AccessMap.Count) | <strong>Total Folders:</strong> $($folders.Count) | <strong>Total Groups:</strong> $($Groups.Count)</p>
            </div>
        </header>
        
        <div class="stats-grid">
            <div class="stat-card">
                <div class="stat-value">$($AccessMap.Count)</div>
                <div class="stat-label">Users Analyzed</div>
            </div>
            <div class="stat-card">
                <div class="stat-value">$($folders.Count)</div>
                <div class="stat-label">Folders Scanned</div>
            </div>
            <div class="stat-card">
                <div class="stat-value">$($Groups.Count)</div>
                <div class="stat-label">Groups in Scope</div>
            </div>
            <div class="stat-card">
                <div class="stat-value">$(($AccessMap | ForEach-Object { $_.FolderAccess.Count } | Measure-Object -Sum).Sum)</div>
                <div class="stat-label">Access Mappings</div>
            </div>
        </div>
        
        <div class="legend">
            <span style="font-weight: 600; margin-right: 10px;">Permission Levels:</span>
"@

    # Add legend items
    foreach ($perm in @('FullControl', 'Modify', 'Write', 'ReadAndExecute', 'Read', 'ListDirectory')) {
        $color = $Script:Config.PermissionColors[$perm]
        $html += @"
            <div class="legend-item">
                <div class="legend-color" style="background-color: $color;"></div>
                <span>$perm</span>
            </div>
"@
    }
    
    $html += @"
        </div>
        
        <div class="tabs">
            <button class="tab-btn active" onclick="showTab('user-view')">&#128100; User View</button>
            <button class="tab-btn" onclick="showTab('matrix-view')">&#128202; Matrix View</button>
            <button class="tab-btn" onclick="showTab('group-view')">&#128101; Group Analysis</button>
        </div>
        
        <input type="text" class="search-box" placeholder="&#128269; Search users, groups, or folders..." onkeyup="filterContent(this.value)">
        
        <!-- User View -->
        <div id="user-view" class="tab-content active">
            <div class="user-grid">
"@

    # Generate user cards
    foreach ($entry in ($AccessMap | Sort-Object { $_.User.DisplayName })) {
        $user = $entry.User
        $displayName = if ($user.DisplayName) { $user.DisplayName } else { $user.SamAccountName }
        
        if ($entry.FolderAccess.Count -eq 0 -and -not $IncludeEmptyUsers) { continue }
        
        $html += @"
                <div class="user-card" data-searchable="$($displayName.ToLower()) $($user.SamAccountName.ToLower())">
                    <div class="user-card-header">
                        <div class="user-name">$([System.Web.HttpUtility]::HtmlEncode($displayName))</div>
                        <div class="user-account">$($user.SamAccountName)</div>
                    </div>
                    <div class="user-card-body">
"@
        
        if ($entry.FolderAccess.Count -eq 0) {
            $html += '<div class="no-access-msg">No folder access found</div>'
        } else {
            foreach ($folderAccess in ($entry.FolderAccess.GetEnumerator() | Sort-Object { $_.Value.Permission.FolderPath })) {
                $perm = $folderAccess.Value.Permission
                $groups = $folderAccess.Value.ViaGroups
                $color = $Script:Config.PermissionColors[$perm.SimplifiedRight]
                if (-not $color) { $color = '#666666' }
                
                $accessType = if ($perm.AccessType -eq 'Deny') { 
                    $color = $Script:Config.PermissionColors['Deny']
                    'DENY: ' 
                } else { '' }
                
                $html += @"
                        <div class="folder-access" style="border-left-color: $color;" data-searchable="$($perm.RelativePath.ToLower())">
                            <div class="folder-name">&#128193; $([System.Web.HttpUtility]::HtmlEncode($perm.FolderName))</div>
                            <div class="folder-path">$([System.Web.HttpUtility]::HtmlEncode($perm.RelativePath))</div>
                            <span class="permission-badge" style="background-color: $color;">$accessType$($perm.SimplifiedRight)</span>
                            <div class="group-chain">
"@
                
                foreach ($group in $groups) {
                    if ($group.IsDirect -or $group.GroupName -eq "(Direct)") {
                        $html += "<span class='group-name'>$([System.Web.HttpUtility]::HtmlEncode($group.GroupName))</span>"
                    } else {
                        $pathStr = ($group.Path | ForEach-Object { 
                            if ($_ -eq "->") { "<span class='arrow'>→</span>" } 
                            else { "<span class='group-name'>$([System.Web.HttpUtility]::HtmlEncode($_))</span><br>" }
                        }) -join ""
                        $html += $pathStr
                    }
                    $html += " "
                }
                
                $html += @"
                            </div>
                        </div>
"@
            }
        }
        
        $html += @"
                    </div>
                </div>
"@
    }
    
    $html += @"
            </div>
        </div>
        
        <!-- Matrix View -->
        <div id="matrix-view" class="tab-content">
            <div class="matrix-container">
                <table class="matrix-table">
                    <thead>
                        <tr>
                            <th class="user-header">User</th>
"@

    # Add folder headers
    foreach ($folder in $folders) {
        $folderDisplay = if ($folder.RelativePath) { $folder.RelativePath } else { "(Root)" }
        $html += "<th class='folder-header' title='$([System.Web.HttpUtility]::HtmlEncode($folder.FolderPath))'>$([System.Web.HttpUtility]::HtmlEncode($folderDisplay))</th>"
    }
    
    $html += @"
                        </tr>
                    </thead>
                    <tbody>
"@

    # Add user rows
    foreach ($entry in ($AccessMap | Sort-Object { $_.User.DisplayName })) {
        $user = $entry.User
        $displayName = if ($user.DisplayName) { $user.DisplayName } else { $user.SamAccountName }
        
        if ($entry.FolderAccess.Count -eq 0 -and -not $IncludeEmptyUsers) { continue }
        
        $html += "<tr data-searchable='$($displayName.ToLower()) $($user.SamAccountName.ToLower())'>"
        $html += "<td class='user-cell'>$([System.Web.HttpUtility]::HtmlEncode($displayName))</td>"
        
        foreach ($folder in $folders) {
            if ($entry.FolderAccess.ContainsKey($folder.FolderPath)) {
                $access = $entry.FolderAccess[$folder.FolderPath]
                $perm = $access.Permission
                $color = $Script:Config.PermissionColors[$perm.SimplifiedRight]
                if (-not $color) { $color = '#666666' }
                if ($perm.AccessType -eq 'Deny') { $color = $Script:Config.PermissionColors['Deny'] }
                
                $groupNames = ($access.ViaGroups | ForEach-Object { $_.GroupName }) -join ", "
                $tooltip = "$($perm.SimplifiedRight) via: $groupNames"
                
                $html += "<td class='access-cell' style='background-color: $color;' title='$([System.Web.HttpUtility]::HtmlEncode($tooltip))'>&check;</td>"
            } else {
                $html += "<td class='access-cell no-access'></td>"
            }
        }
        
        $html += "</tr>"
    }
    
    $html += @"
                    </tbody>
                </table>
            </div>
        </div>
        
        <!-- Group Analysis View -->
        <div id="group-view" class="tab-content">
"@

    # Build group analysis
    $groupFolders = @{}
    $groupUsers = @{}
    
    foreach ($perm in $FolderPermissions) {
        if (-not $groupFolders.ContainsKey($perm.AccountName)) {
            $groupFolders[$perm.AccountName] = @()
        }
        $groupFolders[$perm.AccountName] += $perm
    }
    
    foreach ($entry in $AccessMap) {
        foreach ($folderAccess in $entry.FolderAccess.Values) {
            foreach ($group in $folderAccess.ViaGroups) {
                if (-not $groupUsers.ContainsKey($group.GroupName)) {
                    $groupUsers[$group.GroupName] = @()
                }
                $userName = if ($entry.User.DisplayName) { $entry.User.DisplayName } else { $entry.User.SamAccountName }
                if ($groupUsers[$group.GroupName] -notcontains $userName) {
                    $groupUsers[$group.GroupName] += $userName
                }
            }
        }
    }
    
    foreach ($group in ($Groups | Sort-Object Name)) {
        $groupName = if ($group.Name) { $group.Name } else { $group.SamAccountName }
        if (-not $groupName) { continue }
        
        $memberCount = if ($groupName -and $groupUsers.ContainsKey($groupName)) { $groupUsers[$groupName].Count } else { 0 }
        $folderCount = 0
        if ($groupName -and $groupFolders.ContainsKey($groupName)) { 
            $folderCount = $groupFolders[$groupName].Count 
        } elseif ($group.SamAccountName -and $groupFolders.ContainsKey($group.SamAccountName)) { 
            $folderCount = $groupFolders[$group.SamAccountName].Count 
        }
        
        $html += @"
            <div class="group-card" data-searchable="$($groupName.ToLower()) $($group.SamAccountName.ToLower())">
                <div class="group-header" onclick="toggleGroup(this)">
                    <span>&#128101; <strong>$([System.Web.HttpUtility]::HtmlEncode($groupName))</strong></span>
                    <span>$memberCount users | $folderCount folders</span>
                </div>
                <div class="group-body">
                    <div class="group-section">
                        <h4>Effective Users ($memberCount)</h4>
                        <div class="member-list">
"@
        
        if ($groupName -and $groupUsers.ContainsKey($groupName)) {
            foreach ($userName in ($groupUsers[$groupName] | Sort-Object)) {
                $html += "<span class='member-tag'>$([System.Web.HttpUtility]::HtmlEncode($userName))</span>"
            }
        } else {
            $html += "<span class='member-tag' style='color: var(--text-secondary);'>No users</span>"
        }
        
        $html += @"
                        </div>
                    </div>
                    <div class="group-section">
                        <h4>Folder Permissions ($folderCount)</h4>
                        <div class="folder-list">
"@
        
        $folderPerms = @()
        if ($groupName -and $groupFolders.ContainsKey($groupName)) { 
            $folderPerms = $groupFolders[$groupName] 
        } elseif ($group.SamAccountName -and $groupFolders.ContainsKey($group.SamAccountName)) { 
            $folderPerms = $groupFolders[$group.SamAccountName] 
        }
        
        foreach ($fp in $folderPerms) {
            $color = $Script:Config.PermissionColors[$fp.SimplifiedRight]
            if (-not $color) { $color = '#666666' }
            $html += "<span class='folder-tag' style='border-left: 3px solid $color; padding-left: 8px;'>$([System.Web.HttpUtility]::HtmlEncode($fp.RelativePath)) ($($fp.SimplifiedRight))</span>"
        }
        
        if ($folderPerms.Count -eq 0) {
            $html += "<span class='folder-tag' style='color: var(--text-secondary);'>No direct folder permissions</span>"
        }
        
        $html += @"
                        </div>
                    </div>
                </div>
            </div>
"@
    }
    
    $html += @"
        </div>
    </div>
    
    <div class="tooltip" id="tooltip"></div>
    
    <script>
        function showTab(tabId) {
            document.querySelectorAll('.tab-content').forEach(t => t.classList.remove('active'));
            document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
            document.getElementById(tabId).classList.add('active');
            event.target.classList.add('active');
        }
        
        function toggleGroup(header) {
            const body = header.nextElementSibling;
            body.classList.toggle('expanded');
        }
        
        function filterContent(searchTerm) {
            const term = searchTerm.toLowerCase();
            document.querySelectorAll('[data-searchable]').forEach(el => {
                const searchable = el.getAttribute('data-searchable');
                if (searchable.includes(term) || term === '') {
                    el.style.display = '';
                } else {
                    el.style.display = 'none';
                }
            });
        }
    </script>
</body>
</html>
"@

    # Save the HTML file
    $html | Out-File -FilePath $OutputFile -Encoding UTF8
    Write-Log "HTML report saved to: $OutputFile" -Level "SUCCESS"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

try {
    Write-Log "Starting User-Group-Folder Access Map generation..."
    Write-Log "Data Path: $DataPath"
    Write-Log "Depth: $Depth"
    Write-Log "User OU: $UserOU"
    Write-Log "Group OU: $GroupOU"
    
    # Validate path exists
    if (-not (Test-Path -Path $DataPath)) {
        throw "Data path does not exist: $DataPath"
    }
    
    # Import AD module
    Import-Module ActiveDirectory -ErrorAction Stop
    
    # Collect data
    $users = Get-ADUsersFromOU -OU $UserOU
    $groups = Get-ADGroupsFromOU -OU $GroupOU
    $folderPermissions = Get-FolderPermissions -Path $DataPath -Depth $Depth
    
    # Resolve nested group memberships
    $groupMemberships = Get-NestedGroupMembership -Groups $groups -GroupLookup @{}
    
    # Build access map
    $accessMap = Build-AccessMap -Users $users -Groups $groups -FolderPermissions $folderPermissions -GroupMemberships $groupMemberships
    
    # Generate output filename
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $outputFile = Join-Path -Path $OutputPath -ChildPath "AccessMap_$timestamp.html"
    
    # Generate HTML report
    Generate-HTMLReport -AccessMap $accessMap -FolderPermissions $folderPermissions -Groups $groups -DataPath $DataPath -OutputFile $outputFile
    
    # Open the report
    Write-Log "Opening report in default browser..."
    Start-Process $outputFile
    
    Write-Log "Script completed successfully!" -Level "SUCCESS"
}
catch {
    Write-Log "Script failed: $_" -Level "ERROR"
    Write-Log $_.ScriptStackTrace -Level "ERROR"
    throw
}
