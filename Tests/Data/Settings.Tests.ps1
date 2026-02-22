Describe 'Data/Settings.ps1' {
    BeforeAll {
        . "$PSScriptRoot\..\..\Data\Settings.ps1"
    }

    BeforeEach {
        $script:SettingsInitialized = $false
        $script:SettingsData = $null
        $tempFile = [System.IO.Path]::GetTempFileName()
        Set-SettingsStoragePathOverride -Path $tempFile | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $tempFile) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
        $bakFile = "$tempFile.bak"
        if (Test-Path -LiteralPath $bakFile) {
            Remove-Item -LiteralPath $bakFile -Force -ErrorAction SilentlyContinue
        }
        $tmpFile = "$tempFile.tmp"
        if (Test-Path -LiteralPath $tmpFile) {
            Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
        }
        Set-SettingsStoragePathOverride -Path '' | Out-Null
    }

    It 'returns defaults when settings file does not exist' {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        $settings = Get-Settings
        $settings.Video.Resolution | Should -Be '1024x768'
        $settings.Video.VSync | Should -Be $true
        $settings.Video.RenderDistance | Should -Be 4
    }

    It 'persists settings round-trip via Save + Load' {
        Initialize-Settings | Out-Null
        Set-SettingValue -Category 'Video' -Name 'RenderDistance' -Value 6 | Out-Null
        Save-Settings | Out-Null

        $script:SettingsInitialized = $false
        $script:SettingsData = $null

        Load-Settings | Out-Null
        $settings = Get-Settings
        $settings.Video.RenderDistance | Should -Be 6
    }

    It 'clamps render distance to 2..8 range' {
        Initialize-Settings | Out-Null
        Set-SettingValue -Category 'Video' -Name 'RenderDistance' -Value 15 | Out-Null
        $settings = Get-Settings
        $settings.Video.RenderDistance | Should -BeLessOrEqual 8

        Set-SettingValue -Category 'Video' -Name 'RenderDistance' -Value 0 | Out-Null
        $settings = Get-Settings
        $settings.Video.RenderDistance | Should -BeGreaterOrEqual 2
    }

    It 'manages key bindings via Set-KeyBinding and Get-KeyBinding' {
        Initialize-Settings | Out-Null
        Set-KeyBinding -Action 'Jump' -Key 'E' | Out-Null

        $binding = Get-KeyBinding -Action 'Jump'
        $binding | Should -Be 'E'
    }

    It 'clamps volume settings to 0..100' {
        Initialize-Settings | Out-Null
        Set-SettingValue -Category 'Audio' -Name 'MasterVolume' -Value 150 | Out-Null
        $settings = Get-Settings
        $settings.Audio.MasterVolume | Should -BeLessOrEqual 100

        Set-SettingValue -Category 'Audio' -Name 'MasterVolume' -Value -20 | Out-Null
        $settings = Get-Settings
        $settings.Audio.MasterVolume | Should -BeGreaterOrEqual 0
    }
}
