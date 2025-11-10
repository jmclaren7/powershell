# Function to create AD group
function New-ADGroup {
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
        if ($CreateGroups) {
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
                Write-Error "Parent group '$ParentGroup' does not exist. Skipping membership addition."
                continue
            }

            # Check if the group is already a member
            if (Get-ADGroupMember -Identity $ParentGroup | Where-Object { $_.Name -eq $GroupName }) {
                Write-Host "'$GroupName' is already a member of '$ParentGroup'. Skipping addition." -ForegroundColor Green
                continue
            }

            # Add the group as a member of the parent group
            if ($CreateGroups) {
                Write-Host "Adding '$GroupName' as a member of '$ParentGroup'." -ForegroundColor Yellow
                Add-ADGroupMember -Identity $ParentGroup -Members $GroupName
            }else{
                Write-Host "Dry-Run: Adding '$GroupName' as a member of '$ParentGroup'." -ForegroundColor Yellow}
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
        Write-Error "Group '$GroupName' does not exist. Cannot set permissions."
        return
    }

    # Get the security descriptor of the folder
    $Acl = Get-Acl -Path $FolderPath

    # Define the access rule
    $AccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($GroupName, $AccessRights, "ContainerInherit,ObjectInherit", "None", "Allow")

    # Add the access rule to the ACL
    $Acl.AddAccessRule($AccessRule)

    # Set the updated ACL back to the folder
    if ($SetPermissions) {
        Write-Host "Setting '$AccessRights' permissions for group '$GroupName' on folder '$FolderPath'." -ForegroundColor Yellow
        Set-Acl -Path $FolderPath -AclObject $Acl
    } else {
        Write-Host "Dry-Run: Setting '$AccessRights' permissions for group '$GroupName' on folder '$FolderPath'." -ForegroundColor Yellow
    }
}

# Import Active Directory module
Import-Module ActiveDirectory

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
    [switch]$All
)

# If no -CreateGroups, inform user that changes will not be applied
if (-Not $CreateGroups) {
    Write-Host "Groups will not be created. Use -CreateGroups to create groups." -ForegroundColor Yellow
}

# If no -SetPermissions, inform user that permissions will not be set
if (-Not $SetPermissions) {
    Write-Host "Permissions will not be set. Use -SetPermissions to set permissions." -ForegroundColor Yellow
}

# Check if folder exists, if not error out
if (-Not (Test-Path -Path $FolderPath)) {
    Write-Host "The specified folder path '$FolderPath' does not exist." -ForegroundColor Red
    exit
}

New-ADGroup -GroupName "DataRoot-Read" -Description "Read access group for Data"
New-ADGroup -GroupName "DataRoot-Write" -Description "Write access group for Data" -MemberOf "DataRoot-Read"
New-ADGroup -GroupName "DataRoot-Full" -Description "Full control access group for Data" -MemberOf "DataRoot-Read", "DataRoot-Write"

# Get SubFolders in the specified folder
$SubFolders = Get-ChildItem -Path $FolderPath -Directory

# Loop through each subfolder and create AD groups
foreach ($Subfolder in $SubFolders) {
    # Remove spaces and special characters from folder name for group naming
    $SafeFolderName = $Subfolder.Name -replace '[^a-zA-Z0-9]', ''

    Write-Host "Processing folder: $($Subfolder.FullName) with Safe Name: $SafeFolderName" -ForegroundColor Cyan

    $GroupNameRead = "Data-$SafeFolderName-Read"
    $GroupNameWrite = "Data-$SafeFolderName-Write"

    New-ADGroup -GroupName $GroupNameRead -Description "Read access group for $($Subfolder.Name)"
    New-ADGroup -GroupName $GroupNameWrite -Description "Write access group for $($Subfolder.Name)" -MemberOf $GroupNameRead
}


Write-Host "AD group creation process completed."