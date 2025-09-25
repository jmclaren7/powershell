function Measure-TcpPortLatency {
    <#
.SYNOPSIS
    Measures the connection latency to a specific TCP port on a remote host.

.DESCRIPTION
    This function creates a .NET TcpClient object, attempts to connect to the
    specified host and port, and measures the time it takes to establish the connection.
    This provides a more accurate latency measurement than Test-NetConnection for a
    specific TCP port.

.PARAMETER ComputerName
    The hostname or IP address of the remote machine to test.

.PARAMETER Port
    The TCP port number to connect to.

.EXAMPLE
    Measure-TcpPortLatency -ComputerName "google.com" -Port 443

    This command measures the latency to Google's HTTPS port (443).

.EXAMPLE
    Measure-TcpPortLatency -ComputerName "192.168.1.1" -Port 3389

    This command measures the latency to a local machine's RDP port.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$ComputerName,

        [Parameter(Mandatory=$true)]
        [int]$Port
    )

    try {
        # Initialize a new TcpClient object
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        
        # Start the stopwatch
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        
        # Attempt to connect to the remote host and port
        $connectTask = $tcpClient.ConnectAsync($ComputerName, $Port)
        
        # Wait for the connection to complete with a timeout (e.g., 5 seconds)
        $connectTask.Wait(5000) | Out-Null
        
        $stopwatch.Stop()
        
        if ($tcpClient.Connected) {
            # Connection was successful, get the elapsed time
            $latency = $stopwatch.Elapsed.TotalMilliseconds
            Write-Output "Successfully connected to $ComputerName on port $Port in $latency ms."
        }
        else {
            # Connection failed or timed out
            throw "Connection to $ComputerName on port $Port failed or timed out."
        }
    }
    catch {
        Write-Error $_.Exception.Message
    }
    finally {
        # Clean up the TcpClient object
        if ($tcpClient.Connected) {
            $tcpClient.Close()
        }
    }
}