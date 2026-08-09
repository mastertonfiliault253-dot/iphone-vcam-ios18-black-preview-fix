[CmdletBinding()]
param(
    [string]$MediaMTXPath,
    [string]$FFmpegPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$rtspPort = 18554
$hlsPort = 18888
$pathName = "vcam-test"
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$serverConfig = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "deterministic-mediamtx.yml")).Path
$workspaceRoot = Split-Path -Parent (Split-Path -Parent $projectRoot)

if ([string]::IsNullOrWhiteSpace($MediaMTXPath)) {
    $MediaMTXPath = Join-Path $workspaceRoot "rtsp-vnc-tool\mediamtx\mediamtx.exe"
}
if (-not (Test-Path -LiteralPath $MediaMTXPath -PathType Leaf)) {
    throw "MediaMTX not found: $MediaMTXPath"
}
$MediaMTXPath = (Resolve-Path -LiteralPath $MediaMTXPath).Path

if ([string]::IsNullOrWhiteSpace($FFmpegPath)) {
    $command = Get-Command ffmpeg -ErrorAction Stop
    $FFmpegPath = $command.Source
}
if (-not (Test-Path -LiteralPath $FFmpegPath -PathType Leaf)) {
    throw "FFmpeg not found: $FFmpegPath"
}
$FFmpegPath = (Resolve-Path -LiteralPath $FFmpegPath).Path

function Test-LocalPort {
    param([int]$Port)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync("127.0.0.1", $Port)
        return $task.Wait(300) -and $client.Connected
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

if ((Test-LocalPort $rtspPort) -or (Test-LocalPort $hlsPort)) {
    throw "Test ports $rtspPort/$hlsPort are already in use."
}

$diagnostics = Join-Path $projectRoot "dist\diagnostics\deterministic-stream"
New-Item -ItemType Directory -Path $diagnostics -Force | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$serverStdout = Join-Path $diagnostics "mediamtx-$stamp.out.log"
$serverStderr = Join-Path $diagnostics "mediamtx-$stamp.err.log"
$publisherStdout = Join-Path $diagnostics "ffmpeg-$stamp.out.log"
$publisherStderr = Join-Path $diagnostics "ffmpeg-$stamp.err.log"

$server = $null
$publisher = $null
try {
    $server = Start-Process -FilePath $MediaMTXPath `
        -ArgumentList @($serverConfig) `
        -WorkingDirectory (Split-Path -Parent $MediaMTXPath) `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $serverStdout `
        -RedirectStandardError $serverStderr

    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    while (-not ((Test-LocalPort $rtspPort) -and (Test-LocalPort $hlsPort))) {
        if ($server.HasExited) {
            throw "MediaMTX exited with code $($server.ExitCode). See $serverStderr"
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "MediaMTX did not open ports $rtspPort/$hlsPort."
        }
        Start-Sleep -Milliseconds 100
    }

    $rtspURL = "rtsp://127.0.0.1:$rtspPort/$pathName"
    $ffmpegArguments = @(
        "-hide_banner", "-loglevel", "info", "-re",
        "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30",
        "-an", "-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency",
        "-profile:v", "baseline", "-level:v", "3.1", "-pix_fmt", "yuv420p",
        "-r", "30", "-fps_mode", "cfr",
        "-b:v", "4M", "-maxrate", "4M", "-bufsize", "8M",
        "-g", "30", "-keyint_min", "30", "-sc_threshold", "0", "-bf", "0",
        "-x264-params", "repeat-headers=1:aud=1:force-cfr=1:threads=1:sliced-threads=0:slices=1",
        "-f", "rtsp", "-rtsp_transport", "tcp", "-muxdelay", "0.1",
        $rtspURL
    )
    $publisher = Start-Process -FilePath $FFmpegPath `
        -ArgumentList $ffmpegArguments `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $publisherStdout `
        -RedirectStandardError $publisherStderr

    Start-Sleep -Seconds 2
    if ($publisher.HasExited) {
        throw "FFmpeg exited with code $($publisher.ExitCode). See $publisherStderr"
    }

    $lanAddress = "192.168.2.181"
    Write-Host "Deterministic H.264 stream is running."
    Write-Host "RTSP: rtsp://$lanAddress`:$rtspPort/$pathName"
    Write-Host "HLS:  http://$lanAddress`:$hlsPort/$pathName/index.m3u8"
    Write-Host "MediaMTX PID: $($server.Id); FFmpeg PID: $($publisher.Id)"
    Write-Host "Press Ctrl+C to stop both owned processes."

    while (-not $server.HasExited -and -not $publisher.HasExited) {
        Start-Sleep -Seconds 1
    }
    if ($server.HasExited) {
        throw "MediaMTX exited with code $($server.ExitCode). See $serverStderr"
    }
    throw "FFmpeg exited with code $($publisher.ExitCode). See $publisherStderr"
} finally {
    foreach ($process in @($publisher, $server)) {
        if ($null -ne $process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
