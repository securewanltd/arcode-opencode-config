#Requires -Version 5.1

<#
.SYNOPSIS
    End-to-end idempotent onboarding script for arcode-opencode-config.

.DESCRIPTION
    Prepares a bare Windows machine for opencode + arcode-opencode-config:
    - Checks/Installs Node.js/npm via winget (if available)
    - Checks/Installs git via winget (if available) for general plugin compatibility
    - Checks/Installs opencode CLI
    - Checks/Installs MCP prerequisites (codegraph, lsp-mcp, websearch-mcp)
    - Verifies remote MCP endpoints (context7, grep_app) reachability
    - Configures opencode.json with the arcode-opencode-config plugin tuple

    The plugin is referenced by a GitHub tarball URL so that opencode can fetch it
    without requiring git to be installed on the machine (unlike the `github:owner/repo`
    npm spec). Git is still installed when missing because it is broadly useful for
    other plugins and workflows.

    Use -SkipOpencode to skip opencode installation.
    Use -SkipMcp to skip MCP prerequisite installation/verification.
    Set $env:ARCODE_INSTALL_DRYRUN='1' to log installs instead of executing them.

.PARAMETER Repo
    GitHub repository in owner/name format. Defaults to "securewanltd/arcode-opencode-config".

.PARAMETER Branch
    Git branch, tag, or ref to pin. Defaults to "main".

.PARAMETER SkipMcp
    Skip MCP prerequisite installation and verification.

.PARAMETER SkipOpencode
    Skip opencode CLI installation.
#>
param(
    [Parameter(Mandatory = $false, HelpMessage = "GitHub repository in owner/name format; defaults to securewanltd/arcode-opencode-config")]
    [string]$Repo = "securewanltd/arcode-opencode-config",

    [Parameter(HelpMessage = "Git branch, tag, or ref")]
    [string]$Branch = "main",

    [Parameter(HelpMessage = "Skip MCP prerequisite installation and verification")]
    [switch]$SkipMcp,

    [Parameter(HelpMessage = "Skip opencode CLI installation")]
    [switch]$SkipOpencode
)

# Status collector
$Status = @{
    NodeNpm = $null
    Git = $null
    Opencode = $null
    Codegraph = $null
    "lsp-mcp" = $null
    "websearch-mcp" = $null
    Context7 = $null
    GrepApp = $null
    PluginConfig = $null
}

function Write-Header($text) {
    Write-Host ""
    Write-Host "== $text ==" -ForegroundColor Cyan
}

function Write-Step($text) {
    Write-Host "  - $text" -ForegroundColor Gray
}

function Write-Status($name, $status) {
    $color = switch -Regex ($status) {
        "^(OK|INSTALLED|REMOTE-OK)$" { "Green" }
        "^MISSING$" { "Red" }
        default { "Yellow" }
    }
    Write-Host "  $($name.PadRight(18)) : " -NoNewline
    Write-Host $status -ForegroundColor $color
}

function Test-CommandOnPath($name) {
    return $null -ne (Get-Command $name -ErrorAction SilentlyContinue)
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

function Invoke-NpmInstallGlobal($package) {
    if ($env:ARCODE_INSTALL_DRYRUN -eq '1') {
        Write-Step "DRY RUN: would run npm install -g $package"
        return $true
    }
    try {
        $output = & npm install -g $package 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "npm exited with exit code $LASTEXITCODE"
        }
        Write-Step "npm install -g $package succeeded"
        return $true
    } catch {
        Write-Warning "npm install -g $package failed: $_"
        return $false
    }
}

# --- Stage 1: Node.js / npm ---

function Install-NodeNpm {
    if (Test-CommandOnPath "npm") {
        Write-Step "npm already available on PATH"
        $Status.NodeNpm = "OK"
        return
    }

    Write-Step "npm not found on PATH"

    if (-not (Test-CommandOnPath "winget")) {
        Write-Warning "winget not available. Cannot auto-install Node.js. Please install Node.js (https://nodejs.org/) and re-run this script."
        $Status.NodeNpm = "MISSING"
        return
    }

    Write-Step "winget found; installing Node.js LTS"
    if ($env:ARCODE_INSTALL_DRYRUN -eq '1') {
        Write-Step "DRY RUN: would run winget install OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements"
        $Status.NodeNpm = "SKIPPED"
        return
    }

    try {
        & winget install OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) {
            throw "winget exited with exit code $LASTEXITCODE"
        }
        Write-Step "winget Node.js installation reported success"
        Update-ProcessPathFromRegistry

        if (Test-CommandOnPath "npm") {
            Write-Step "npm is now available on PATH"
            $Status.NodeNpm = "INSTALLED"
        } else {
            Write-Warning "npm still not on PATH after winget install. Please restart the terminal and re-run this script."
            $Status.NodeNpm = "MISSING"
        }
    } catch {
        Write-Warning "winget install Node.js failed: $_"
        $Status.NodeNpm = "MISSING"
    }
}

# --- Stage 2: git ---

function Install-Git {
    if (Test-CommandOnPath "git") {
        Write-Step "git already available on PATH"
        $Status.Git = "OK"
        return
    }

    Write-Step "git not found on PATH"

    if (-not (Test-CommandOnPath "winget")) {
        Write-Warning "winget not available. Cannot auto-install git. The arcode-opencode-config plugin uses a tarball URL so it does not require git, but other plugins using the 'github:' npm install spec may fail on this machine. Install git to avoid that issue."
        $Status.Git = "MISSING"
        return
    }

    Write-Step "winget found; installing Git"
    if ($env:ARCODE_INSTALL_DRYRUN -eq '1') {
        Write-Step "DRY RUN: would run winget install Git.Git --accept-source-agreements --accept-package-agreements"
        $Status.Git = "SKIPPED"
        return
    }

    try {
        & winget install Git.Git --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) {
            throw "winget exited with exit code $LASTEXITCODE"
        }
        Write-Step "winget git installation reported success"
        Update-ProcessPathFromRegistry

        if (Test-CommandOnPath "git") {
            Write-Step "git is now available on PATH"
            $Status.Git = "INSTALLED"
        } else {
            Write-Warning "git still not on PATH after winget install. The arcode-opencode-config plugin uses a tarball URL so it does not require git, but other plugins using the 'github:' npm install spec may fail on this machine. Restart the terminal and re-run."
            $Status.Git = "MISSING"
        }
    } catch {
        Write-Warning "winget install git failed: $_"
        $Status.Git = "MISSING"
    }
}

# --- Stage 3: opencode CLI ---

function Install-OpencodeCli {
    if (Test-CommandOnPath "opencode") {
        try {
            $version = & opencode --version 2>$null
            if ($version) {
                Write-Step "opencode already available (version $version)"
            } else {
                Write-Step "opencode already available"
            }
        } catch {
            Write-Step "opencode already available"
        }
        $Status.Opencode = "OK"
        return
    }

    if ($SkipOpencode) {
        Write-Step "opencode installation skipped (-SkipOpencode)"
        $Status.Opencode = "SKIPPED"
        return
    }

    if (-not (Test-CommandOnPath "npm")) {
        Write-Warning "npm not available; skipping opencode installation."
        $Status.Opencode = "SKIPPED"
        return
    }

    Write-Step "Installing opencode CLI via npm"
    $ok = Invoke-NpmInstallGlobal "opencode-ai"
    Update-ProcessPathFromRegistry

    if (Test-CommandOnPath "opencode") {
        $Status.Opencode = "INSTALLED"
    } else {
        if ($ok) {
            Write-Warning "opencode install reported success but command not found on PATH. Restart the terminal and re-run."
        }
        $Status.Opencode = "MISSING"
    }
}

# --- Stage 4: MCP prerequisites ---

function Install-CodegraphCli {
    if ($SkipMcp) {
        $Status.Codegraph = "SKIPPED"
        return
    }

    $binDir = Join-Path $env:LOCALAPPDATA "codegraph\current\bin"

    if (Test-CommandOnPath "codegraph.cmd") {
        Write-Step "codegraph.cmd already available on PATH"
        $Status.Codegraph = "OK"
        return
    }

    Write-Step "codegraph.cmd not found on PATH; installing via official installer"
    if ($env:ARCODE_INSTALL_DRYRUN -eq '1') {
        Write-Step "DRY RUN: would run irm https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.ps1 | iex"
        $Status.Codegraph = "SKIPPED"
        return
    }

    try {
        $installerUrl = "https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.ps1"
        $installScript = Invoke-RestMethod -Uri $installerUrl -ErrorAction Stop
        Invoke-Expression $installScript

        # Installer updates USER PATH; refresh process PATH and prepend known bin dir for this session.
        Update-ProcessPathFromRegistry
        if (Test-Path -LiteralPath $binDir) {
            $env:Path = "$binDir;$env:Path"
        }

        if (Test-CommandOnPath "codegraph.cmd") {
            $Status.Codegraph = "INSTALLED"
        } else {
            Write-Warning "codegraph installed but codegraph.cmd not on PATH. Restart the terminal and re-run."
            $Status.Codegraph = "MISSING"
        }
    } catch {
        Write-Warning "codegraph installation failed: $_"
        $Status.Codegraph = "MISSING"
    }
}

function Install-NpmMcpTool($name, $command) {
    if ($SkipMcp) {
        $Status[$name] = "SKIPPED"
        return
    }

    if (Test-CommandOnPath $command) {
        Write-Step "$command already available on PATH"
        $Status[$name] = "OK"
        return
    }

    if (-not (Test-CommandOnPath "npm")) {
        Write-Warning "npm not available; skipping $name installation."
        $Status[$name] = "SKIPPED"
        return
    }

    Write-Step "Installing $name via npm"
    $ok = Invoke-NpmInstallGlobal $name
    Update-ProcessPathFromRegistry

    if (Test-CommandOnPath $command) {
        $Status[$name] = "INSTALLED"
    } else {
        if ($ok) {
            Write-Warning "$name install reported success but $command not found on PATH. Restart the terminal and re-run."
        }
        $Status[$name] = "MISSING"
    }
}

function Test-RemoteMcp($url, $statusKey) {
    if ($SkipMcp) {
        $Status[$statusKey] = "SKIPPED"
        return
    }

    Write-Step "Checking reachability of $url (HEAD, 5s timeout)"
    try {
        $resp = Invoke-WebRequest -Uri $url -Method HEAD -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        $Status[$statusKey] = "REMOTE-OK"
    } catch {
        $e = $_
        $response = $e.Exception.Response
        if ($response -and $response.StatusCode -ge 100) {
            # Any HTTP response means reachable even if HEAD is not supported.
            $Status[$statusKey] = "REMOTE-OK"
        } else {
            $Status[$statusKey] = "REMOTE-FAIL"
            Write-Warning "$url is not reachable from this machine: $($e.Exception.Message)"
        }
    }
}

# --- Stage 5: Plugin config ---

function Test-ManagedPluginEntry($firstElement) {
    $oldSpec = "github:$Repo"
    $tarballPrefix = "https://github.com/$Repo/archive/refs/heads/"
    $tarballSuffix = ".tar.gz"
    if ($firstElement -eq $oldSpec) { return $true }
    if ($firstElement -and $firstElement.StartsWith($tarballPrefix) -and $firstElement.EndsWith($tarballSuffix)) { return $true }
    return $false
}

function Write-PluginConfig {
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

    $Status.PluginConfig = "OK"

    Write-Header "Resulting opencode.json"
    Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | Write-Host
}

# --- Main ---

# Validate repo format
if ($Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw "Repo must be in owner/name format (e.g. myorg/arcode-opencode-config). Got: $Repo"
}

Write-Header "Stage 1/6: Node.js / npm"
Install-NodeNpm

Write-Header "Stage 2/6: git"
Install-Git

Write-Header "Stage 3/6: opencode CLI"
Install-OpencodeCli

Write-Header "Stage 4/6: MCP prerequisites"
Install-CodegraphCli
Install-NpmMcpTool "lsp-mcp" "lsp-mcp.cmd"
Install-NpmMcpTool "websearch-mcp" "websearch-mcp.cmd"
Test-RemoteMcp "https://mcp.context7.com/mcp" "Context7"
Test-RemoteMcp "https://mcp.grep.app" "GrepApp"

Write-Header "Stage 5/6: arcode-opencode-config plugin config"
Write-PluginConfig

Write-Header "Stage 6/6: Summary"
Write-Status "Node.js / npm" $Status.NodeNpm
Write-Status "git" $Status.Git
Write-Status "opencode CLI" $Status.Opencode
Write-Status "codegraph" $Status.Codegraph
Write-Status "lsp-mcp" $Status["lsp-mcp"]
Write-Status "websearch-mcp" $Status["websearch-mcp"]
Write-Status "context7 (remote)" $Status.Context7
Write-Status "grep_app (remote)" $Status.GrepApp
Write-Status "arcode plugin cfg" $Status.PluginConfig

Write-Header "Next steps"
Write-Host @"
1. Restart the terminal so PATH changes (Node.js, git, opencode, MCP tools) take effect.
2. Restart opencode so the arcode-opencode-config plugin is downloaded from the tarball and fetches the manifest from:
   https://raw.githubusercontent.com/$Repo/$Branch/manifest.json
3. Edit manifest.json on GitHub; the next opencode start on every machine will pull the updated agents, MCP servers, and config keys.
"@
