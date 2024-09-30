<#
.SYNOPSIS
    This script finds local administrators of client computers in your domain and outputs them as an object.

.DESCRIPTION
    This script will find local administrators of client computers in your domain and output them as an object.

.PARAMETER Path
    This will be the DN of the OU or search scope. Simply copy the DN of the OU in which you want to query for local admins. If not defined, the whole domain will be considered as the search scope.

.PARAMETER ComputerName
    This parameter defines the computer account in which the function will run against. If not specified, all computers will be considered as the search scope and consequently, this function will get local admins of all computers. You can define multiple computers by utilizing a comma (,).

.EXAMPLE
    C:\PS> Get-LocalAdmin
    
    This command will get local admins of all computers in the domain.

    C:\PS> Get-LocalAdmin -ComputerName PC1,PC2,PC3

    This command will get local admins of PC1, PC2, and PC3.

    C:\PS> Get-LocalAdmin -Path "OU=Computers,DC=Contoso,DC=com"

.NOTES
    Author: Mahdi Tehrani
    Date  : February 18, 2017   
#>

Import-Module ActiveDirectory

Function Get-LocalAdmin {
    Param(
        [string]$Path = (Get-ADDomain).DistinguishedName,   
        [array]$ComputerName = (Get-ADComputer -Filter * -Server (Get-ADDomain).DNSRoot -SearchBase $Path -Properties Enabled | Where-Object {$_.Enabled -eq $true}).Name
    )

    $Table = @()
    $Counter = 0
    $TotalComputers = $ComputerName.Count

    foreach ($Computer in $ComputerName) {
        try {
            $PC = Get-ADComputer $Computer
            $Name = $PC.Name
        } catch {
            Write-Error "Cannot retrieve computer $Computer"
            continue
        }

        $Counter++
        Write-Progress -Activity "Connecting PC $Counter/$TotalComputers" -Status "Querying ($Name)" -PercentComplete (($Counter / $TotalComputers) * 100)

        try {
            $members = [ADSI]"WinNT://$Name/Administrators"
            $members = @($members.psbase.Invoke("Members"))
            $LocalAdmins = $members | ForEach-Object {
                $_.GetType().InvokeMember("Name", 'GetProperty', $null, $_, $null)
            }

            $obj = [PSCustomObject]@{
                ComputerName = $Name
                LocalAdmins  = $LocalAdmins -join "; "
            }
            $Table += $obj

            Write-Host "Computer ($Name) has been queried." -ForegroundColor Green -BackgroundColor Black
        } catch {
            Write-Error "Error accessing ($Name)"
        }
    }

    return $Table
}

# Example usage
$localAdminsReport = Get-LocalAdmin
$localAdminsReport