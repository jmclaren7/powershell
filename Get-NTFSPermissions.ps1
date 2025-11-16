<# Get-NTFSPermissions.ps1
Version: 1.1
Date: 2025-11-13

.SYNOPSIS
    Retrieves NTFS permissions for a specified path.
.DESCRIPTION
    This script retrieves NTFS permissions for a specified directory or file path.
    It can include files, show permissions as objects, and include inherited permissions.
.PARAMETER Path
    The directory or file path to retrieve NTFS permissions from.
.PARAMETER IncludeFiles
    Include files in the permission report. By default, only directories are included.
.PARAMETER AsObject
    Output the permissions as objects instead of formatted text.
.PARAMETER IncludeInherited
    Include inherited permissions in the output.   
.EXAMPLE
    Get-NTFSPermissions.ps1 -Path "C:\MyFolder"

#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$Path,

    [switch]$IncludeFiles,

    [switch]$AsObject,

    [switch]$IncludeInherited
)

function Get-NtfsPermissionsData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResolvedPath,

        [switch]$IncludeFiles
    )

    $rootItem = Get-Item -LiteralPath $ResolvedPath -ErrorAction Stop

    $childParams = @{
        LiteralPath = $ResolvedPath
        Recurse     = $true
        Force       = $true
        ErrorAction = "SilentlyContinue"
    }

    if (-not $IncludeFiles) {
        $childParams["Directory"] = $true
    }

    $items = @()
    if ($rootItem.PSIsContainer) {
        $items = Get-ChildItem @childParams
    }

    $allItems = @($rootItem) + $items
    $normalizedRoot = $rootItem.FullName.TrimEnd([System.IO.Path]::DirectorySeparatorChar)

    foreach ($item in $allItems | Sort-Object FullName) {
        $fullPath = $item.FullName
        $relativePath = if ($fullPath.Equals($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            "."
        } else {
            $fullPath.Substring($normalizedRoot.Length + 1)
        }

        $depth = if ($relativePath -eq ".") { 0 } else { ($relativePath -split "[\\/]").Count }

        try {
            $acl = Get-Acl -LiteralPath $fullPath -ErrorAction Stop
        } catch {
            Write-Warning ("Failed to read ACL for {0}: {1}" -f $fullPath, $_.Exception.Message)
            continue
        }

        $rules = @($acl.Access | Sort-Object @{ Expression = { $_.IsInherited } }, IdentityReference, FileSystemRights)
        $explicitRules = @($rules | Where-Object { -not $_.IsInherited })

        $permissionDetails = foreach ($rule in $rules) {
            [PSCustomObject]@{
                IdentityReference = $rule.IdentityReference.Value
                AccessControlType = $rule.AccessControlType
                FileSystemRights  = [string]$rule.FileSystemRights
                IsInherited       = $rule.IsInherited
                InheritanceFlags  = $rule.InheritanceFlags
                PropagationFlags  = $rule.PropagationFlags
            }
        }

        [PSCustomObject]@{
            Path                   = $fullPath
            RelativePath           = $relativePath
            Depth                  = $depth
            ItemType               = if ($item.PSIsContainer) { "Directory" } else { "File" }
            InheritanceDisabled    = $acl.AreAccessRulesProtected
            HasExplicitPermissions = $explicitRules.Count -gt 0
            ExplicitRuleCount      = $explicitRules.Count
            InheritedRuleCount     = $rules.Count - $explicitRules.Count
            Permissions            = $permissionDetails
        }
    }
}

function Show-NtfsPermissionsTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject[]]$Report,
        [switch]$IncludeInherited = $false
    )

    if (-not $Report) {
        Write-Host "No permissions found in the specified location." -ForegroundColor Yellow
        return
    }

    # Warn if not running as administrator
    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
        Write-Host "This script is not running with administrator privileges. Some permissions may not be accessible." -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Options: " -ForegroundColor Cyan
    Write-Host "    -IncludeFiles"
    Write-Host "    -IncludeInherited"
    Write-Host "    -AsObject"
    Write-Host "Legend: " -ForegroundColor Cyan
    Write-Host "    [!] " -NoNewline -ForegroundColor Red
    Write-Host "inheritance disabled   "
    Write-Host "    [+] " -NoNewline -ForegroundColor Yellow
    Write-Host "explicit permissions present" 
    If ($IncludeFiles) {
        Write-Host "    abc " -NoNewline -ForegroundColor Magenta
        Write-Host "object is a file"
        
    }
    Write-Host "    Abc " -NoNewline -ForegroundColor DarkGray
    Write-Host "permission is inherited"
    Write-Host "  + Abc " -NoNewline -ForegroundColor White
    Write-Host "permission is explicit"
    Write-Host "Results:" -ForegroundColor Cyan

    $First = $true
    foreach ($entry in $Report | Sort-Object Depth, RelativePath) {
        $indent =  " " + ">" * ($entry.Depth) + " "
        $indent = ""
        $inheritanceMarker = if ($entry.InheritanceDisabled) { "!" } else { " " }
        $explicitMarker = if ($entry.HasExplicitPermissions) { "+" } else { " " }
        $indicator = "[{0}{1}]" -f $inheritanceMarker, $explicitMarker
        $lineColor = 
            if ($entry.ItemType -eq "File" -and ($entry.InheritanceDisabled -or $entry.HasExplicitPermissions)) { "Magenta" } 
            elseif ($entry.InheritanceDisabled) { "Red" } 
            elseif ($entry.HasExplicitPermissions) { "Yellow" } 
            else { "Gray" }

        # Only show entries with explicit permissions or inheritance disabled, or the first entry
        If ($IncludeInherited -or $entry.HasExplicitPermissions -or $entry.InheritanceDisabled -or $First) { 
            Write-Host ("{0}{1} {2}" -f $indent, $indicator, $entry.Path) -ForegroundColor $lineColor

            # Show detailed permissions
            foreach ($rule in $entry.Permissions) {
                if ($IncludeInherited -or -not $rule.IsInherited -or $First) {
                    $ruleIndent = " " * $indent.Length + " " * 2
                    $ruleMarker = if ($rule.IsInherited) { " " } else { "+" }
                    $ruleColor = if ($rule.IsInherited) { "DarkGray" } else { "White" }
                    
                    $Rights = $rule.FileSystemRights
                    $Rights = $Rights -replace "ReadAndExecute", "ReadExecute"
                    $Rights = $Rights -replace "FullControl", "Full"
                    $Rights = $Rights -replace "Synchronize", ""
                    $Rights = $Rights -replace "-?\d+", "Unknown"
                    $Rights = $Rights -replace "\s+", ""
                    $Rights = $Rights -replace ",,", ","
                    $Rights = $Rights.Trim(",")

                    $Extra = ""
                    If ($rule.AccessControlType -ne "Allow") {
                        $Extra += "Deny "
                    }
                    If ($rule.InheritanceFlags -ne "ContainerInherit, ObjectInherit") { 
                        $Extra += $rule.InheritanceFlags + " " -replace "None", "NoInherit"
                    }
                    
                    If ($rule.PropagationFlags -ne "None") { 
                        $Extra += $rule.PropagationFlags + " "
                    }
                    $Extra = $Extra.Trim() -replace " ", ","


                    $ruleText = "{0}{1} {2,-35} {3,-12} {4}" -f $ruleIndent, $ruleMarker, $rule.IdentityReference, $Rights, $Extra
                    Write-Host $ruleText -ForegroundColor $ruleColor

                }
            }
            $First = $false
    
        }
        
    }
}

try {
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
} catch {
    throw ("Unable to resolve path {0}: {1}" -f $Path, $_.Exception.Message)
}

$reportData = Get-NtfsPermissionsData -ResolvedPath $resolved -IncludeFiles:$IncludeFiles


if ($AsObject) {
    $reportData
} else {
    Show-NtfsPermissionsTree -Report $reportData -IncludeInherited:$IncludeInherited
}
