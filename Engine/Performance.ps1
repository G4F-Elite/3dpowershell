# ============================================================================
# Engine/Performance.ps1 - Performance Monitoring and Optimization Utilities
# ============================================================================
# Provides FPS tracking, frame time profiling, memory monitoring, and
# optimization helpers for hot-path PowerShell execution.
#
# Dependencies: None (standalone utility module)
# ============================================================================

# --- Module State ---
$script:PerfFrameTimes = [double[]]::new(256)
$script:PerfFrameTimesIndex = [int]0
$script:PerfFrameTimesCount = [int]0
$script:PerfLastFrameStart = [double]0
$script:PerfFPSCache = [float]0
$script:PerfFPSCacheAge = [int]0
$script:PerfFPSCacheInterval = [int]30
$script:PerfInitialized = $false
$script:PerfStopwatch = $null
$script:PerfGCCollectThresholdMB = [int]512
$script:PerfLastGCCollectFrame = [int]0
$script:PerfGCCollectIntervalFrames = [int]1800
$script:PerfTotalFrames = [int64]0

# ============================================================================
# Initialization
# ============================================================================

function Initialize-Performance {
    $script:PerfStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $script:PerfFrameTimes = [double[]]::new(256)
    $script:PerfFrameTimesIndex = [int]0
    $script:PerfFrameTimesCount = [int]0
    $script:PerfLastFrameStart = [double]$script:PerfStopwatch.Elapsed.TotalMilliseconds
    $script:PerfFPSCache = [float]60.0
    $script:PerfFPSCacheAge = [int]0
    $script:PerfTotalFrames = [int64]0
    $script:PerfInitialized = $true
}

# ============================================================================
# Frame Timing
# ============================================================================

function Start-PerfFrame {
    if (-not $script:PerfInitialized) { Initialize-Performance }
    $script:PerfLastFrameStart = [double]$script:PerfStopwatch.Elapsed.TotalMilliseconds
}

function End-PerfFrame {
    if (-not $script:PerfInitialized) { return }

    [double]$now = $script:PerfStopwatch.Elapsed.TotalMilliseconds
    [double]$frameMs = $now - $script:PerfLastFrameStart

    if ($frameMs -lt 0.01) { $frameMs = [double]0.01 }
    if ($frameMs -gt 1000.0) { $frameMs = [double]1000.0 }

    $script:PerfFrameTimes[$script:PerfFrameTimesIndex] = $frameMs
    $script:PerfFrameTimesIndex = ($script:PerfFrameTimesIndex + 1) -band 255
    if ($script:PerfFrameTimesCount -lt 256) {
        $script:PerfFrameTimesCount++
    }

    $script:PerfFPSCacheAge++
    $script:PerfTotalFrames++

    # Periodic GC hint for long sessions
    if (($script:PerfTotalFrames - $script:PerfLastGCCollectFrame) -ge $script:PerfGCCollectIntervalFrames) {
        $memMB = [int]([System.GC]::GetTotalMemory($false) / 1048576)
        if ($memMB -gt $script:PerfGCCollectThresholdMB) {
            [System.GC]::Collect(1, [System.GCCollectionMode]::Optimized)
            $script:PerfLastGCCollectFrame = $script:PerfTotalFrames
        }
    }
}

# ============================================================================
# FPS Queries
# ============================================================================

function Get-FPS {
    if ($script:PerfFrameTimesCount -lt 1) { return [float]60.0 }

    if ($script:PerfFPSCacheAge -lt $script:PerfFPSCacheInterval) {
        return [float]$script:PerfFPSCache
    }

    [double]$sum = 0.0
    [int]$count = $script:PerfFrameTimesCount
    for ([int]$i = 0; $i -lt $count; $i++) {
        $sum += $script:PerfFrameTimes[$i]
    }

    [double]$avgMs = $sum / $count
    if ($avgMs -lt 0.01) { $avgMs = [double]0.01 }

    $script:PerfFPSCache = [float](1000.0 / $avgMs)
    $script:PerfFPSCacheAge = [int]0
    return [float]$script:PerfFPSCache
}

function Get-FrameTimeMs {
    if ($script:PerfFrameTimesCount -lt 1) { return [double]16.67 }

    [double]$sum = 0.0
    [int]$count = $script:PerfFrameTimesCount
    for ([int]$i = 0; $i -lt $count; $i++) {
        $sum += $script:PerfFrameTimes[$i]
    }

    return [double]($sum / $count)
}

function Get-FrameTimePercentile {
    param([float]$Percentile = 99.0)

    if ($script:PerfFrameTimesCount -lt 2) { return [double]16.67 }

    [int]$count = $script:PerfFrameTimesCount
    $sorted = [double[]]::new($count)
    [Array]::Copy($script:PerfFrameTimes, $sorted, $count)
    [Array]::Sort($sorted)

    [int]$idx = [Math]::Min([int]([Math]::Floor(($Percentile / 100.0) * $count)), $count - 1)
    return [double]$sorted[$idx]
}

# ============================================================================
# Memory Monitoring
# ============================================================================

function Get-MemoryUsageMB {
    return [int]([System.GC]::GetTotalMemory($false) / 1048576)
}

function Invoke-MemoryCleanup {
    param([switch]$Full)

    if ($Full) {
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        [System.GC]::Collect()
    }
    else {
        [System.GC]::Collect(1, [System.GCCollectionMode]::Optimized)
    }

    return [int](Get-MemoryUsageMB)
}

# ============================================================================
# Performance Report
# ============================================================================

function Get-PerformanceReport {
    [float]$fps = Get-FPS
    [double]$avgMs = Get-FrameTimeMs
    [double]$p99Ms = Get-FrameTimePercentile -Percentile 99.0
    [int]$memMB = Get-MemoryUsageMB

    return [PSCustomObject]@{
        FPS              = [float]$fps
        AvgFrameTimeMs   = [Math]::Round($avgMs, 2)
        P99FrameTimeMs   = [Math]::Round($p99Ms, 2)
        MemoryUsageMB    = [int]$memMB
        TotalFrames      = [int64]$script:PerfTotalFrames
        SampleCount      = [int]$script:PerfFrameTimesCount
        TargetFPS        = [int]30
        IsAboveTarget    = ($fps -ge 30.0)
    }
}

# ============================================================================
# Hot-Path Optimization Helpers
# ============================================================================

function New-ReusableFloatArray {
    param([int]$Size = 16)
    return [float[]]::new($Size)
}

function New-ReusableIntArray {
    param([int]$Size = 256)
    return [int[]]::new($Size)
}

function Copy-FloatArrayFast {
    param(
        [float[]]$Source,
        [float[]]$Destination,
        [int]$Count
    )

    [Buffer]::BlockCopy($Source, 0, $Destination, 0, $Count * 4)
}

function Get-PerfTimestamp {
    if ($null -eq $script:PerfStopwatch) { return [double]0.0 }
    return [double]$script:PerfStopwatch.Elapsed.TotalMilliseconds
}
