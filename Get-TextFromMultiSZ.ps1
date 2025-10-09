<#
.SYNOPSIS
    Converts REG_MULTI_SZ values from a .reg file to plain text.

.DESCRIPTION
    Reads a registry export (.reg) file and extracts all REG_MULTI_SZ values,
    converting them from hex format to readable text strings.

.PARAMETER Path
    Path to the .reg file to process.

.EXAMPLE
    .\Get-TextFromMultiSZ.ps1 -Path "C:\export.reg"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Path
)

# Verify the file exists
if (-not (Test-Path $Path)) {
    Write-Error "File not found: $Path"
    exit 1
}

# Read the file content
$fileContent = Get-Content -Path $Path -Raw

# Split into lines for processing
$lines = Get-Content -Path $Path

# Find and process all REG_MULTI_SZ values
$i = 0
$results = @()

while ($i -lt $lines.Count) {
    $line = $lines[$i]
    
    # Check if this line contains a REG_MULTI_SZ value
    if ($line -match '"([^"]+)"=hex\(7\):(.+)') {
        $valueName = $matches[1]
        $hexData = $matches[2]
        
        # Collect all continuation lines (lines ending with \)
        while ($hexData.TrimEnd() -match '\\$' -and ($i + 1) -lt $lines.Count) {
            $i++
            $hexData = $hexData.TrimEnd().TrimEnd('\') + $lines[$i].TrimStart()
        }
        
        # Remove any backslashes and whitespace
        $hexData = $hexData -replace '\\', '' -replace '\s+', ''
        
        # Convert hex data to bytes
        try {
            $hexValues = $hexData -split ','
            $bytes = $hexValues | Where-Object { $_ -ne '' } | ForEach-Object { 
                [byte]([convert]::ToInt32($_, 16))
            }
            
            # Convert bytes to Unicode string
            $multiString = [System.Text.Encoding]::Unicode.GetString($bytes)
            
            # Split by null terminators and remove empty entries
            $stringArray = ($multiString.TrimEnd("`0") -split "`0") | Where-Object { $_ -ne '' }
            
            # Create result object
            $result = [PSCustomObject]@{
                ValueName = $valueName
                Strings = $stringArray
                StringsJoined = ($stringArray -join ', ')
            }
            
            $results += $result
        }
        catch {
            Write-Warning "Failed to convert value '$valueName': $_"
        }
    }
    
    $i++
}

# Display results
if ($results.Count -eq 0) {
    Write-Host "No REG_MULTI_SZ values found in the file." -ForegroundColor Yellow
}
else {
    Write-Host "`nFound $($results.Count) REG_MULTI_SZ value(s):`n" -ForegroundColor Green
    
    foreach ($result in $results) {
        Write-Host "Value Name: " -NoNewline -ForegroundColor Cyan
        Write-Host $result.ValueName
        Write-Host "Strings:" -ForegroundColor Cyan
        foreach ($str in $result.Strings) {
            Write-Host "  - $str"
        }
        Write-Host ""
    }
}

# Return results for pipeline usage
return $results