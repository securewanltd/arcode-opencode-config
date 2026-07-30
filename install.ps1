#Requires -Version 5.1

<#
.SYNOPSIS
    One-time onboarding script for arcode-opencode-config.

.DESCRIPTION
    Configures opencode.json to load the arcode-opencode-config plugin from a GitHub repository.
    Preserves existing config keys and other plugin entries.
    Optionally installs the local MCP server prerequisites (lsp-mcp, websearch-mcp) via npm
    and verifies that codegraph is on PATH. Use -SkipMcp to disable MCP installation.

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

# Validate repo format
if ($Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw "Repo must be in owner/name format (e.g. myorg/arcode-opencode-config). Got: $Repo"
}

$PluginIdentifier = "github:$Repo"
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
    if ($entry -is [System.Array] -and $entry.Length -gt 0 -and $entry[0] -eq $PluginIdentifier) {
        [void]$pluginArray.Add(@($PluginIdentifier, @{ manifestUrl = $ManifestUrl }))
        $found = $true
        Write-Step "Replaced existing $PluginIdentifier entry"
    } else {
        [void]$pluginArray.Add($entry)
    }
}
if (-not $found) {
    [void]$pluginArray.Add(@($PluginIdentifier, @{ manifestUrl = $ManifestUrl }))
    Write-Step "Added new $PluginIdentifier entry"
}

$config.plugin = $pluginArray.ToArray()

Write-Header "Writing $configPath"
$config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding UTF8
Write-Step "Wrote $configPath"

$McpStatus = @{}

if (-not $SkipMcp) {
    Write-Header "Installing MCP prerequisites"

    if (-not (Test-CommandOnPath "npm")) {
        Write-Warning "Node.js/npm is not available on PATH. MCP prerequisite installation skipped. Install Node.js and re-run without -SkipMcp, or install lsp-mcp, websearch-mcp, and codegraph manually."
    } else {
        Write-Step "npm found on PATH"

        $npmTools = @(
            @{ name = "lsp-mcp"; command = "lsp-mcp.cmd" },
            @{ name = "websearch-mcp"; command = "websearch-mcp.cmd" }
        )
        $missing = [System.Collections.ArrayList]::new()

        foreach ($tool in $npmTools) {
            if (Test-CommandOnPath $tool.command) {
                Write-Step "$($tool.name) already available ($($tool.command))"
                $McpStatus[$tool.name] = "OK"
            } else {
                Write-Step "$($tool.name) missing; will install via npm"
                [void]$missing.Add($tool.name)
                $McpStatus[$tool.name] = "MISSING"
            }
        }

        if ($missing.Count -gt 0) {
            $packageList = $missing -join " "
            Write-Step "Installing: $packageList"
            $installOk = Invoke-NpmInstallGlobal $packageList
            if (-not $installOk) {
                Write-Warning "Installation reported failure; subsequent verification will show MISSING for those tools."
            }
        }

        # Re-verify after install attempt so the summary reflects actual PATH state.
        foreach ($tool in $npmTools) {
            if (Test-CommandOnPath $tool.command) {
                $McpStatus[$tool.name] = "OK"
            } else {
                $McpStatus[$tool.name] = "MISSING"
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
1. Restart opencode so the arcode-opencode-config plugin fetches the manifest from:
   $ManifestUrl

2. If codegraph.cmd is missing from PATH, install the codegraph CLI from the official distribution, ensure it is on PATH, and restart opencode.

3. If you already have an opencode.jsonc file, review it and merge any settings into opencode.json.

4. Edit manifest.json on GitHub; the next opencode start on every machine will pull the updated agents, MCP servers, and config keys.
"@

Write-Header "Resulting opencode.json"
Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | Write-Host
