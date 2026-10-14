<#
.SYNOPSIS
    Downloads all files from Yandex.Disk, mirroring the folder structure, via the official REST API.
    Downloads run in parallel across multiple threads. The remote folder listing is cached locally
    next to the script, so re-runs don't re-scan the whole tree.

.USAGE
    1) Get an OAuth token: open https://yandex.ru/dev/disk/poligon/, log in,
       click "Get OAuth token".
    2) Run one of:

       # pass the token directly
       .\yandex_disk_sync_portable.ps1 -Token "YOUR_TOKEN"

       # or save the token to a file and point to it
       .\yandex_disk_sync_portable.ps1 -TokenFile "C:\secrets\ya_token.txt"

    By default downloads the whole disk (path "/") into F:\Ya.Disk using 4
    parallel threads. The script can be stopped and re-run - already
    downloaded files (matching size) are skipped, and the remote folder
    listing is read from a local cache instead of being re-fetched.

.PARAMETER Threads
    Number of files to download in parallel (default 4). Raise this if your
    connection has spare bandwidth; the folder listing phase stays
    single-threaded (it's cheap metadata-only calls, and is skipped
    entirely on reruns thanks to the cache).

.PARAMETER MinFreeGB
    If free space on the target drive would drop below this value, no new
    downloads are started. With parallel downloads this is checked per
    in-flight file, so actual free space may dip slightly below this value
    by up to (Threads - 1) files' worth before everything stops.

.PARAMETER TimeoutSec
    Per-request network timeout. On a timeout, that attempt is NOT retried
    (moves straight to the next file) since a timeout usually means the
    far end is stuck. Other errors (e.g. "500 Internal Server Error") are
    retried up to -RetryCount times.

.PARAMETER JobTimeoutSec
    Hard ceiling (wall-clock) for a single file, enforced externally by the
    main thread. -TimeoutSec is not always honored by Invoke-WebRequest once
    a transfer has started hanging mid-stream, so this is the real safety
    net: if a download thread is still running after this many seconds, it
    is forcibly killed, logged as failed, and the next file takes its slot.
    Keep it comfortably above RetryCount * (TimeoutSec + RetryDelaySec) so
    legitimate retries aren't cut short.

.PARAMETER CacheFile
    Where the remote folder listing is cached (default: next to the script,
    "_listing_cache.json"). On the next run, if this file exists, the whole
    remote-tree scan is skipped entirely (no LIST calls at all) - the file
    is only scanned fresh for new/moved files if you pass -RefreshCache.

.PARAMETER RefreshCache
    Ignore any existing cache and re-scan the whole remote tree from
    scratch (use this if files were added/removed/renamed on the disk).
#>
param(
    [string]$Token,
    [string]$TokenFile,
    [string]$RemotePath = "/",
    [string]$LocalRoot = "F:\Ya.Disk",
    [int]$MaxDownloads = 0,       # 0 = unlimited
    [double]$MinFreeGB = 2.0,
    [int]$RetryCount = 3,
    [int]$RetryDelaySec = 5,
    [int]$TimeoutSec = 20,
    [int]$Threads = 4,
    [int]$JobTimeoutSec = 90,
    [string]$CacheFile = (Join-Path $PSScriptRoot "_listing_cache.json"),
    [switch]$RefreshCache
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # the console progress bar makes Invoke-WebRequest drastically slower in Windows PowerShell 5.1

if (-not $Token -and -not $TokenFile) {
    throw "Provide -Token <string> or -TokenFile <path to file with token>"
}
if (-not $Token) {
    $Token = (Get-Content -LiteralPath $TokenFile -Raw).Trim()
}

$headers = @{ Authorization = "OAuth $Token" }
$apiBase = "https://cloud-api.yandex.net/v1/disk/resources"
$minFreeBytes = $MinFreeGB * 1GB

if (-not (Test-Path -LiteralPath $LocalRoot)) {
    New-Item -ItemType Directory -Force -Path $LocalRoot | Out-Null
}
$driveRoot = (Get-Item -LiteralPath $LocalRoot).PSDrive.Name

$failLogPath = Join-Path $LocalRoot "_failed_downloads.txt"
$logPath = Join-Path $LocalRoot "_sync_log.txt"
$logMutexName = "YaDiskSyncLogMutex"

function Write-Log($msg) {
    $mutex = New-Object System.Threading.Mutex($false, $logMutexName)
    [void]$mutex.WaitOne()
    try {
        $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
        Write-Host $line
        Add-Content -LiteralPath $logPath -Value $line
    } finally {
        $mutex.ReleaseMutex()
    }
}

function Test-IsTimeout($errorRecord) {
    $ex = $errorRecord.Exception
    if ($ex -is [System.Net.WebException] -and $ex.Status -eq [System.Net.WebExceptionStatus]::Timeout) { return $true }
    if ($ex.Message -match "timed out|timeout") { return $true }
    return $false
}

function Get-DiskItems($path) {
    $items = @()
    $offset = 0
    $limit = 200
    while ($true) {
        $uri = "$apiBase`?path=$([uri]::EscapeDataString($path))&limit=$limit&offset=$offset"
        $resp = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -TimeoutSec $TimeoutSec
        $embedded = $resp._embedded
        if (-not $embedded) { break }
        $items += $embedded.items
        $offset += $embedded.items.Count
        if ($offset -ge $embedded.total -or $embedded.items.Count -eq 0) { break }
    }
    return $items
}

function Sanitize-Name($name) {
    $invalid = [IO.Path]::GetInvalidFileNameChars()
    $clean = $name
    foreach ($c in $invalid) { $clean = $clean.Replace([string]$c, "_") }
    return $clean
}

# ---- Phase 1: get the full remote file inventory - either from cache, or by walking the tree ----
$script:allItems = New-Object System.Collections.Generic.List[object]

function Collect-Files($remotePath, $localPath) {
    Write-Log "LIST: $remotePath"
    $items = $null
    for ($i = 1; $i -le $RetryCount; $i++) {
        try {
            $items = Get-DiskItems $remotePath
            break
        } catch {
            if (Test-IsTimeout $_) {
                Write-Log "  list attempt $i/${RetryCount} for $remotePath - TIMEOUT, no further retries"
                break
            }
            Write-Log "  list attempt $i/$RetryCount failed for $remotePath - $($_.Exception.Message)"
            if ($i -lt $RetryCount) { Start-Sleep -Seconds $RetryDelaySec }
        }
    }
    if ($null -eq $items) {
        Write-Log "FAILED_LIST (skipping folder): $remotePath"
        Add-Content -LiteralPath $failLogPath -Value "$remotePath`t[listing failed]"
        return
    }
    foreach ($item in $items) {
        $childLocal = Join-Path $localPath (Sanitize-Name $item.name)
        if ($item.type -eq "dir") {
            Collect-Files $item.path $childLocal
        } else {
            $script:allItems.Add([PSCustomObject]@{ RemotePath = $item.path; LocalPath = $childLocal; Size = $item.size })
        }
    }
}

if ((Test-Path -LiteralPath $CacheFile) -and -not $RefreshCache) {
    Write-Log "Loading cached remote listing from $CacheFile (use -RefreshCache to re-scan)"
    $cached = Get-Content -LiteralPath $CacheFile -Raw | ConvertFrom-Json
    foreach ($c in $cached) {
        $script:allItems.Add([PSCustomObject]@{ RemotePath = $c.RemotePath; LocalPath = $c.LocalPath; Size = $c.Size })
    }
    Write-Log "Loaded $($script:allItems.Count) entries from cache - no remote LIST calls made"
} else {
    Write-Log "=== Scanning remote tree: remote=$RemotePath local=$LocalRoot ==="
    Collect-Files $RemotePath $LocalRoot
    $script:allItems | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $CacheFile -Encoding UTF8
    Write-Log "Saved listing cache: $CacheFile ($($script:allItems.Count) files)"
}

# Make sure every local folder exists (cheap local calls, needed whether we scanned fresh or loaded from cache)
$uniqueDirs = $script:allItems | ForEach-Object { [System.IO.Path]::GetDirectoryName($_.LocalPath) } | Sort-Object -Unique
foreach ($d in $uniqueDirs) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

# Filter out files already downloaded with a matching size
$script:flatList = New-Object System.Collections.Generic.List[object]
foreach ($item in $script:allItems) {
    if (Test-Path -LiteralPath $item.LocalPath) {
        $localSize = (Get-Item -LiteralPath $item.LocalPath).Length
        if ($localSize -eq $item.Size) {
            continue
        }
    }
    $script:flatList.Add($item)
}

if ($MaxDownloads -gt 0 -and $script:flatList.Count -gt $MaxDownloads) {
    $script:flatList = [System.Collections.Generic.List[object]]($script:flatList | Select-Object -First $MaxDownloads)
}

Write-Log "Files to download: $($script:flatList.Count) (of $($script:allItems.Count) total)"

# Some folder/file names on the disk contain an unmatched "[" (seen in the wild, e.g. a
# name truncated at some point in the past). Invoke-WebRequest -OutFile tries to resolve
# its path as a wildcard pattern and throws on those, even though New-Item/Move-Item don't.
# Work around it by downloading to a plain-named staging file on the same drive, then
# Move-Item -LiteralPath into the real (possibly bracket-containing) destination.
$stagingDir = "${driveRoot}:\_yadisk_staging_tmp"
if (-not (Test-Path -LiteralPath $stagingDir)) {
    New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null
}

# ---- Phase 2: download the flat list in parallel ----
$workerScript = {
    param($remotePath, $localPath, $size, $headers, $apiBase, $retryCount, $retryDelaySec, $timeoutSec,
          $logPath, $failLogPath, $logMutexName, $sync, $minFreeBytes, $driveRoot, $stagingDir)

    function Write-WLog($msg) {
        $mutex = New-Object System.Threading.Mutex($false, $logMutexName)
        [void]$mutex.WaitOne()
        try {
            $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
            Add-Content -LiteralPath $logPath -Value $line
        } finally {
            $mutex.ReleaseMutex()
        }
    }

    function Test-WTimeout($errorRecord) {
        $ex = $errorRecord.Exception
        if ($ex -is [System.Net.WebException] -and $ex.Status -eq [System.Net.WebExceptionStatus]::Timeout) { return $true }
        if ($ex.Message -match "timed out|timeout") { return $true }
        return $false
    }

    if ($sync.stopped) {
        return [PSCustomObject]@{ Path = $remotePath; Status = "SkippedSpace" }
    }

    $free = (Get-PSDrive $driveRoot).Free
    if (($free - $size) -lt $minFreeBytes) {
        $sync.stopped = $true
        Write-WLog "LOW_DISK_SPACE_STOP: free=$([math]::Round($free/1GB,2))GB, file=$remotePath"
        return [PSCustomObject]@{ Path = $remotePath; Status = "SkippedSpace" }
    }

    Write-WLog "DOWNLOAD: $remotePath -> $localPath"
    $attempt = 0
    $ok = $false
    $lastMsg = $null
    while ($attempt -lt $retryCount -and -not $ok) {
        $attempt++
        $tempFile = Join-Path $stagingDir ([guid]::NewGuid().ToString("N") + ".part")
        try {
            $dlUri = "$apiBase/download?path=$([uri]::EscapeDataString($remotePath))"
            $dlResp = Invoke-RestMethod -Uri $dlUri -Headers $headers -Method Get -TimeoutSec $timeoutSec
            Invoke-WebRequest -Uri $dlResp.href -OutFile $tempFile -TimeoutSec $timeoutSec
            Move-Item -LiteralPath $tempFile -Destination $localPath -Force
            $ok = $true
        } catch {
            $lastMsg = $_.Exception.Message
            if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $localPath) { Remove-Item -LiteralPath $localPath -Force -ErrorAction SilentlyContinue }
            if (Test-WTimeout $_) {
                Write-WLog "  attempt $attempt/${retryCount}: TIMEOUT, no further retries [$remotePath]"
                break
            }
            Write-WLog "  attempt $attempt/$retryCount failed [$remotePath]: $lastMsg"
            if ($attempt -lt $retryCount) { Start-Sleep -Seconds $retryDelaySec }
        }
    }

    if ($ok) {
        Write-WLog "OK: $remotePath"
        return [PSCustomObject]@{ Path = $remotePath; Status = "OK" }
    } else {
        Write-WLog "FAILED (skipping): $remotePath - $lastMsg"
        $mutex = New-Object System.Threading.Mutex($false, "${logMutexName}_fail")
        [void]$mutex.WaitOne()
        try { Add-Content -LiteralPath $failLogPath -Value "$remotePath`t$lastMsg" } finally { $mutex.ReleaseMutex() }
        return [PSCustomObject]@{ Path = $remotePath; Status = "Failed"; Error = $lastMsg }
    }
}

$okCount = 0; $failCount = 0; $skipCount = 0

if ($script:flatList.Count -gt 0) {
    $sync = [hashtable]::Synchronized(@{ stopped = $false })
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $pool = [runspacefactory]::CreateRunspacePool(1, $Threads, $iss, $Host)
    $pool.Open()

    $pending = New-Object System.Collections.Generic.Queue[object]
    foreach ($f in $script:flatList) { $pending.Enqueue($f) }
    $active = New-Object System.Collections.Generic.List[object]

    function Start-DownloadJob($file) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($workerScript).
            AddArgument($file.RemotePath).AddArgument($file.LocalPath).AddArgument($file.Size).
            AddArgument($headers).AddArgument($apiBase).AddArgument($RetryCount).AddArgument($RetryDelaySec).
            AddArgument($TimeoutSec).AddArgument($logPath).AddArgument($failLogPath).AddArgument($logMutexName).
            AddArgument($sync).AddArgument($minFreeBytes).AddArgument($driveRoot).AddArgument($stagingDir)
        $handle = $ps.BeginInvoke()
        return [PSCustomObject]@{ PS = $ps; Handle = $handle; Item = $file; Start = Get-Date }
    }

    Write-Log "Starting parallel download: $($pending.Count) files, $Threads threads, hard per-file timeout ${JobTimeoutSec}s"

    while ($pending.Count -gt 0 -or $active.Count -gt 0) {
        while ($active.Count -lt $Threads -and $pending.Count -gt 0 -and -not $sync.stopped) {
            $active.Add((Start-DownloadJob $pending.Dequeue()))
        }
        if ($active.Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
        for ($idx = $active.Count - 1; $idx -ge 0; $idx--) {
            $job = $active[$idx]
            if ($job.Handle.IsCompleted) {
                try {
                    $res = $job.PS.EndInvoke($job.Handle)
                    foreach ($r in $res) {
                        switch ($r.Status) {
                            "OK"           { $okCount++ }
                            "Failed"       { $failCount++ }
                            "SkippedSpace" { $skipCount++ }
                        }
                    }
                } catch {
                    Write-Log "FAILED (job error): $($job.Item.RemotePath) - $($_.Exception.Message)"
                    Add-Content -LiteralPath $failLogPath -Value "$($job.Item.RemotePath)`t$($_.Exception.Message)"
                    $failCount++
                }
                $job.PS.Dispose()
                $active.RemoveAt($idx)
            } elseif (((Get-Date) - $job.Start).TotalSeconds -gt $JobTimeoutSec) {
                Write-Log "FORCED_TIMEOUT (hung thread, killing after ${JobTimeoutSec}s): $($job.Item.RemotePath)"
                try { $job.PS.Stop() } catch {}
                try { if (Test-Path -LiteralPath $job.Item.LocalPath) { Remove-Item -LiteralPath $job.Item.LocalPath -Force -ErrorAction SilentlyContinue } } catch {}
                Add-Content -LiteralPath $failLogPath -Value "$($job.Item.RemotePath)`t[forced timeout after ${JobTimeoutSec}s - hung thread]"
                $failCount++
                $job.PS.Dispose()
                $active.RemoveAt($idx)
            }
        }
    }

    $pool.Close()
    $pool.Dispose()

    # Clean up any leftover staging files (e.g. from forcibly killed threads)
    Get-ChildItem -LiteralPath $stagingDir -Filter "*.part" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

if ($skipCount -gt 0) {
    Write-Log "STOPPED_LOW_SPACE. Downloaded: $okCount, Failed: $failCount, Skipped (low space): $skipCount"
} else {
    Write-Log "DONE. Downloaded: $okCount, Failed: $failCount"
}
if ($failCount -gt 0) {
    Write-Log "Failed items logged to: $failLogPath"
}
