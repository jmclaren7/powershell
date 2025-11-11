# Define parameters
param (
    # Specify the folder path as a parameter
    [Parameter(Mandatory = $true)]
    [string]$FolderPath,
    # Create groups switch
    [switch]$CreateGroups,
    # Set permissions switch
    [switch]$SetPermissions,
    # All switch
    [switch]$All,
    # Prefix for group names (optional)
    [string]$GroupNamePrefix = ""
)

Write-Host "Starting AD group creation process for folders in '$FolderPath'..." -ForegroundColor Cyan

# Function to create AD group
function New-ADFolderGroup {
    param (
        [string]$GroupName,
        [string]$Description,
        [string[]]$MemberOf = @()
    )

    # Check if group already exists
    if (Get-ADGroup -Filter { Name -eq $GroupName } -ErrorAction SilentlyContinue) {
        Write-Host "Group '$GroupName' already exists. Skipping creation." -ForegroundColor Green
    } else {
        # Create the AD group
        if ($CreateGroups -or $All) {
            Write-Host "Creating group '$GroupName'..." -ForegroundColor Yellow
            New-ADGroup -Name $GroupName -GroupScope Global -GroupCategory Security -Description $Description
        }else{
            Write-Host "Dry-Run: Creating group '$GroupName'..." -ForegroundColor Yellow
        }
    }

    # Add group memberships if specified
    if ($MemberOf.Count -gt 0) {
        foreach ($ParentGroup in $MemberOf) {
            # Check if parent group exists
            if (-Not (Get-ADGroup -Filter { Name -eq $ParentGroup } -ErrorAction SilentlyContinue)) {
                Write-Host "Parent group '$ParentGroup' does not exist. Skipping membership addition." -ForegroundColor Red
                continue
            }

            # Check if the group is already a member
            if (Get-ADGroupMember -Identity $ParentGroup | Where-Object { $_.Name -eq $GroupName }) {
                Write-Host "'$GroupName' is already a member of '$ParentGroup'. Skipping addition." -ForegroundColor Green
                continue
            }

            # Add the group as a member of the parent group
            if ($CreateGroups -or $All) {
                Write-Host "Adding '$GroupName' as a member of '$ParentGroup'." -ForegroundColor Yellow
                Add-ADGroupMember -Identity $ParentGroup -Members $GroupName
            } else {
                Write-Host "Dry-Run: Adding '$GroupName' as a member of '$ParentGroup'." -ForegroundColor Yellow
            }
        }
    }
}

function Set-Permissions {
    param (
        [string]$FolderPath,
        [string]$GroupName,
        [string]$AccessRights
    )

    # Check if the group exists
    if (-Not (Get-ADGroup -Filter { Name -eq $GroupName } -ErrorAction SilentlyContinue)) {
        Write-Host "Group '$GroupName' does not exist. Cannot set permissions." -ForegroundColor Red
        return
    }

    # Get the security descriptor of the folder
    $Acl = Get-Acl -Path $FolderPath

    # Define the access rule
    $AccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($GroupName, $AccessRights, "ContainerInherit,ObjectInherit", "None", "Allow")

    # Add the access rule to the ACL
    $Acl.AddAccessRule($AccessRule)

    # Set the updated ACL back to the folder
    if ($SetPermissions -or $All) {
        Write-Host "Setting '$AccessRights' permissions for group '$GroupName' on folder '$FolderPath'." -ForegroundColor Yellow
        Set-Acl -Path $FolderPath -AclObject $Acl
    } else {
        Write-Host "Dry-Run: Setting '$AccessRights' permissions for group '$GroupName' on folder '$FolderPath'." -ForegroundColor Yellow
    }
}

# Import Active Directory module
Import-Module ActiveDirectory

# If no -CreateGroups, inform user that changes will not be applied
if (-Not $CreateGroups -and -Not $All) {
    Write-Host "Groups will not be created. Use -CreateGroups to create groups." -ForegroundColor Yellow
}

# If no -SetPermissions, inform user that permissions will not be set
if (-Not $SetPermissions -and -Not $All) {
    Write-Host "Permissions will not be set. Use -SetPermissions to set permissions." -ForegroundColor Yellow
}

# Check if folder exists, if not error out
if (-Not (Test-Path -Path $FolderPath)) {
    Write-Host "The specified folder path '$FolderPath' does not exist." -ForegroundColor Red
    exit
}

# Fix the path so case matches the real folder
$RootFolder = (Get-Item -Path $FolderPath)
$FolderPath = $RootFolder.FullName
Write-Host "Root folder detected: $FolderPath" -ForegroundColor Magenta
$RootFolder | select *
# If no prefix provided, set default as root folder name
if ([string]::IsNullOrWhiteSpace($GroupNamePrefix)) {
    $GroupNamePrefix = $RootFolder.Name
    $GroupNamePrefix = $GroupNamePrefix -replace '[^a-zA-Z0-9]', ''
}

# Create main groups for the root folder
New-ADFolderGroup -GroupName "$GroupNamePrefix--Read" -Description "Read access group for Data"
New-ADFolderGroup -GroupName "$GroupNamePrefix--Write" -Description "Write access group for Data" -MemberOf "$GroupNamePrefix--Read"
New-ADFolderGroup -GroupName "$GroupNamePrefix--Full" -Description "Full control access group for Data" -MemberOf "$GroupNamePrefix--Read", "$GroupNamePrefix--Write"

# Get SubFolders in the specified folder
$SubFolders = Get-ChildItem -Path $FolderPath -Directory

# Loop through each subfolder and create AD groups
foreach ($Subfolder in $SubFolders) {
    # Remove spaces and special characters from folder name for group naming
    $SafeFolderName = $Subfolder.Name -replace '[^a-zA-Z0-9]', ''

    Write-Host "Processing folder: $($Subfolder.FullName) with Safe Name: $SafeFolderName" -ForegroundColor Cyan

    $GroupNameRead = "$GroupNamePrefix-$SafeFolderName-Read"
    $GroupNameWrite = "$GroupNamePrefix-$SafeFolderName-Write"

    New-ADFolderGroup -GroupName $GroupNameRead -Description "Read access group for $($Subfolder.Name)"
    New-ADFolderGroup -GroupName $GroupNameWrite -Description "Write access group for $($Subfolder.Name)" -MemberOf $GroupNameRead
}


Write-Host "AD group creation process completed."