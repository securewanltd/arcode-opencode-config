#Requires -Version 5.1

<#
.SYNOPSIS
    One-time onboarding script for arcode-opencode-config.

.DESCRIPTION
    Configures opencode.json to load the arcode-opencode-config plugin from a GitHub repository tarball.
    Preserves existing config keys and other plugin entries.
    Optionally installs the local MCP server prerequisites (@theupsider/lsp-mcp@1.3.2, websearch-mcp) via npm
    and verifies that codegraph is on PATH. Use -SkipMcp to disable MCP installation.

    NOTE: The unscoped `lsp-mcp` package on npm is a security-holding placeholder and must NOT be used.

    The plugin is referenced by a GitHub tarball URL so that opencode can fetch it without
    requiring git to be installed on the machine (unlike the `github:owner/repo` npm spec).

.PARAMETER Repo
    GitHub repository in owner/name format. Defaults to "securewanltd/arcode-opencode-config".

.PARAMETER Branch
    Git branch, tag, or ref to pin. Defaults to "main".

.PARAMETER SkipMcp
    Skip installation and verification of MCP prerequisites.
#>
param(
    [Parameter(Mandatory = $false, HelpMessage = "GitHub repository in owner/name format; defaults to securewanltd/arcode-opencode-config")]
    [string]$Repo = "securewanltd/arcode-opencode-config",

    [Parameter(HelpMessage = "Git branch, tag, or ref")]
    [string]$Branch = "main",

    [Parameter(HelpMessage = "Skip MCP prerequisite installation and verification")]
    [switch]$SkipMcp
)

function Write-Header($text) {
    Write-Host ""
    Write-Host "== $text ==" -ForegroundColor Cyan
}

function Write-Step($text) {
    Write-Host "  - $text" -ForegroundColor Gray
}

function Test-CommandOnPath($name) {
    return $null -ne (Get-Command $name -ErrorAction SilentlyContinue)
}

function Invoke-NpmInstallGlobal($packages) {
    $dryRun = ($env:ARCODE_INSTALL_DRYRUN -eq '1')
    if ($dryRun) {
        Write-Step "DRY RUN: would run npm install -g $packages"
        return $true
    }
    try {
        $output = & npm install -g $packages 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "npm exited with exit code $LASTEXITCODE"
        }
        Write-Step "npm install -g $packages succeeded"
        return $true
    } catch {
        Write-Warning "npm install -g $packages failed: $_"
        return $false
    }
}

function Update-ProcessPathFromRegistry {
    # Refresh process PATH from machine+user registry values, preserving process-only additions.
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $processPath = $env:Path

    $parts = [System.Collections.ArrayList]::new()
    $seen = @{}

    foreach ($part in ($processPath -split ";")) {
        if ($part -and -not $seen.ContainsKey($part)) {
            [void]$parts.Add($part)
            $seen[$part] = $true
        }
    }
    foreach ($part in (($userPath -split ";") + ($machinePath -split ";"))) {
        if ($part -and -not $seen.ContainsKey($part)) {
            [void]$parts.Add($part)
            $seen[$part] = $true
        }
    }

    $env:Path = $parts -join ";"
}

function Get-RunningOpencodeOrLspMcpProcesses {
    try {
        return Get-CimInstance Win32_Process | Where-Object {
            ($_.Name -in @('opencode.exe', 'node.exe')) -and
            ($_.CommandLine -match 'opencode|lsp-mcp')
        }
    } catch {
        Write-Warning "Could not enumerate running processes: $_"
        return @()
    }
}

function Remove-StaleLspMcpPlaceholder {
    if ($env:ARCODE_INSTALL_DRYRUN -eq '1') {
        Write-Step "DRY RUN: would check for and remove stale bare `lsp-mcp` placeholder package/shims"
        return
    }

    try {
        $npmLsJson = & npm ls -g --depth=0 --json 2>&1 | Out-String
        $npmLs = $npmLsJson | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($npmLs -and $npmLs.dependencies -and $npmLs.dependencies.'lsp-mcp') {
            Write-Step "Found stale bare `lsp-mcp` package in global npm list; uninstalling"
            $uninstallOut = & npm uninstall -g lsp-mcp 2>&1
            $uninstallExit = $LASTEXITCODE
            if ($uninstallExit -ne 0) {
                Write-Warning "npm uninstall -g lsp-mcp returned exit code $uninstallExit; continuing with shim cleanup"
            } else {
                Write-Step "npm uninstall -g lsp-mcp succeeded"
            }
        }
    } catch {
        Write-Warning "Could not check global npm list for stale lsp-mcp: $_"
    }

    $shimDir = Join-Path $env:APPDATA 'npm'
    foreach ($shimName in @('lsp-mcp', 'lsp-mcp.cmd', 'lsp-mcp.ps1')) {
        $shimPath = Join-Path $shimDir $shimName
        if (Test-Path -LiteralPath $shimPath) {
            try {
                $content = Get-Content -LiteralPath $shimPath -Raw -ErrorAction Stop
                if ($content -match 'node_modules\\lsp-mcp' -and $content -notmatch '@theupsider\\lsp-mcp') {
                    Write-Step "Deleting stale placeholder shim $shimPath"
                    Remove-Item -LiteralPath $shimPath -Force
                } else {
                    Write-Step "Shim $shimName references @theupsider/lsp-mcp or is not a placeholder; keeping"
                }
            } catch {
                Write-Warning "Could not inspect shim $shimPath : $_"
            }
        }
    }

    $placeholderDir = Join-Path $shimDir 'node_modules\lsp-mcp'
    if (Test-Path -LiteralPath $placeholderDir) {
        $pkgJsonPath = Join-Path $placeholderDir 'package.json'
        $isScoped = $false
        if (Test-Path -LiteralPath $pkgJsonPath) {
            try {
                $pkgJson = Get-Content -LiteralPath $pkgJsonPath -Raw | ConvertFrom-Json -ErrorAction Stop
                if ($pkgJson.name -eq '@theupsider/lsp-mcp') {
                    $isScoped = $true
                }
            } catch {
                # Treat unreadable package.json as stale.
            }
        }
        if (-not $isScoped) {
            Write-Step "Removing stale placeholder directory $placeholderDir"
            Remove-Item -LiteralPath $placeholderDir -Recurse -Force
        } else {
            Write-Step "node_modules\lsp-mcp is @theupsider/lsp-mcp; keeping"
        }
    }
}

function Test-LspMcpShimIsHealthy($command) {
    try {
        $cmdInfo = Get-Command $command -ErrorAction Stop
        $shimPath = $cmdInfo.Source
        if (-not (Test-Path -LiteralPath $shimPath)) { return $false }
        $content = Get-Content -LiteralPath $shimPath -Raw -ErrorAction Stop
        return $content -match '@theupsider\\lsp-mcp'
    } catch {
        return $false
    }
}

function Test-McpInstallPrerequisites($tools) {
    if ($env:ARCODE_INSTALL_DRYRUN -eq '1') {
        Write-Step "DRY RUN: would check for running opencode/lsp-mcp processes and clean stale lsp-mcp placeholder"
        return $true
    }

    $running = Get-RunningOpencodeOrLspMcpProcesses
    if ($running.Count -gt 0) {
        Write-Warning "Kurulumdan önce opencode'u kapatın: running opencode/lsp-mcp processes detected."
        foreach ($proc in $running) {
            Write-Warning "  ProcessId: $($proc.ProcessId), Name: $($proc.Name)"
        }
        Write-Warning "MCP install skipped to avoid EPERM file locks. Close opencode and re-run."
        return $false
    }

    Remove-StaleLspMcpPlaceholder
    return $true
}

function Test-ManagedPluginEntry($firstElement) {
    $oldSpec = "github:$Repo"
    $tarballPrefix = "https://github.com/$Repo/archive/refs/heads/"
    $tarballSuffix = ".tar.gz"
    if ($firstElement -eq $oldSpec) { return $true }
    if ($firstElement -and $firstElement.StartsWith($tarballPrefix) -and $firstElement.EndsWith($tarballSuffix)) { return $true }
    return $false
}

# Validate repo format
if ($Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw "Repo must be in owner/name format (e.g. myorg/arcode-opencode-config). Got: $Repo"
}

$PluginIdentifier = "https://github.com/$Repo/archive/refs/heads/$Branch.tar.gz"
$ManifestUrl = "https://raw.githubusercontent.com/$Repo/$Branch/manifest.json"

$configDir = Join-Path $env:USERPROFILE ".config\opencode"
$configPath = Join-Path $configDir "opencode.json"
$jsoncPath = Join-Path $configDir "opencode.jsonc"

Write-Header "Preparing opencode config directory"
if (-not (Test-Path -LiteralPath $configDir)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    Write-Step "Created $configDir"
} else {
    Write-Step "Found $configDir"
}

if (Test-Path -LiteralPath $jsoncPath) {
    Write-Warning "opencode.jsonc exists at $jsoncPath. This script only manages opencode.json. Please consolidate the two files manually if needed."
}

Write-Header "Loading existing opencode.json"
if (Test-Path -LiteralPath $configPath) {
    $configText = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    $config = $configText | ConvertFrom-Json
    Write-Step "Loaded existing $configPath"
} else {
    $config = [PSCustomObject]@{
        '$schema' = 'https://opencode.ai/config.json'
    }
    Write-Step "Creating new opencode.json with `$schema"
}

Write-Header "Updating plugin entry"
if (-not (Get-Member -InputObject $config -Name 'plugin' -MemberType NoteProperty)) {
    $config | Add-Member -NotePropertyName 'plugin' -NotePropertyValue @() -Force
    Write-Step "Added empty plugin array"
}

$pluginArray = [System.Collections.ArrayList]::new()
$found = $false
foreach ($entry in $config.plugin) {
    if ($entry -is [System.Array] -and $entry.Length -gt 0 -and (Test-ManagedPluginEntry $entry[0])) {
        [void]$pluginArray.Add(@($PluginIdentifier, @{ manifestUrl = $ManifestUrl }))
        $found = $true
        Write-Step "Replaced existing managed plugin entry"
    } else {
        [void]$pluginArray.Add($entry)
    }
}
if (-not $found) {
    [void]$pluginArray.Add(@($PluginIdentifier, @{ manifestUrl = $ManifestUrl }))
    Write-Step "Added new managed plugin entry"
}

$config.plugin = $pluginArray.ToArray()

Write-Header "Writing $configPath"
$config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding UTF8
Write-Step "Wrote $configPath"

$McpStatus = @{}

if (-not $SkipMcp) {
    Write-Header "Installing MCP prerequisites"

    if (-not (Test-CommandOnPath "npm")) {
        Write-Warning "Node.js/npm is not available on PATH. MCP prerequisite installation skipped. Install Node.js and re-run without -SkipMcp, or install @theupsider/lsp-mcp@1.3.2, websearch-mcp, and codegraph manually. NOTE: the bare 'lsp-mcp' package on npm is a placeholder and must not be used."
    } else {
        Write-Step "npm found on PATH"

        $npmTools = @(
            @{ name = "lsp-mcp"; command = "lsp-mcp.cmd"; package = "@theupsider/lsp-mcp@1.3.2" },
            @{ name = "websearch-mcp"; command = "websearch-mcp.cmd"; package = "websearch-mcp" }
        )
        $missing = [System.Collections.ArrayList]::new()

        foreach ($tool in $npmTools) {
            if (Test-CommandOnPath $tool.command) {
                Write-Step "$($tool.name) already available ($($tool.command))"
                $McpStatus[$tool.name] = "OK"
            } else {
                Write-Step "$($tool.name) missing; will install via npm ($($tool.package))"
                [void]$missing.Add($tool)
                $McpStatus[$tool.name] = "MISSING"
            }
        }

        if ($missing.Count -gt 0) {
            # Guard: do not install while opencode/lsp-mcp processes are running, and clean stale placeholder.
            if (Test-McpInstallPrerequisites $npmTools) {
                $packageList = ($missing | ForEach-Object { $_.package }) -join " "
                Write-Step "Installing: $packageList"
                $installOk = Invoke-NpmInstallGlobal $packageList
                if (-not $installOk) {
                    Write-Warning "Installation reported failure; subsequent verification will show MISSING for those tools."
                }

                Update-ProcessPathFromRegistry

                # Re-verify after install attempt so the summary reflects actual PATH state.
                foreach ($tool in $npmTools) {
                    if ($McpStatus[$tool.name] -eq 'MISSING' -and (Test-CommandOnPath $tool.command)) {
                        if ($tool.name -eq 'lsp-mcp' -and -not (Test-LspMcpShimIsHealthy $tool.command)) {
                            Write-Warning "lsp-mcp.cmd found on PATH but its shim does not reference @theupsider/lsp-mcp; a stale placeholder may still be present."
                            $McpStatus[$tool.name] = "MISSING"
                        } else {
                            $McpStatus[$tool.name] = "OK"
                        }
                    }
                }
            } else {
                foreach ($tool in $npmTools) {
                    if ($McpStatus[$tool.name] -eq 'MISSING') {
                        $McpStatus[$tool.name] = "SKIPPED (opencode running)"
                    }
                }
            }
        }

        if (Test-CommandOnPath "codegraph.cmd") {
            Write-Step "codegraph CLI found on PATH"
            $McpStatus["codegraph"] = "OK"
        } else {
            Write-Warning "codegraph CLI not found on PATH. codegraph is required by the manifest MCP server. Install codegraph from the official distribution, ensure codegraph.cmd is on PATH, and restart opencode."
            $McpStatus["codegraph"] = "MISSING"
        }
    }

    Write-Header "MCP prerequisite summary"
    foreach ($toolName in @("lsp-mcp", "websearch-mcp", "codegraph")) {
        $status = $McpStatus[$toolName]
        if (-not $status) { $status = "SKIPPED" }
        $color = switch ($status) {
            "OK"        { "Green" }
            "INSTALLED" { "Green" }
            "MISSING"   { "Red" }
            default     { "Yellow" }
        }
        Write-Host "  $($toolName.PadRight(15)) : " -NoNewline
        Write-Host $status -ForegroundColor $color
    }
}

Write-Header "Next steps"
Write-Host @"
1. Restart opencode so the arcode-opencode-config plugin is downloaded from the tarball and fetches the manifest from:
   $ManifestUrl

2. If lsp-mcp.cmd is missing from PATH, install the correct scoped package (do NOT use the bare `lsp-mcp` placeholder):
   npm install -g @theupsider/lsp-mcp@1.3.2

3. If codegraph.cmd is missing from PATH, install the codegraph CLI from the official distribution, ensure it is on PATH, and restart opencode.

4. If you already have an opencode.jsonc file, review it and merge any settings into opencode.json.

5. Edit manifest.json on GitHub; the next opencode start on every machine will pull the updated agents, MCP servers, and config keys.
"@

Write-Header "Resulting opencode.json"
Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | Write-Host
