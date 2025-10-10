$printerName = "Microsoft Print to PDF"
$printer = Get-Printer -Name $printerName -ErrorAction SilentlyContinue

if ($null -eq $printer) {
    return $false
}else {
    return $true
}