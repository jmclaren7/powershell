<#+
.SYNOPSIS
Generates OpenSSL-based root CA and service certificates.

.DESCRIPTION
- Runs interactively to collect information. 
- Ensures OpenSSL is available (offering to install the ShiningLight distribution via winget when missing)
- Creates a password-protected root CA key/certificate and service-specific keys, CSRs, and signed certificates in the script directory. 
- Previously entered defaults are cached in `settings.json`.

.EXAMPLE
pwsh .\Build-SSLCertificates.ps1

.NOTES
- Requires OpenSSL 1.1+ in PATH; the script can add `C:\Program Files\OpenSSL-Win64\bin` automatically.
- Outputs keys, CSRs, certificates, and extension files to the script directory using the provided identifier.
- Keep private keys secure; they are generated with AES-256 encryption but still require safeguarding.
#>

$StoragePath = $PSScriptRoot
# Script to setup some basic certificates

$StoragePath = $PSScriptRoot
Set-Location $StoragePath

# Function to ask user for input with default value
function Read-HostWithDefault {
    param (
        [string]$Prompt,
        [string]$Default,
        [switch]$UseDefault,
        [string]$SecondaryDefault
    )
    if ($Default -and $UseDefault) {
        return $Default
    }elseif ($SecondaryDefault -and $UseDefault) {
        $Default = $SecondaryDefault
    }

    $UserInput = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($UserInput)) {
        return $Default
    } else {
        return $UserInput
    }
}   

# Ask user for ID, country, state. Look for settings.json
$SettingsFile = Join-Path $PSScriptRoot "settings.json"
$Settings = @{}

if (Test-Path $SettingsFile) {
    $Settings = Get-Content $SettingsFile | ConvertFrom-Json
}

$ID = Read-HostWithDefault "Enter ID" $Settings.ID -UseDefault
$Country = Read-HostWithDefault "Enter Country (2 letter code)" $Settings.Country -UseDefault "US"
$State = Read-HostWithDefault "Enter State/Province" $Settings.State -UseDefault

# Save settings to settings.json
$Settings = @{
    ID      = $ID
    Country = $Country
    State   = $State
}
$Settings | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding ascii

# If OpenSSL not found
if (!(Get-Command openssl -ErrorAction SilentlyContinue)) {
    # Check C:\Program Files\OpenSSL-Win64\bin\openssl.exe
    $OpenSSLPath = "C:\Program Files\OpenSSL-Win64\bin\openssl.exe"
    if (Test-Path $OpenSSLPath) {
        $env:Path += ";C:\Program Files\OpenSSL-Win64\bin"
    }else {
        # Ask to install with winget
        $install = Read-HostWithDefault "Install ShiningLight.OpenSSL.Light using winget? (Y/N)" "Y"
        if ($install -eq "Y") {
            winget install -e --id ShiningLight.OpenSSL.Light
        } else {
            exit
        }

        # Check again
        if (Test-Path $OpenSSLPath) {
            $env:Path += ";C:\Program Files\OpenSSL-Win64\bin"
        } else {
            Write-Host "OpenSSL installation failed or not found. Please install OpenSSL manually." -ForegroundColor Red
            exit
        }
    }
}

# Verify OpenSSL is now available
if (!(Get-Command openssl -ErrorAction SilentlyContinue)) {
    Write-Host "OpenSSL not found in PATH. Please ensure OpenSSL is installed and added to PATH." -ForegroundColor Red
    exit
} else {
    $opensslVersion = & openssl version
    Write-Host "OpenSSL found: $opensslVersion" -ForegroundColor Green
}

# If private key doesn't already exist
$RootPrivateKey = "${ID}_root_private.key"
if (!(Test-Path $RootPrivateKey)) {
    Write-Host "Root private key not found, generating... $RootPrivateKey" -ForegroundColor Cyan
    openssl genrsa -aes256 -out $RootPrivateKey 2048
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to generate root private key." -ForegroundColor Red
        exit
    }
}else {
    Write-Host "Root private key found: $RootPrivateKey" -ForegroundColor Green
}

# If root CA cert doesn't already exist
$RootCACert = "${ID}_root_ca.crt"
if (!(Test-Path $RootCACert)) {
    Write-Host "Root CA certificate not found, generating... $RootCACert" -ForegroundColor Cyan
    $Subject = "/C=$($Country)/ST=$($State)/L=/O=${ID}/OU=${ID}/CN="
    openssl req -new -x509 -days 3650 -extensions v3_ca -key $RootPrivateKey -out $RootCACert -subj $Subject -batch
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to generate root CA certificate." -ForegroundColor Red
        exit
    }
}else {
    Write-Host "Root CA certificate found: $RootCACert" -ForegroundColor Green
}

While ($true) {
    # Discover existing service tags from previously generated private keys
    $existingServiceTags = @(Get-ChildItem -File -Filter "${ID}_*_private.key" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match "^${ID}_(.+?)_private\.key$" -and $_.Name -notlike "*_root*") { $Matches[1] }
    } | Sort-Object -Unique)

    if ($existingServiceTags.Count -gt 0) {
        Write-Host ""
        Write-Host "Known service tags:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $existingServiceTags.Count; $i++) {
            Write-Host ("  [{0}] {1}" -f ($i + 1), $existingServiceTags[$i])
        }
        $HintText = "# to select, "
    }

    $userInput = Read-Host "Enter service tag (${HintText}blank to exit)"
    if ([string]::IsNullOrWhiteSpace($userInput)) { break }

    if ($userInput -as [int] -and $userInput -ge 1 -and $userInput -le $existingServiceTags.Count) {
        $ServiceTag = $existingServiceTags[$userInput - 1]
        Write-Host "Selected existing tag: $ServiceTag" -ForegroundColor Green
    } else {
        $ServiceTag = $userInput.Trim()
    }

    if (-not $ServiceTag) { continue }

    # If service specific private key doesn't already exist
    $ServicePrivateKey = "${ID}_${ServiceTag}_private.key"
    if (!(Test-Path $ServicePrivateKey)) {
        Write-Host "${ServiceTag} private key not found, generating..." -ForegroundColor Cyan
        openssl genrsa -aes256 -out $ServicePrivateKey 2048
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Failed to generate ${ServiceTag} private key." -ForegroundColor Red
            continue
        }
    }else {
        Write-Host "${ServiceTag} private key found: $ServicePrivateKey" -ForegroundColor Green
    }

    # Generate CSR from service specific private key (Skip challenge and company):
    $ServiceCSR = "${ID}_${ServiceTag}.csr"
    if (!(Test-Path $ServiceCSR)) {
        Write-Host "${ServiceTag} CSR not found, generating..." -ForegroundColor Cyan
        $Subject = "/C=${Country}/ST=${State}/L=/O=${ID}/OU=${ID}/CN="
        openssl req -new -key $ServicePrivateKey -out $ServiceCSR -subj $Subject -batch
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Failed to generate ${ServiceTag} CSR." -ForegroundColor Red
            continue
        }
    }else {
        Write-Host "${ServiceTag} CSR found: $ServiceCSR" -ForegroundColor Green
    }

    # Sign and generate service certificate from CSR using root CA (with SANs):
    $ServiceCert = "${ID}_${ServiceTag}.crt"
    if (!(Test-Path $ServiceCert)) {
        Write-Host "Signing certificate (using ext file)..." -ForegroundColor Cyan

        $ExtFile = "${ID}_${ServiceTag}.ext"

        # If the ext file already exists, get the alt names from [alt_names] section and add them to an array
        if (Test-Path $ExtFile) {
            $existingAltNames = Get-Content -Path $ExtFile | Select-String -Pattern '(?:DNS|IP)\.\d+\s*=\s*(.+)' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() }
        }

        # Ask the user for what SANs they want to use and use $existingAltNames
        $userInput = Read-HostWithDefault "Enter SANs (comma separated) or press Enter to use existing" ($existingAltNames -join ', ')

        if ($userInput) {
            $SANs = @($userInput -split ',' | ForEach-Object { $_.Trim() })
            # Go through SANs and add DNS. or IP. as needed
            for ($i = 0; $i -lt $SANs.Count; $i++) {
                if ($SANs[$i] -match '^\d{1,3}(\.\d{1,3}){3}$') {
                    $SANs[$i] = "IP." + ($i + 1) + "=" + $SANs[$i]
                } else {
                    $SANs[$i] = "DNS." + ($i + 1) + "=" + $SANs[$i]
                }
            }
            
            # Create ext file content
            $extLines = @(
                'basicConstraints=CA:FALSE'
                'keyUsage=digitalSignature,nonRepudiation,keyEncipherment,dataEncipherment'
                'extendedKeyUsage=serverAuth,clientAuth'
                'subjectKeyIdentifier=hash'
                'authorityKeyIdentifier=keyid,issuer'
                'subjectAltName = @alt_names'
                '[alt_names]'
            ) + $SANs
            $extContent = $extLines -join "`n"

            $extContent | Set-Content -Encoding ascii $ExtFile

            openssl x509 -req -in $ServiceCSR -CA "${ID}_root_ca.crt" -CAkey "${ID}_root_private.key" -CAcreateserial -out $ServiceCert -days 3650 -sha256 -extfile $ExtFile
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Failed to generate service certificate." -ForegroundColor Red
                continue
            } elseif ((Test-Path $ServiceCert) -and (Get-Item $ServiceCert).Length -gt 0) {
                Write-Host "Service certificate generated: $ServiceCert" -ForegroundColor Green
            } else {
                Write-Host "Failed to generate service certificate (unknown error)." -ForegroundColor Red
            }

        } else {
            Write-Host "No SANs provided and no existing SANs found. Skipping certificate generation." -ForegroundColor Yellow
        }
    }   else {
        Write-Host "Certificate already exists, did not regenerate: $ServiceCert" -ForegroundColor Yellow
    }

    
}

Write-Host "Hints:" -ForegroundColor Cyan
Write-Host "  Fortigate: Service .crt and .key can be imported: Import > Certificate > Certificate"
Write-Host "  Windows CA: Root CA .crt can be used in the ""Trusted Root Certificate Authority"""

<# Ext File Example
basicConstraints=CA:FALSE
keyUsage=digitalSignature,nonRepudiation,keyEncipherment,dataEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
subjectAltName = @alt_names
[alt_names]
DNS.1 = *.local.domain.net
IP.1 = 123.123.1.1
#>
