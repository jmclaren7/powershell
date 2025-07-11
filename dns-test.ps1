$domain = "johnscs.com"
$interval = 1 # seconds

while ($true) {
    try {
        Resolve-DnsName -Name $domain
        Write-Host "DNS resolution successful for $domain"
        #Write-Host $result
    } catch {
        Write-Host "DNS resolution failed for $domain"
    }
    Start-Sleep -Seconds $interval
}