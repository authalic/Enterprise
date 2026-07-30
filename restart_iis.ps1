#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Continuously monitors an HTTP endpoint and restarts IIS when repeated
    health checks fail.

.DESCRIPTION
    The URL is checked at a configurable interval.

    A request is considered successful only when it returns HTTP status 200.

    A failure includes:
      - Request timeout
      - DNS or connection failure
      - TLS or certificate failure
      - Any HTTP status other than 200

    After the configured number of consecutive failures, the script restarts
    IIS by explicitly:

      1. Stopping W3SVC
      2. Stopping WAS
      3. Starting WAS
      4. Starting W3SVC
      5. Waiting for both services to reach Running
      6. Waiting for IIS applications to initialize
      7. Testing the URL again

    The script logs all health checks, service transitions, restart attempts,
    and errors.

.NOTES
    Run this script from an elevated PowerShell session or through a scheduled
    task configured with "Run with highest privileges."

    Stopping WAS may stop other dependent IIS services.
#>

[CmdletBinding()]
param (
    # URL that should return HTTP 200 when the application is healthy.
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Url = "https://central.udot.utah.gov/central/rest/services",

    # Number of minutes between routine health checks.
    [Parameter()]
    [ValidateRange(1, 1440)]
    [int]$CheckIntervalMinutes = 5,

    # Maximum number of seconds allowed for an HTTP request.
    [Parameter()]
    [ValidateRange(1, 600)]
    [int]$RequestTimeoutSeconds = 30,

    # Number of consecutive failed checks required before restarting IIS.
    [Parameter()]
    [ValidateRange(1, 100)]
    [int]$FailureThreshold = 3,

    # Minimum number of minutes between IIS restart attempts.
    [Parameter()]
    [ValidateRange(1, 1440)]
    [int]$RestartCooldownMinutes = 15,

    # Maximum time to wait for a service to stop.
    [Parameter()]
    [ValidateRange(10, 900)]
    [int]$ServiceStopTimeoutSeconds = 180,

    # Maximum time to wait for a service to start.
    [Parameter()]
    [ValidateRange(10, 900)]
    [int]$ServiceStartTimeoutSeconds = 180,

    # Pause after IIS starts before testing the web endpoint again.
    [Parameter()]
    [ValidateRange(0, 900)]
    [int]$ApplicationRecoverySeconds = 30,

    # Log file location.
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogPath = "D:\PowerShell\central_portal_connectivity\logs\IIS-HealthMonitor.log"
)


# ---------------------------------------------------------------------------
# Initial setup
# ---------------------------------------------------------------------------

$logDirectory = Split-Path -Path $LogPath -Parent

if (
    -not [string]::IsNullOrWhiteSpace($logDirectory) -and
    -not (Test-Path -LiteralPath $logDirectory)
) {
    New-Item `
        -Path $logDirectory `
        -ItemType Directory `
        -Force `
        -ErrorAction Stop |
        Out-Null
}


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

function Write-MonitorLog {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter()]
        [ValidateSet("INFO", "WARNING", "ERROR")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"

    Write-Host $entry

    try {
        Add-Content `
            -LiteralPath $LogPath `
            -Value $entry `
            -Encoding UTF8 `
            -ErrorAction Stop
    }
    catch {
        Write-Warning (
            "Unable to write to log file '$LogPath': " +
            $_.Exception.Message
        )
    }
}


# ---------------------------------------------------------------------------
# Administrative privilege validation
# ---------------------------------------------------------------------------

function Test-IsAdministrator {
    [CmdletBinding()]
    param ()

    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $principal = [Security.Principal.WindowsPrincipal]::new(
        $currentIdentity
    )

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}


# ---------------------------------------------------------------------------
# Service-state helpers
# ---------------------------------------------------------------------------

function Get-ServiceStateText {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServiceName
    )

    try {
        $service = Get-Service `
            -Name $ServiceName `
            -ErrorAction Stop

        return $service.Status.ToString()
    }
    catch {
        return "Unavailable"
    }
}


function Write-IISServiceStates {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]$Prefix = "IIS service states"
    )

    $wasState = Get-ServiceStateText -ServiceName "WAS"
    $w3svcState = Get-ServiceStateText -ServiceName "W3SVC"

    Write-MonitorLog -Message (
        "$Prefix`: WAS=$wasState; W3SVC=$w3svcState."
    )
}


function Wait-ServiceStatus {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [System.ServiceProcess.ServiceController]$Service,

        [Parameter(Mandatory)]
        [System.ServiceProcess.ServiceControllerStatus]$DesiredStatus,

        [Parameter(Mandatory)]
        [ValidateRange(1, 900)]
        [int]$TimeoutSeconds
    )

    # Refresh first so the ServiceController object does not use a stale state.
    $Service.Refresh()

    if ($Service.Status -eq $DesiredStatus) {
        return
    }

    $Service.WaitForStatus(
        $DesiredStatus,
        [TimeSpan]::FromSeconds($TimeoutSeconds)
    )

    # Refresh and independently verify the final state.
    $Service.Refresh()

    if ($Service.Status -ne $DesiredStatus) {
        throw (
            "Service '$($Service.Name)' did not reach state " +
            "'$DesiredStatus'. Current state: '$($Service.Status)'."
        )
    }
}


# ---------------------------------------------------------------------------
# HTTP health check
# ---------------------------------------------------------------------------

function Test-WebEndpoint {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Uri,

        [Parameter(Mandatory)]
        [ValidateRange(1, 600)]
        [int]$TimeoutSeconds
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $handler = $null
    $httpClient = $null
    $request = $null
    $response = $null
    $cancellationSource = $null

    try {
        $handler = [System.Net.Http.HttpClientHandler]::new()

        # Follow redirects, matching the prior Invoke-WebRequest behavior.
        $handler.AllowAutoRedirect = $true
        $handler.MaxAutomaticRedirections = 5

        $httpClient = [System.Net.Http.HttpClient]::new($handler)

        # Set an overall HttpClient timeout.
        $httpClient.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)

        $request = [System.Net.Http.HttpRequestMessage]::new(
            [System.Net.Http.HttpMethod]::Get,
            $Uri
        )

        # Add a per-request cancellation token as an additional timeout guard.
        $cancellationSource =
            [System.Threading.CancellationTokenSource]::new()

        $cancellationSource.CancelAfter(
            [TimeSpan]::FromSeconds($TimeoutSeconds)
        )

        # Complete when the HTTP response headers arrive.
        # Do not wait for or parse the entire response body.
        $task = $httpClient.SendAsync(
            $request,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead,
            $cancellationSource.Token
        )

        $response = $task.GetAwaiter().GetResult()

        $stopwatch.Stop()

        $statusCode = [int]$response.StatusCode

        return [PSCustomObject]@{
            Success        = ($statusCode -eq 200)
            StatusCode     = $statusCode
            StatusText     = $response.ReasonPhrase
            ErrorType      = $null
            ErrorMessage   = $null
            DurationMillis = $stopwatch.ElapsedMilliseconds
            CheckedAt      = Get-Date
        }
    }
    catch [System.OperationCanceledException] {
        $stopwatch.Stop()

        return [PSCustomObject]@{
            Success        = $false
            StatusCode     = $null
            StatusText     = $null
            ErrorType      = $_.Exception.GetType().FullName
            ErrorMessage   = (
                "HTTP request exceeded the configured timeout of " +
                "$TimeoutSeconds second(s)."
            )
            DurationMillis = $stopwatch.ElapsedMilliseconds
            CheckedAt      = Get-Date
        }
    }
    catch {
        $stopwatch.Stop()

        return [PSCustomObject]@{
            Success        = $false
            StatusCode     = $null
            StatusText     = $null
            ErrorType      = $_.Exception.GetType().FullName
            ErrorMessage   = $_.Exception.Message
            DurationMillis = $stopwatch.ElapsedMilliseconds
            CheckedAt      = Get-Date
        }
    }
    finally {
        if ($null -ne $response) {
            $response.Dispose()
        }

        if ($null -ne $request) {
            $request.Dispose()
        }

        if ($null -ne $cancellationSource) {
            $cancellationSource.Dispose()
        }

        if ($null -ne $httpClient) {
            $httpClient.Dispose()
        }

        if ($null -ne $handler) {
            $handler.Dispose()
        }
    }
}


function Write-HealthCheckResult {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject]$Result,

        [Parameter()]
        [int]$ConsecutiveFailures = 0,

        [Parameter()]
        [int]$FailureLimit = 0,

        [Parameter()]
        [string]$Context = "Health check"
    )

    if ($Result.Success) {
        Write-MonitorLog -Message (
            "$Context succeeded. HTTP status 200; " +
            "duration=$($Result.DurationMillis) ms."
        )

        return
    }

    $failureCountText = ""

    if ($FailureLimit -gt 0) {
        $failureCountText = (
            " Consecutive failures: $ConsecutiveFailures " +
            "of $FailureLimit."
        )
    }

    if ($null -ne $Result.StatusCode) {
        Write-MonitorLog `
            -Level "WARNING" `
            -Message (
                "$Context failed with HTTP status " +
                "$($Result.StatusCode)" +
                $(if ($Result.StatusText) {
                    " ($($Result.StatusText))"
                }
                else {
                    ""
                }) +
                "; duration=$($Result.DurationMillis) ms." +
                $failureCountText
            )
    }
    else {
        Write-MonitorLog `
            -Level "WARNING" `
            -Message (
                "$Context failed after $($Result.DurationMillis) ms. " +
                "Error type: $($Result.ErrorType). " +
                "Error: $($Result.ErrorMessage)." +
                $failureCountText
            )
    }
}


# ---------------------------------------------------------------------------
# IIS restart
# ---------------------------------------------------------------------------

function Restart-IISServices {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateRange(10, 900)]
        [int]$StopTimeoutSeconds,

        [Parameter(Mandatory)]
        [ValidateRange(10, 900)]
        [int]$StartTimeoutSeconds
    )

    try {
        Write-MonitorLog `
            -Level "WARNING" `
            -Message "Beginning IIS service restart."

        $w3svc = Get-Service `
            -Name "W3SVC" `
            -ErrorAction Stop

        $was = Get-Service `
            -Name "WAS" `
            -ErrorAction Stop

        Write-IISServiceStates -Prefix "Initial service states"

        # -------------------------------------------------------------------
        # Stop W3SVC
        # -------------------------------------------------------------------

        $w3svc.Refresh()

        if ($w3svc.Status -ne "Stopped") {
            Write-MonitorLog -Message "Stopping W3SVC."

            Stop-Service `
                -Name "W3SVC" `
                -Force `
                -ErrorAction Stop

            Wait-ServiceStatus `
                -Service $w3svc `
                -DesiredStatus (
                    [System.ServiceProcess.ServiceControllerStatus]::Stopped
                ) `
                -TimeoutSeconds $StopTimeoutSeconds

            Write-MonitorLog -Message "W3SVC reached the Stopped state."
        }
        else {
            Write-MonitorLog -Message "W3SVC is already stopped."
        }

        # -------------------------------------------------------------------
        # Stop WAS
        # -------------------------------------------------------------------

        $was.Refresh()

        if ($was.Status -ne "Stopped") {
            Write-MonitorLog -Message "Stopping WAS."

            Stop-Service `
                -Name "WAS" `
                -Force `
                -ErrorAction Stop

            Wait-ServiceStatus `
                -Service $was `
                -DesiredStatus (
                    [System.ServiceProcess.ServiceControllerStatus]::Stopped
                ) `
                -TimeoutSeconds $StopTimeoutSeconds

            Write-MonitorLog -Message "WAS reached the Stopped state."
        }
        else {
            Write-MonitorLog -Message "WAS is already stopped."
        }

        Write-IISServiceStates -Prefix "States after stopping IIS"

        # Allow worker processes and service handles a brief period to close.
        Write-MonitorLog `
            -Message "Waiting 5 seconds before starting IIS services."

        Start-Sleep -Seconds 5

        # -------------------------------------------------------------------
        # Start WAS
        # -------------------------------------------------------------------

        Write-MonitorLog -Message "Starting WAS."

        Start-Service `
            -Name "WAS" `
            -ErrorAction Stop

        Wait-ServiceStatus `
            -Service $was `
            -DesiredStatus (
                [System.ServiceProcess.ServiceControllerStatus]::Running
            ) `
            -TimeoutSeconds $StartTimeoutSeconds

        Write-MonitorLog -Message "WAS reached the Running state."

        # -------------------------------------------------------------------
        # Start W3SVC
        # -------------------------------------------------------------------

        Write-MonitorLog -Message "Starting W3SVC."

        Start-Service `
            -Name "W3SVC" `
            -ErrorAction Stop

        Wait-ServiceStatus `
            -Service $w3svc `
            -DesiredStatus (
                [System.ServiceProcess.ServiceControllerStatus]::Running
            ) `
            -TimeoutSeconds $StartTimeoutSeconds

        Write-MonitorLog -Message "W3SVC reached the Running state."

        # -------------------------------------------------------------------
        # Final validation
        # -------------------------------------------------------------------

        $was.Refresh()
        $w3svc.Refresh()

        Write-IISServiceStates -Prefix "Final service states"

        if (
            $was.Status -eq "Running" -and
            $w3svc.Status -eq "Running"
        ) {
            Write-MonitorLog `
                -Message "IIS service restart completed successfully."

            return $true
        }

        Write-MonitorLog `
            -Level "ERROR" `
            -Message (
                "IIS restart completed with unexpected service states. " +
                "WAS=$($was.Status); W3SVC=$($w3svc.Status)."
            )

        return $false
    }
    catch {
        $wasState = Get-ServiceStateText -ServiceName "WAS"
        $w3svcState = Get-ServiceStateText -ServiceName "W3SVC"

        Write-MonitorLog `
            -Level "ERROR" `
            -Message (
                "IIS restart encountered an error: " +
                "$($_.Exception.Message) " +
                "Current states: WAS=$wasState; W3SVC=$w3svcState."
            )

        return $false
    }
}


# ---------------------------------------------------------------------------
# Main monitoring loop
# ---------------------------------------------------------------------------

if (-not (Test-IsAdministrator)) {
    throw (
        "This script must run with administrative privileges because it " +
        "restarts the WAS and W3SVC services."
    )
}

# Confirm that the required services exist before entering the loop.
try {
    Get-Service -Name "WAS", "W3SVC" -ErrorAction Stop |
        Out-Null
}
catch {
    throw (
        "The required IIS services could not be found or accessed: " +
        $_.Exception.Message
    )
}

$consecutiveFailures = 0
$lastRestartAttempt = [datetime]::MinValue

Write-MonitorLog -Message "------------------------------------------------------------"
Write-MonitorLog -Message "Starting IIS HTTP health monitor."
Write-MonitorLog -Message "URL: $Url"
Write-MonitorLog -Message (
    "Check interval: $CheckIntervalMinutes minute(s); " +
    "request timeout: $RequestTimeoutSeconds second(s)."
)
Write-MonitorLog -Message (
    "Failure threshold: $FailureThreshold; restart cooldown: " +
    "$RestartCooldownMinutes minute(s)."
)
Write-MonitorLog -Message (
    "Service stop timeout: $ServiceStopTimeoutSeconds second(s); " +
    "service start timeout: $ServiceStartTimeoutSeconds second(s)."
)
Write-MonitorLog -Message (
    "Post-restart application recovery delay: " +
    "$ApplicationRecoverySeconds second(s)."
)
Write-MonitorLog -Message "Log file: $LogPath"
Write-IISServiceStates -Prefix "Startup service states"


while ($true) {
    try {
        Write-MonitorLog -Message (
            "Beginning health check for '$Url' with a " +
            "$RequestTimeoutSeconds-second timeout."
        )

        $result = Test-WebEndpoint `
            -Uri $Url `
            -TimeoutSeconds $RequestTimeoutSeconds

        if ($result.Success) {
            Write-HealthCheckResult `
                -Result $result `
                -Context "Health check"

            $consecutiveFailures = 0
        }
        else {
            $consecutiveFailures++

            Write-HealthCheckResult `
                -Result $result `
                -ConsecutiveFailures $consecutiveFailures `
                -FailureLimit $FailureThreshold `
                -Context "Health check"

            if ($consecutiveFailures -ge $FailureThreshold) {
                $currentTime = Get-Date

                $minutesSinceLastRestartAttempt = (
                    $currentTime - $lastRestartAttempt
                ).TotalMinutes

                if (
                    $minutesSinceLastRestartAttempt -ge
                    $RestartCooldownMinutes
                ) {
                    # Record the attempt time before beginning the restart.
                    # This prevents an immediate repeated attempt if the
                    # restart itself fails.
                    $lastRestartAttempt = $currentTime

                    Write-MonitorLog `
                        -Level "WARNING" `
                        -Message (
                            "Failure threshold reached. Attempting IIS restart."
                        )

                    $restartSucceeded = Restart-IISServices `
                        -StopTimeoutSeconds $ServiceStopTimeoutSeconds `
                        -StartTimeoutSeconds $ServiceStartTimeoutSeconds

                    # Start a new failure sequence after the restart attempt.
                    $consecutiveFailures = 0

                    if ($restartSucceeded) {
                        if ($ApplicationRecoverySeconds -gt 0) {
                            Write-MonitorLog -Message (
                                "Waiting $ApplicationRecoverySeconds " +
                                "second(s) for IIS applications to initialize."
                            )

                            Start-Sleep `
                                -Seconds $ApplicationRecoverySeconds
                        }

                        $verificationResult = Test-WebEndpoint `
                            -Uri $Url `
                            -TimeoutSeconds $RequestTimeoutSeconds

                        Write-HealthCheckResult `
                            -Result $verificationResult `
                            -Context "Post-restart health check"

                        if ($verificationResult.Success) {
                            Write-MonitorLog -Message (
                                "IIS recovery verification completed " +
                                "successfully."
                            )
                        }
                        else {
                            # Count the failed post-restart check as the first
                            # failure in a new sequence. The cooldown prevents
                            # another immediate restart.
                            $consecutiveFailures = 1

                            Write-MonitorLog `
                                -Level "WARNING" `
                                -Message (
                                    "The IIS services are running, but the " +
                                    "endpoint remains unhealthy. Restart " +
                                    "cooldown is now in effect."
                                )
                        }
                    }
                    else {
                        # Retain one failure following an unsuccessful restart
                        # so monitoring does not treat the application as
                        # healthy. The cooldown still prevents a restart loop.
                        $consecutiveFailures = 1

                        Write-MonitorLog `
                            -Level "ERROR" `
                            -Message (
                                "IIS restart was unsuccessful. Monitoring will " +
                                "continue, and the restart cooldown will apply."
                            )
                    }
                }
                else {
                    $remainingCooldownMinutes = [math]::Ceiling(
                        $RestartCooldownMinutes -
                        $minutesSinceLastRestartAttempt
                    )

                    Write-MonitorLog `
                        -Level "WARNING" `
                        -Message (
                            "IIS restart suppressed by the cooldown period. " +
                            "Approximately $remainingCooldownMinutes " +
                            "minute(s) remain."
                        )
                }
            }
        }
    }
    catch {
        # This protects the continuous loop from unexpected errors outside
        # the individual HTTP and service-management functions.
        Write-MonitorLog `
            -Level "ERROR" `
            -Message (
                "Unexpected monitoring-loop error: " +
                "$($_.Exception.Message)"
            )
    }

    Start-Sleep -Seconds ($CheckIntervalMinutes * 60)
}
