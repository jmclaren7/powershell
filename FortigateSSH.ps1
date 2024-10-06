# Install Posh-SSH module if not already installed
if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
    Install-Module -Name Posh-SSH -Force
}

# Define the Fortigate firewall details
$server = ''  # Replace with your Fortigate firewall IP address
$username = ''  # Replace with your SSH username
$password = ''  # Replace with your SSH password

# Create a secure string for the password
$securePassword = ConvertTo-SecureString $password -AsPlainText -Force

# Create a PSCredential object
$creds = New-Object System.Management.Automation.PSCredential ($username, $securePassword)

# Establish SSH session
$session = New-SSHSession -ComputerName $server -Credential $creds -AcceptKey

# Execute a command
$command = @"
config firewall policy
edit 17
set status enable
end
"@

$result = Invoke-SSHCommand -SessionId $session.SessionId -Command $command
$result.Output

# Close the session
Remove-SSHSession -Session $session.SessionId