#Requires -Version 7.0
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Monitors multiple HTTP/HTTPS endpoints and restarts IIS when repeated
    monitoring cycles fail.

.DESCRIPTION
    All configured URLs are checked in parallel.

    An endpoint is considered healthy only when it returns HTTP status 200.

    A monitoring cycle fails if ANY monitored endpoint:
      - Times out
      - Cannot be reached
      - Encounters a DNS, TLS, or connection error
      - Returns an HTTP status other than 200

    After a failed monitoring cycle, the script retries after a shorter
    configurable interval.

    After the configured number of consecutive failed monitoring cycles,
    the script restarts IIS by explicitly:

      1. Stopping W3SVC
      2. Stopping WAS
      3. Starting WAS
      4. Starting W3SVC
      5. Waiting for both services to reach Running
      6. Waiting for IIS applications to initialize
      7. Testing all monitored URLs again

    The script is intended for PowerShell 7 running directly on the
    Windows IIS server handling traffic for the monitored endpoints.
#>

[CmdletBinding()]
param (
    # -----------------------------------------------------------------------
    # URLs to monitor.
    #
    # Add or remove URLs from this array as needed.
    # Every URL must return HTTP 200 for the monitoring cycle to succeed.
    # -----------------------------------------------------------------------

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$Urls = @(
        "https://roads.udot.utah.gov/server/rest/services"
    ),

    # Number of minutes between checks when all endpoints are healthy.
    [Parameter()]
    [ValidateRange(1, 1440)]
    [int]$CheckIntervalMinutes = 5,

    # Number of seconds between checks following a failed monitoring cycle.
    [Parameter()]
    [ValidateRange(1, 3600)]
    [int]$FailureRetrySeconds = 30,

    # Maximum time allowed for each individual HTTP request.
    [Parameter()]
    [ValidateRange(1, 600)]
    [int]$RequestTimeoutSeconds = 30,

    # Number of consecutive failed monitoring cycles required before restarting IIS.
    [Parameter()]
    [ValidateRange(1, 100)]
    [int]$FailureThreshold = 3,

    # Minimum number of minutes allowed between IIS restart attempts.
    [Parameter()]
    [ValidateRange(1, 1440)]
    [int]$RestartCooldownMinutes = 15,

    # Maximum time to wait for an IIS service to stop.
    [Parameter()]
    [ValidateRange(10, 900)]
    [int]$ServiceStopTimeoutSeconds = 180,

    # Maximum time to wait for an IIS service to start.
    [Parameter()]
    [ValidateRange(10, 900)]
    [int]$ServiceStartTimeoutSeconds = 180,

    # Amount of time to wait after IIS has restarted before performing the post-restart health check.
    [Parameter()]
    [ValidateRange(0, 900)]
    [int]$ApplicationRecoverySeconds = 30,

    # Log file location.
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogPath = "D:\PowerShell\roads_portal_connectivity\logs\IIS-HealthMonitor.log"

)


# ===========================================================================
# Initial setup
# ===========================================================================

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


# ===========================================================================
# Logging
# ===========================================================================

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


# ===========================================================================
# Administrative privilege check
# ===========================================================================

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


# ===========================================================================
# Service-state functions
# ===========================================================================

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

    # Refresh the ServiceController object so it does not contain a stale cached service state.
    $Service.Refresh()

    if ($Service.Status -eq $DesiredStatus) {
        return
    }

    $Service.WaitForStatus(
        $DesiredStatus,
        [TimeSpan]::FromSeconds($TimeoutSeconds)
    )

    # Verify the state independently after WaitForStatus returns.
    $Service.Refresh()

    if ($Service.Status -ne $DesiredStatus) {
        throw (
            "Service '$($Service.Name)' did not reach state " +
            "'$DesiredStatus'. Current state: '$($Service.Status)'."
        )
    }
}


# ===========================================================================
# HTTP endpoint monitoring
# ===========================================================================

function Test-AllWebEndpoints {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Uris,

        [Parameter(Mandatory)]
        [ValidateRange(1, 600)]
        [int]$TimeoutSeconds
    )

    # -----------------------------------------------------------------------
    # One HttpClient is shared by all requests in this monitoring cycle.
    #
    # HttpClient.Timeout is disabled here because each request receives its
    # own CancellationTokenSource. This gives each URL its own independent
    # timeout.
    # -----------------------------------------------------------------------

    $handler = [System.Net.Http.HttpClientHandler]::new()

    $handler.AllowAutoRedirect = $true
    $handler.MaxAutomaticRedirections = 5

    $httpClient = [System.Net.Http.HttpClient]::new($handler)

    $httpClient.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan

    $requests = @()

    try {
        # -------------------------------------------------------------------
        # Start all HTTP requests before waiting for any of them.
        #
        # This causes the URLs to be tested concurrently instead of waiting
        # up to 30 seconds for one URL before starting the next.
        # -------------------------------------------------------------------

        foreach ($uri in $Uris) {
            Write-MonitorLog -Message (
                "Beginning health check for '$uri' with a " +
                "$TimeoutSeconds-second timeout."
            )

            $stopwatch =
                [System.Diagnostics.Stopwatch]::StartNew()

            $request =
                [System.Net.Http.HttpRequestMessage]::new(
                    [System.Net.Http.HttpMethod]::Get,
                    $uri
                )

            $cancellationSource =
                [System.Threading.CancellationTokenSource]::new()

            $cancellationSource.CancelAfter(
                [TimeSpan]::FromSeconds($TimeoutSeconds)
            )

            # ResponseHeadersRead means that HTTP success is determined as
            # soon as the response headers arrive. The script does not wait
            # for the entire page or REST response body to download.
            $task = $httpClient.SendAsync(
                $request,
                [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead,
                $cancellationSource.Token
            )

            $requests += [PSCustomObject]@{
                Uri                = $uri
                Task               = $task
                Request            = $request
                CancellationSource = $cancellationSource
                Stopwatch          = $stopwatch
            }
        }


        # -------------------------------------------------------------------
        # Collect the result of each request.
        #
        # Because all SendAsync calls have already started, waiting here does
        # not make the checks sequential.
        # -------------------------------------------------------------------

        $results = @()

        foreach ($requestInfo in $requests) {
            $response = $null

            try {
                $response =
                    $requestInfo.Task.GetAwaiter().GetResult()

                $requestInfo.Stopwatch.Stop()

                $statusCode = [int]$response.StatusCode

                $results += [PSCustomObject]@{
                    Uri             = $requestInfo.Uri
                    Success         = ($statusCode -eq 200)
                    StatusCode      = $statusCode
                    StatusText      = $response.ReasonPhrase
                    ErrorType       = $null
                    ErrorMessage    = $null
                    DurationMillis  = $requestInfo.Stopwatch.ElapsedMilliseconds
                    CheckedAt       = Get-Date
                }
            }
            catch [System.OperationCanceledException] {
                $requestInfo.Stopwatch.Stop()

                $results += [PSCustomObject]@{
                    Uri            = $requestInfo.Uri
                    Success        = $false
                    StatusCode     = $null
                    StatusText     = $null
                    ErrorType      = $_.Exception.GetType().FullName
                    ErrorMessage   = (
                        "HTTP request exceeded the configured timeout of " +
                        "$TimeoutSeconds second(s)."
                    )
                    DurationMillis = $requestInfo.Stopwatch.ElapsedMilliseconds
                    CheckedAt      = Get-Date
                }
            }
            catch {
                $requestInfo.Stopwatch.Stop()

                $results += [PSCustomObject]@{
                    Uri            = $requestInfo.Uri
                    Success        = $false
                    StatusCode     = $null
                    StatusText     = $null
                    ErrorType      = $_.Exception.GetType().FullName
                    ErrorMessage   = $_.Exception.Message
                    DurationMillis = $requestInfo.Stopwatch.ElapsedMilliseconds
                    CheckedAt      = Get-Date
                }
            }
            finally {
                if ($null -ne $response) {
                    $response.Dispose()
                }
            }
        }


        # -------------------------------------------------------------------
        # Log every endpoint individually.
        # -------------------------------------------------------------------

        foreach ($result in $results) {
            if ($result.Success) {
                Write-MonitorLog -Message (
                    "HTTP 200; " +
                    "Health check succeeded for '$($result.Uri)'. " +
                    "duration=$($result.DurationMillis) ms."
                )
            }
            elseif ($null -ne $result.StatusCode) {
                Write-MonitorLog `
                    -Level "WARNING" `
                    -Message (
                        "HTTP status=$($result.StatusCode)" +
                        "Health check failed for '$($result.Uri)'. " +
                        $(if ($result.StatusText) {
                            " ($($result.StatusText))"
                        }
                        else {
                            ""
                        }) +
                        "; duration=$($result.DurationMillis) ms."
                    )
            }
            else {
                Write-MonitorLog `
                    -Level "WARNING" `
                    -Message (
                        "Error type=$($result.ErrorType); " +
                        "Health check failed for '$($result.Uri)'. " +
                        "Error=$($result.ErrorMessage); " +
                        "duration=$($result.DurationMillis) ms."
                    )
            }
        }


        # -------------------------------------------------------------------
        # The entire monitoring cycle succeeds only if EVERY endpoint
        # returned HTTP 200.
        # -------------------------------------------------------------------

        $failedResults =
            @($results | Where-Object { -not $_.Success })

        return [PSCustomObject]@{
            Success      = ($failedResults.Count -eq 0)
            Results      = $results
            FailedResults = $failedResults
            FailureCount = $failedResults.Count
        }
    }
    finally {
        # -------------------------------------------------------------------
        # Dispose of all request-related resources.
        # -------------------------------------------------------------------

        foreach ($requestInfo in $requests) {
            if ($null -ne $requestInfo.Request) {
                $requestInfo.Request.Dispose()
            }

            if ($null -ne $requestInfo.CancellationSource) {
                $requestInfo.CancellationSource.Dispose()
            }
        }

        if ($null -ne $httpClient) {
            $httpClient.Dispose()
        }

        if ($null -ne $handler) {
            $handler.Dispose()
        }
    }
}


# ===========================================================================
# IIS restart
# ===========================================================================

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
        Write-MonitorLog -Message "Waiting 5 seconds before starting IIS services."

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
        # Final service validation
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
                "Current states: " +
                "WAS=$wasState; W3SVC=$w3svcState."
            )

        return $false
    }
}


# ===========================================================================
# Startup validation
# ===========================================================================

if (-not (Test-IsAdministrator)) {
    throw (
        "This script must run with administrative privileges because it " +
        "restarts the WAS and W3SVC services."
    )
}

# Confirm that both required IIS services exist.
try {
    Get-Service -Name "WAS", "W3SVC" -ErrorAction Stop | Out-Null
}
catch {
    throw (
        "The required IIS services could not be found or accessed: " +
        $_.Exception.Message
    )
}

# Remove accidental blank entries from the URL list.

$Urls =
    @(
        $Urls |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } |
        Select-Object -Unique
    )


if ($Urls.Count -eq 0) {
    throw "At least one monitoring URL must be configured."
}


# ===========================================================================
# Initial monitoring state
# ===========================================================================

$consecutiveFailures = 0
$lastRestartAttempt =[datetime]::MinValue


# ===========================================================================
# Startup logging
# ===========================================================================

Write-MonitorLog -Message "------------------------------------------------------------"
Write-MonitorLog -Message "Starting IIS HTTP health monitor."
Write-MonitorLog -Message "PowerShell version: $($PSVersionTable.PSVersion)."
Write-MonitorLog -Message "Number of monitored endpoints: $($Urls.Count)."


foreach ($url in $Urls) {
    Write-MonitorLog -Message "Monitored endpoint: $url"
}


Write-MonitorLog -Message (
    "Normal check interval: " +
    "$CheckIntervalMinutes minute(s)."
)

Write-MonitorLog -Message (
    "HTTP request timeout: " +
    "$RequestTimeoutSeconds second(s)."
)

Write-MonitorLog -Message (
    "Retry interval following failure: " +
    "$FailureRetrySeconds second(s)."
)

Write-MonitorLog -Message (
    "Failure threshold: $FailureThreshold consecutive cycle(s)."
)

Write-MonitorLog -Message (
    "Restart cooldown: " +
    "$RestartCooldownMinutes minute(s)."
)

Write-MonitorLog -Message (
    "Service stop timeout: $ServiceStopTimeoutSeconds second(s); " +
    "service start timeout: $ServiceStartTimeoutSeconds second(s)."
)

Write-MonitorLog -Message (
    "Post-restart application recovery delay: $ApplicationRecoverySeconds second(s)."
)

Write-MonitorLog -Message "Log file: $LogPath"
Write-IISServiceStates -Prefix "Startup service states"


# ===========================================================================
# Main monitoring loop
# ===========================================================================

while ($true) {
    # Assume the normal interval unless a failure changes it.
    $nextCheckDelaySeconds = $CheckIntervalMinutes * 60

    try {
        # -------------------------------------------------------------------
        # Check all endpoints concurrently.
        # -------------------------------------------------------------------

        $groupResult = Test-AllWebEndpoints `
                -Uris $Urls `
                -TimeoutSeconds $RequestTimeoutSeconds


        if ($groupResult.Success) {
            # ---------------------------------------------------------------
            # Every endpoint returned HTTP 200.
            # ---------------------------------------------------------------

            Write-MonitorLog -Message (
                "All $($Urls.Count) monitored endpoint(s) responded successfully."
            )

            $consecutiveFailures = 0

            $nextCheckDelaySeconds = $CheckIntervalMinutes * 60
        }
        else {
            # ---------------------------------------------------------------
            # At least one endpoint failed.
            # ---------------------------------------------------------------

            $consecutiveFailures++

            Write-MonitorLog `
                -Level "WARNING" `
                -Message (
                    "$($groupResult.FailureCount) of " +
                    "$($Urls.Count) monitored endpoint(s) failed. " +
                    "Consecutive failed monitoring cycles: " +
                    "$consecutiveFailures of $FailureThreshold."
                )


            # Log the failed URLs together as a concise summary.

            foreach ($failedResult in $groupResult.FailedResults) {
                Write-MonitorLog `
                    -Level "WARNING" `
                    -Message (
                        "Failed endpoint: $($failedResult.Uri)"
                    )
            }


            # ---------------------------------------------------------------
            # Restart IIS when the failure threshold has been reached.
            # ---------------------------------------------------------------

            if ($consecutiveFailures -ge $FailureThreshold) {
                $currentTime = Get-Date

                $minutesSinceLastRestartAttempt = ($currentTime - $lastRestartAttempt).TotalMinutes


                if (
                    $minutesSinceLastRestartAttempt -ge
                    $RestartCooldownMinutes
                ) {
                    # Record the attempt before starting the restart.
                    #
                    # This prevents a failed restart operation from causing
                    # an immediate restart loop.
                    $lastRestartAttempt = $currentTime


                    Write-MonitorLog `
                        -Level "WARNING" `
                        -Message (
                            "Failure threshold reached. Attempting IIS restart."
                        )


                    $restartSucceeded = Restart-IISServices `
                            -StopTimeoutSeconds $ServiceStopTimeoutSeconds `
                            -StartTimeoutSeconds $ServiceStartTimeoutSeconds


                    # Begin a new failure sequence after the restart attempt.
                    $consecutiveFailures = 0


                    if ($restartSucceeded) {
                        # ---------------------------------------------------
                        # Give IIS-hosted applications time to initialize.
                        # ---------------------------------------------------

                        if ($ApplicationRecoverySeconds -gt 0) {
                            Write-MonitorLog -Message (
                                "Waiting $ApplicationRecoverySeconds second(s) " +
                                "for IIS applications to initialize."
                            )

                            Start-Sleep `
                                -Seconds $ApplicationRecoverySeconds
                        }


                        # ---------------------------------------------------
                        # Verify all endpoints after IIS restarts.
                        # ---------------------------------------------------

                        Write-MonitorLog -Message (
                            "Beginning post-restart health check of all monitored endpoints."
                        )


                        $verificationResult =
                            Test-AllWebEndpoints `
                                -Uris $Urls `
                                -TimeoutSeconds `
                                    $RequestTimeoutSeconds


                        if ($verificationResult.Success) {
                            Write-MonitorLog -Message (
                                "Post-restart health check succeeded. " +
                                "All monitored endpoints returned HTTP 200."
                            )

                            # Everything recovered normally.
                            $consecutiveFailures = 0
                            $nextCheckDelaySeconds =
                                $CheckIntervalMinutes * 60
                        }
                        else {
                            # Treat the failed post-restart verification as the first failure in a new sequence.
                            $consecutiveFailures = 1

                            Write-MonitorLog `
                                -Level "WARNING" `
                                -Message (
                                    "IIS services are running, but " +
                                    "$($verificationResult.FailureCount) " +
                                    "endpoint(s) remain unhealthy. " +
                                    "Restart cooldown is now in effect."
                                )

                            $nextCheckDelaySeconds = $FailureRetrySeconds
                        }
                    }
                    else {
                        # ---------------------------------------------------
                        # IIS itself failed to restart successfully.
                        # ---------------------------------------------------

                        $consecutiveFailures = 1

                        Write-MonitorLog `
                            -Level "ERROR" `
                            -Message (
                                "IIS restart was unsuccessful. " +
                                "Monitoring will continue and the " +
                                "restart cooldown will apply."
                            )

                        $nextCheckDelaySeconds = $FailureRetrySeconds
                    }
                }
                else {
                    # -------------------------------------------------------
                    # The application is still unhealthy, but IIS has
                    # already been restarted recently.
                    # -------------------------------------------------------

                    $remainingCooldownMinutes =
                        [math]::Ceiling(
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

                    $nextCheckDelaySeconds = $FailureRetrySeconds
                }
            }
            else {
                # -----------------------------------------------------------
                # We have not yet reached the restart threshold.
                #
                # Retry after the short failure interval instead of waiting
                # for the normal five-minute monitoring interval.
                # -----------------------------------------------------------

                $nextCheckDelaySeconds = $FailureRetrySeconds
            }
        }
    }
    catch {
        # -------------------------------------------------------------------
        # Protect the continuous monitoring loop from unexpected errors.
        # -------------------------------------------------------------------

        Write-MonitorLog `
            -Level "ERROR" `
            -Message (
                "Unexpected monitoring-loop error: " +
                "$($_.Exception.GetType().FullName): " +
                "$($_.Exception.Message)"
            )

        $nextCheckDelaySeconds = $FailureRetrySeconds
    }


    # -----------------------------------------------------------------------
    # Wait before beginning the next monitoring cycle.
    # -----------------------------------------------------------------------

    Write-MonitorLog -Message (
        "Next health check in $nextCheckDelaySeconds second(s)."
    )

    Start-Sleep -Seconds $nextCheckDelaySeconds
}
