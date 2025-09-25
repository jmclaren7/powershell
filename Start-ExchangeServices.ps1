$services = get-wmiobject win32_service | ? {$_.displayname -like "Microsoft Exchange*" -and $_.StartMode -eq "Auto"}
foreach ($service in $services) {Start-Service $service.name}