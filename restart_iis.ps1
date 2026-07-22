#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Periodically checks an HTTP URL and restarts IIS if repeated checks fail.
    Connectivity to Central portal server: /central is dropping out randomly
    exact cause is not yet known.
    restarting IIS restores connectivity through Web Adaptor and Load Balancer
    might be related to SentinelOne.  Still in research stages.

.DESCRIPTION
    A check is considered successful only when the server returns HTTP 200.

    IIS is restarted when:
      - The request times out
      - A connection or DNS error occurs
      - Any HTTP status other than 200 is returned

    Several consecutive failures are required before restarting W3SVC.
#>

param (
    [string]$Url = "https://central.udot.utah.gov/central/rest/services",

    # Time between checks
    [int]$CheckIntervalMinutes = 5,

    # Maximum time allowed for each HTTP request
    [int]$RequestTimeoutSeconds = 30,

    # Number of consecutive failures required before restarting IIS
    [int]$FailureThreshold = 3,

    # Prevent repeated restarts during a persistent outage
    [int]$RestartCooldownMinutes = 15,

    # Log file location
    [string]$LogPath = "D:\PowerShell\central_portal_connectivity\logs\IIS-HealthMonitor.log"
)


# Create the log directory if it does not already exist.
$logDirectory = Split-Path -Path $LogPath -Parent

if ($logDirectory -and -not (Test-Path -LiteralPath $logDirectory)) {
    New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
}


function Write-MonitorLog {
    param (
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet("INFO", "WARNING", "ERROR")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"

    Write-Host $entry
    Add-Content -LiteralPath $LogPath -Value $entry
}


function Test-WebEndpoint {
    param (
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds
    )

    try {
        $response = Invoke-WebRequest `
            -Uri $Uri `
            -Method Get `
            -TimeoutSec $TimeoutSeconds `
            -UseBasicParsing `
            -ErrorAction Stop

        return [PSCustomObject]@{
            Success    = ($response.StatusCode -eq 200)
            StatusCode = [int]$response.StatusCode
            Error      = $null
        }
    }
    catch {
        # Invoke-WebRequest normally throws an exception for HTTP 4xx and 5xx
        # responses. Attempt to extract the returned HTTP status code.
        $statusCode = $null

        if ($null -ne $_.Exception.Response) {
            try {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            catch {
                $statusCode = $null
            }
        }

        return [PSCustomObject]@{
            Success    = $false
            StatusCode = $statusCode
            Error      = $_.Exception.Message
        }
    }
}


function Restart-IISService {
    try {
        Write-MonitorLog `
            -Level "WARNING" `
            -Message "Restarting the Windows Process Activation Service and IIS service."

        # Restarting WAS also restarts dependent W3SVC cleanly.
        Restart-Service `
            -Name "WAS" `
            -Force `
            -ErrorAction Stop

        # Wait for W3SVC to reach Running status.
        $service = Get-Service -Name "W3SVC"
        $service.WaitForStatus(
            [System.ServiceProcess.ServiceControllerStatus]::Running,
            [TimeSpan]::FromSeconds(60)
        )

        Write-MonitorLog -Message "IIS restart completed successfully."
        return $true
    }
    catch {
        Write-MonitorLog `
            -Level "ERROR" `
            -Message "IIS restart failed: $($_.Exception.Message)"

        return $false
    }
}


$consecutiveFailures = 0
$lastRestartTime = [datetime]::MinValue

Write-MonitorLog -Message (
    "Starting HTTP monitor. URL='$Url'; " +
    "interval=$CheckIntervalMinutes minute(s); " +
    "timeout=$RequestTimeoutSeconds second(s); " +
    "failure threshold=$FailureThreshold."
)


while ($true) {
    $result = Test-WebEndpoint `
        -Uri $Url `
        -TimeoutSeconds $RequestTimeoutSeconds

    if ($result.Success) {
        Write-MonitorLog -Message "Health check succeeded. HTTP status: 200."
        $consecutiveFailures = 0
    }
    else {
        $consecutiveFailures++

        if ($null -ne $result.StatusCode) {
            Write-MonitorLog `
                -Level "WARNING" `
                -Message (
                    "Health check failed with HTTP status " +
                    "$($result.StatusCode). Consecutive failures: " +
                    "$consecutiveFailures of $FailureThreshold."
                )
        }
        else {
            Write-MonitorLog `
                -Level "WARNING" `
                -Message (
                    "Health check failed: $($result.Error) " +
                    "Consecutive failures: $consecutiveFailures " +
                    "of $FailureThreshold."
                )
        }

        if ($consecutiveFailures -ge $FailureThreshold) {
            $minutesSinceRestart = (
                (Get-Date) - $lastRestartTime
            ).TotalMinutes

            if ($minutesSinceRestart -ge $RestartCooldownMinutes) {
                $restartSucceeded = Restart-IISService

                if ($restartSucceeded) {
                    $lastRestartTime = Get-Date
                }

                # Begin a new failure count following the restart attempt.
                $consecutiveFailures = 0
            }
            else {
                $remainingMinutes = [math]::Ceiling(
                    $RestartCooldownMinutes - $minutesSinceRestart
                )

                Write-MonitorLog `
                    -Level "WARNING" `
                    -Message (
                        "Restart suppressed by cooldown period. " +
                        "Approximately $remainingMinutes minute(s) remaining."
                    )
            }
        }
    }

    Start-Sleep -Seconds ($CheckIntervalMinutes * 60)
}
