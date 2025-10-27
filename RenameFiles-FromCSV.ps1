param(
    [Parameter(Mandatory=$true)][string]$CsvPath,
    [Parameter(Mandatory=$true)][string]$RootPath,
    [switch]$Recurse,
    [switch]$DryRun
)

if (-not (Test-Path -LiteralPath $CsvPath)) { Write-Error "CSV not found: $CsvPath"; exit 1 }
if (-not (Test-Path -LiteralPath $RootPath)) { Write-Error "Root path not found: $RootPath"; exit 1 }

# Import CSV (no header expected): "old name,new name"
$map = Import-Csv -Path $CsvPath -Delimiter ',' -Header Old,New | ForEach-Object {
    [PSCustomObject]@{ Old = ($_.Old -as [string]).Trim(); New = ($_.New -as [string]).Trim() }
}

# Collect candidate folders
$folders = Get-ChildItem -LiteralPath $RootPath -Directory -Recurse:$Recurse

foreach ($m in $map) {
    Write-Host $("Processing rename: '$($m.Old)' -> '$($m.New)'") -ForegroundColor Cyan
    if ($m.Old -eq $m.New) {
        Write-Host "  Old and new names are the same, skipping." -ForegroundColor DarkGreen
        continue
    } elseif ([string]::IsNullOrWhiteSpace($m.New)) {
        Write-Host "  New name is empty, skipping." -ForegroundColor Yellow
        continue
    } elseif ([string]::IsNullOrWhiteSpace($m.New)) {
        Write-Host "  New name is empty, skipping." -ForegroundColor Yellow
        continue
    }
    $matches = $folders | Where-Object { $_.Name -eq $m.Old }
    if (-not $matches) {
        Write-Host "  No folder named '$($m.Old)' found under '$RootPath'." -ForegroundColor Yellow
        continue
    }elseif ($matches.count -gt 1) {
        Write-Host "  Multiple folders named '$($m.Old)' found under '$RootPath':" -ForegroundColor Yellow
        $matches | ForEach-Object { Write-Host "    - $($_.FullName)" -ForegroundColor Yellow }
        continue
    }

    foreach ($f in $matches) {
        $targetPath = Join-Path -Path $f.Parent.FullName -ChildPath $m.New
        if (Test-Path -LiteralPath $targetPath) {
            Write-Host "  Target already exists, skipping: $targetPath" -ForegroundColor Yellow
            continue
        }

        if ($DryRun) {
            Write-Host "  DryRun: Rename '$($f.FullName)' -> '$targetPath'" -ForegroundColor Magenta
        } else {
            try {
                Rename-Item -LiteralPath $f.FullName -NewName $m.New -ErrorAction Stop
                Write-Host "  Renamed: '$($f.FullName)' -> '$targetPath'" -ForegroundColor Green
            } catch {
                Write-Host "  Failed to rename '$($f.FullName)': $_" -ForegroundColor Red
            }
        }
    }
}