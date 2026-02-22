Describe 'Engine/Performance.ps1' {
    BeforeAll {
        . "$PSScriptRoot\..\..\Engine\Performance.ps1"
    }

    BeforeEach {
        Initialize-Performance
    }

    It 'tracks frame times and computes FPS' {
        for ($i = 0; $i -lt 10; $i++) {
            Start-PerfFrame
            Start-Sleep -Milliseconds 5
            End-PerfFrame
        }

        $fps = Get-FPS
        $fps | Should -BeGreaterThan 0
        $fps | Should -BeLessOrEqual 250
    }

    It 'reports memory usage in MB' {
        $mb = Get-MemoryUsageMB
        $mb | Should -BeGreaterThan 0
    }

    It 'generates complete performance report' {
        Start-PerfFrame
        End-PerfFrame

        $report = Get-PerformanceReport
        $report.FPS | Should -BeGreaterThan 0
        $report.MemoryUsageMB | Should -BeGreaterThan 0
        $report.TotalFrames | Should -BeGreaterOrEqual 1
    }

    It 'computes frame time percentile' {
        for ($i = 0; $i -lt 20; $i++) {
            Start-PerfFrame
            Start-Sleep -Milliseconds 2
            End-PerfFrame
        }

        $p99 = Get-FrameTimePercentile -Percentile 99.0
        $p99 | Should -BeGreaterThan 0
    }
}
