# Windows-Baseline.ps1
# Reusable script for all windows machines to capture baseline

$ErrorActionPreference = "Continue"
$RunTime = Get-Date -Format "yyyyMMdd_HHmmss"
$ReportDirectory = Join-Path $PSScriptRoot "BaselineReports"
$RunDirectory = Join-Path $ReportDirectory $RunTime

New-Item -Path $RunDirectory -ItemType Directory -Force | Out-Null

$TranscriptPath = Join-Path $RunDirectory "Baseline-Report.txt"
$TranscriptStarted = $false

try {
    Start-Transcript -Path $TranscriptPath -ErrorAction Stop | Out-Null
    $TranscriptStarted = $true
}
catch {
    Write-Warning "Could not start transcript: $($_.Exception.Message)"
}

Write-Host "`nWindows Baseline Report" -ForegroundColor Green
Write-Host "Computer: $env:COMPUTERNAME"
Write-Host "Collected: $(Get-Date)"
Write-Host "Reports: $RunDirectory"

# Runs each check independently and saves successful results.
function Invoke-Check {
    param (
        [Parameter(Mandatory)]
        [string]$Title,
        [Parameter(Mandatory)]
        [string]$FileName,
        [Parameter(Mandatory)]
        [scriptblock]$Check
    )
    Write-Host "`n=== $Title ===" -ForegroundColor Cyan

    try {
        $ErrorActionPreference = "Stop"
        $Results = @(& $Check)

        if ($Results.Count -eq 0 -or $null -eq $Results[0]) {
            Write-Host "No results returned." -ForegroundColor Yellow
            return
        }
        # Save raw objects to CSV for filtering and comparison.
        $CsvPath = Join-Path $RunDirectory "$FileName.csv"
        $Results | Export-Csv -Path $CsvPath -NoTypeInformation

        # Keep console output readable.
        $Results | Format-Table -AutoSize -Wrap |
            Out-Host

        Write-Host "Saved: $CsvPath" -ForegroundColor DarkGray
    }
    catch {
        Write-Host "CHECK FAILED: $($_.Exception.Message)" `
            -ForegroundColor Yellow
    }
}

$MenuChecks = [ordered]@{
    "1" = @{
        Title = "System Information"
        Run = {
            Invoke-Check -Title "SYSTEM INFORMATION" -FileName "system" -Check {
                Get-CimInstance Win32_OperatingSystem |
                    Select-Object CSName, Caption, Version, OSArchitecture, LastBootUpTime
            }
        }
    }

    "2" = @{
        Title = "Current Identity"
        Run = {
            Write-Host "`n=== CURRENT IDENTITY ===" -ForegroundColor Cyan
            try {
                whoami
                whoami /groups
            }
            catch {
                Write-Warning "Could not collect identity information."
            }
        }
    }

    "3" = @{
        Title = "Local Administrators"
        Run = {
            Invoke-Check -Title "LOCAL ADMINISTRATORS" -FileName "administrators" -Check {
                Get-LocalGroupMember -Group "Administrators" |
                    Select-Object Name, ObjectClass, PrincipalSource, SID
            }
        }
    }

    "4" = @{
        Title = "Running Services"
        Run = {
            Invoke-Check -Title "RUNNING SERVICES" -FileName "running-services" -Check {
                Get-CimInstance Win32_Service |
                    Where-Object { $_.State -eq "Running" } |
                    Select-Object Name, DisplayName, StartName, StartMode, State |
                    Sort-Object Name
            }
        }
    }

    "5" = @{
        Title = "Listening TCP Ports"
        Run = {
            Invoke-Check -Title "LISTENING TCP PORTS" -FileName "tcp-listeners" -Check {
                Get-NetTCPConnection -State Listen |
                    ForEach-Object {
                        $Connection = $_
                        $Process = Get-Process -Id $Connection.OwningProcess `
                            -ErrorAction SilentlyContinue
            
                        [PSCustomObject]@{
                            LocalAddress = $Connection.LocalAddress
                            LocalPort = $Connection.LocalPort
                            PID = $Connection.OwningProcess
                            ProcessName = if ($Process) {
                                $Process.ProcessName
                            } else {
                                "Unknown or inaccessible"
                            }
                        }
                    } |
                    Sort-Object LocalPort, LocalAddress
            }
        }
    }

    "6" = @{
        Title = "Firewall Profiles"
        Run = {
            Invoke-Check -Title "FIREWALL PROFILES" -FileName "firewall-profiles" -Check {
                Get-NetFirewallProfile |
                    Select-Object Name, Enabled, DefaultInboundAction,
                        DefaultOutboundAction
            }
        }
    }

    "7" = @{
        Title = "Inbound Firewall Allow Rules"
        Run = {
            Invoke-Check -Title "ENABLED INBOUND ALLOW RULES" `
                -FileName "inbound-allow-rules" -Check {
                Get-NetFirewallRule -PolicyStore ActiveStore `
                    -Enabled True -Direction Inbound -Action Allow |
                    Select-Object DisplayName, Profile, Action, Enabled,
                        PolicyStoreSourceType |
                    Sort-Object DisplayName        
            }
        }
    }

    "8" = @{
        Title = "Recent Logons"
        Run = {
            Invoke-Check -Title "RECENT LOGONS (LAST 4 HOURS)" `
                -FileName "recent-logons" -Check {
                $Events = Get-WinEvent -FilterHashtable @{
                    LogName = "Security"
                    Id = @(4624, 4625)
                    StartTime = (Get-Date).AddHours(-4)
                } -MaxEvents 100
                foreach ($Event1 in $Events) {
                    [xml]$Xml = $Event1.ToXml()
                    $Fields = @{}

                    foreach ($Item in $Xml.Event.EventData.Data) {
                        $Fields[[string]$Item.Name] = [string]$Item.'#text'
                    }

                    $Account = $Fields["TargetUserName"]
                    if ([string]::IsNullOrWhiteSpace($Account)) {
                        $Account = "(not available)"
                    }

                    [PSCustomObject]@{
                        TimeCreated = $Event1.TimeCreated
                        EventID = $Event1.Id
                        Result = if ($Event1.Id -eq 4624) {
                            "Successful logon"
                        } else {
                            "Failed logon"
                        }
                        Account = $Account
                        LogonType = $Fields["LogonType"]
                        SourceIP = $Fields["IpAddress"]
                        Workstation = $Fields["WorkstationName"]
                    }
                }
            }
        }
    }

    "9" = @{
        Title = "Local User Accounts"
        Run = {
            Invoke-Check -Title "LOCAL USER ACCOUNTS" -FileName "local-users" -Check {
                Get-LocalUser |
                    Select-Object Name, Enabled, LastLogon, PasswordRequired,
                        PasswordLastSet, SID |
                        Sort-Object Name
            }
        }
    }

    "10" = @{
        Title = "Active Scheduled Tasks"
        Run = {
            Invoke-Check -Title "ACTIVE SCHEDULED TASKS" -FileName "scheduled-tasks" -Check {
                Get-ScheduledTask |
                    Where-Object { $_.State -in @("Ready", "Running") } |
                    Select-Object TaskPath, TaskName, State, Author |
                    Sort-Object TaskPath, TaskName
            }
        }
    }

    "11" = @{
        Title = "Recently Installed Services"
        Run = {
            Invoke-Check -Title "RECENT SERVICE INSTALL EVENTS (LAST 7 DAYS)" `
                -FileName "service-install-events" -Check {
                Get-WinEvent -FilterHashtable @{
                    LogName = "System"
                    Id = 7045
                    StartTime = (Get-Date).AddDays(-7)
                } -MaxEvents 50 |
                    Select-Object TimeCreated, Id, ProviderName, Message
            }
        }
    }
}

while ($true) {
    Clear-Host

    Write-Host "========== WINDOWS BASELINE MENU ==========" `
        -ForegroundColor Green
    Write-Host "Computer: $env:COMPUTERNAME"
    Write-Host "Report folder: $RunDirectory"
    Write-Host ""

    foreach ($Key in $MenuChecks.Keys) {
        Write-Host ("{0, 2}. {1}" -f $Key, $MenuChecks[$Key].Title)
    }

    Write-Host ""
    Write-Host " A. Run All Checks"
    Write-Host " 0. Exit"
    Write-Host ""

    $Choice = (Read-Host "Enter your choice").Trim().ToUpper()

    if ($Choice -eq "0") {
        break
    }

    if ($Choice -eq "A") {
        foreach ($Key in $MenuChecks.Keys) {
            & $MenuChecks[$Key].Run
        }

        Read-Host "`nAll checks complete. Press Enter to return to menu"
        continue
    }

    $Selections = $Choice -split "," |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne "" }
    
    $InvalidChoices = @(
        $Selections | Where-Object { $_ -notin $MenuChecks.Keys }
    )

    if ($InvalidChoices.Count -gt 0 -or $Selections.Count -eq 0) {
        Write-Host "Invalid choice. Please select a menu number." `
            -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        continue
    }

    foreach ($Selection in $Selections) {
        & $MenuChecks[$Selection].Run
    }

    Read-Host "`nCheck complete. Press Enter to reutn to menu"
}

Write-Host "`nExiting Windows Baseline." -ForegroundColor Green

if ($TranscriptStarted) {
    Stop-Transcript | Out-Null
}