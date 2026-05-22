# common.ps1 — shared helpers for claude-supervision wrappers
# Dot-source: . "$PSScriptRoot\common.ps1"
#
# Mirrors codex-supervision / kimi-supervision patterns:
#   - path resolution + env hygiene + UTF-8 console
#   - millisecond-precision session ID with PID + random suffix
#   - async stdout/stderr reads with timeout + defensive kill
#   - native session JSONL recovery when stdout is unexpectedly empty
#     (Claude Code writes its rollout to ~/.claude/projects/<encoded-cwd>/<uuid>.jsonl)
#   - secret-redacted CLI args recorded in session.json
#
# This file is the "deep module" — wrappers (claude-task.ps1 etc.) are thin
# UX layers on top of Invoke-ClaudeCli.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $script:OutputEncoding    = [System.Text.UTF8Encoding]::new($false)
} catch { }

function Get-ClaudeSupervisionHome {
    if ($env:CLAUDE_SUPERVISION_HOME) { return $env:CLAUDE_SUPERVISION_HOME }
    if ($env:LOCALAPPDATA)            { return (Join-Path $env:LOCALAPPDATA 'claude-supervision') }
    if ($env:USERPROFILE)             { return (Join-Path $env:USERPROFILE '.claude-supervision') }
    return 'C:\claude-supervision'
}

function Initialize-ClaudeEnvironment {
    foreach ($var in 'SystemRoot', 'windir', 'USERPROFILE', 'LOCALAPPDATA', 'APPDATA') {
        if (-not (Get-Item -Path ("env:$var") -ErrorAction SilentlyContinue)) {
            $value = [System.Environment]::GetEnvironmentVariable($var)
            if ($value) { Set-Item -Path ("env:$var") -Value $value }
        }
    }
    if (-not $env:HOME -and $env:USERPROFILE) { $env:HOME = $env:USERPROFILE }
}

function Resolve-ClaudePath {
    # Prefer native .exe — claude.exe at .local\bin is a single native binary, no
    # multi-layer .cmd chain like codex (which hit the Windows stdio race).
    # Use ProviderPath for UNC / \\?\ safety.
    if ($env:CLAUDE_CLI_PATH -and (Test-Path -LiteralPath $env:CLAUDE_CLI_PATH -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $env:CLAUDE_CLI_PATH).ProviderPath
    }
    foreach ($name in 'claude.exe', 'claude.cmd', 'claude') {
        $cmd = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    if ($env:USERPROFILE) {
        foreach ($rel in '.local\bin\claude.exe', 'bin\claude.exe', 'bin\claude.cmd') {
            $p = Join-Path $env:USERPROFILE $rel
            if (Test-Path -LiteralPath $p -PathType Leaf) {
                return (Resolve-Path -LiteralPath $p).ProviderPath
            }
        }
    }
    return $null
}

# Test-IsGitRepo was dead code in this skill (Claude CLI has no --skip-git-repo-check
# flag; it doesn't care whether the workspace is a git repo). Removed per review.

# Cache `claude --version` per PowerShell process so we don't pay ~100-500ms each run.
$script:CachedClaudeVersion = $null

function New-ClaudeSession {
    param(
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$Workspace
    )
    Initialize-ClaudeEnvironment
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    $rand  = (Get-Random -Minimum 1000 -Maximum 9999)
    $id = "$stamp-$PID-$rand-$Mode"
    $root = Get-ClaudeSupervisionHome
    $dir = Join-Path $root "sessions\$id"
    try {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    } catch {
        throw "host_error: cannot create session dir '$dir' — $($_.Exception.Message). Set CLAUDE_SUPERVISION_HOME to a writable path."
    }
    [pscustomobject]@{
        Id        = $id
        Dir       = $dir
        Workspace = (Resolve-Path -LiteralPath $Workspace).ProviderPath
        StartedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Write-SessionMeta {
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][hashtable]$Meta
    )
    $path = Join-Path $Session.Dir 'session.json'
    $merged = @{
        session_id = $Session.Id
        workspace  = $Session.Workspace
        started_at = $Session.StartedAt
    }
    foreach ($k in $Meta.Keys) { $merged[$k] = $Meta[$k] }
    $json = ($merged | ConvertTo-Json -Depth 8)
    [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Get-RedactedArgs {
    param([Parameter(Mandatory)][string[]]$ArgList)
    $out = New-Object System.Collections.Generic.List[string]
    $i = 0
    while ($i -lt $ArgList.Count) {
        $a = $ArgList[$i]
        if ($a -in @('--settings', '--mcp-config', '--agents', '--json-schema', '--system-prompt', '--append-system-prompt') -and ($i + 1) -lt $ArgList.Count) {
            $val = $ArgList[$i + 1]
            if ($val -match '(?i)(token|key|secret|password|api[_-]?key)') {
                $out.Add($a); $out.Add('<redacted-contains-credential-keywords>')
            } else {
                # Inline JSON/strings can be huge; truncate for readability in session.json.
                if ($val.Length -gt 256) {
                    $out.Add($a); $out.Add($val.Substring(0, 256) + "...[truncated $($val.Length) chars]")
                } else {
                    $out.Add($a); $out.Add($val)
                }
            }
            $i += 2
        } else {
            $out.Add($a); $i += 1
        }
    }
    return ,$out.ToArray()
}

function Get-PropOrDefault {
    param($Obj, [string]$Name, $Default = '?')
    if ($null -ne $Obj -and $Obj.PSObject.Properties[$Name]) { return $Obj.$Name }
    return $Default
}

function Get-EncodedClaudeProjectDir {
    # Claude Code encodes the cwd path into a directory name under ~/.claude/projects.
    # Empirically verified on claude 2.1.146 / Windows:
    #   C:\Users\you\.agents\skills\X -> C--Users-you--agents-skills-X
    #   (each \ becomes '-', each : becomes '-', each . becomes '-')
    # So [\\/:.] → '-'. The fallback scan handles paths the regex doesn't
    # quite match (unicode dirs, UNC, etc.).
    param([Parameter(Mandatory)][string]$Workspace)
    $abs = (Resolve-Path -LiteralPath $Workspace).ProviderPath
    return ($abs -replace '[\\/:.]', '-')
}

function Restore-ClaudeAnswerFromJsonl {
    <#
    When the wrapper's stdout is empty but Claude completed, the answer lives in
    ~/.claude/projects/<encoded-cwd>/<uuid>.jsonl. Recovery strategy:

      1. If $ForceSessionUuid was set, look for <uuid>.jsonl directly (exact match).
         This is the only way to be 100% safe against concurrent-run contamination.
      2. Otherwise, restrict candidates to JSONLs with LastWriteTime strictly inside
         this run's window [StartedUtc-2s, FinishedUtc+5s] and pick the newest.
      3. Verify the JSONL's session_meta.cwd matches our workspace when present.
      4. Walk lines backwards; prefer text blocks; fall back to thinking blocks
         only if no text block exists (so the user at least sees SOMETHING).
      5. Skip whitespace-only content.

    Returns @{ Text; JsonlPath; SessionId; SourceBlockType; AmbiguousMatch }
    or $null if recovery is impossible.
    #>
    param(
        [Parameter(Mandatory)][string]$Workspace,
        [Parameter(Mandatory)][datetime]$StartedUtc,
        [datetime]$FinishedUtc = [datetime]::UtcNow,
        [string]$ForceSessionUuid
    )
    if (-not $env:USERPROFILE) { return $null }
    $projectsRoot = Join-Path $env:USERPROFILE '.claude\projects'
    if (-not (Test-Path -LiteralPath $projectsRoot)) { return $null }

    $encoded = Get-EncodedClaudeProjectDir -Workspace $Workspace
    $exact = Join-Path $projectsRoot $encoded

    $candidates = @()
    # Strategy 1: exact UUID match if known. Validate UUID format strictly
    # before using it in Get-ChildItem -Filter — wildcards (*?[]) in -Filter
    # would otherwise let a malicious caller match arbitrary JSONL files.
    if ($ForceSessionUuid) {
        # UUID format: 8-4-4-4-12 hex digits with dashes (RFC 4122). Use [guid]::TryParse
        # rather than a loose regex so "--------" or all-hex strings don't sneak through.
        $parsedGuid = [guid]::Empty
        if (-not [guid]::TryParse($ForceSessionUuid, [ref]$parsedGuid)) {
            Write-Warning "-ForceSessionUuid '$ForceSessionUuid' is not a valid UUID; recovery may miss the intended session."
        } else {
            foreach ($dir in @($exact)) {
                $uuidFile = Join-Path $dir "$ForceSessionUuid.jsonl"
                if (Test-Path -LiteralPath $uuidFile) {
                    $candidates += (Get-Item -LiteralPath $uuidFile)
                }
            }
            # Also scan all project dirs for that uuid (cwd encoding fallback).
            if (-not $candidates) {
                $candidates += Get-ChildItem -LiteralPath $projectsRoot -Recurse -Filter "$ForceSessionUuid.jsonl" -ErrorAction SilentlyContinue
            }
        }
    }
    # Strategy 2: time-window scoped scan in encoded dir, then in all dirs.
    if (-not $candidates) {
        if (Test-Path -LiteralPath $exact) {
            $candidates += (Get-ChildItem -LiteralPath $exact -Filter '*.jsonl' -ErrorAction SilentlyContinue)
        }
        if (-not $candidates) {
            $candidates += Get-ChildItem -LiteralPath $projectsRoot -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter '*.jsonl' -ErrorAction SilentlyContinue }
        }
    }
    if (-not $candidates) { return $null }

    # Detect whether candidates include an exact filename match for the forced UUID.
    # If yes, skip the time window filter entirely — clock skew on the JSONL mtime
    # must not drop an explicit session-id match.
    $forceUuidExact = $false
    if ($ForceSessionUuid) {
        foreach ($c in $candidates) {
            if ([System.IO.Path]::GetFileNameWithoutExtension($c.FullName) -eq $ForceSessionUuid) {
                $forceUuidExact = $true
                break
            }
        }
    }

    # Wrap to array — Where-Object returns a single FileInfo (not array) when only
    # one match, and `.Count` on a scalar throws under StrictMode v2+. @() forces array.
    $windowStart = $StartedUtc.AddSeconds(-2)
    $windowEnd   = $FinishedUtc.AddSeconds(5)
    if ($forceUuidExact) {
        $inWindow = @($candidates | Where-Object {
            [System.IO.Path]::GetFileNameWithoutExtension($_.FullName) -eq $ForceSessionUuid
        })
    } else {
        $inWindow = @($candidates | Where-Object {
            $_.LastWriteTimeUtc -ge $windowStart -and $_.LastWriteTimeUtc -le $windowEnd
        })
    }
    if ($inWindow.Count -eq 0) { return $null }

    # Helper: read first ~15 lines of a JSONL and extract (sessionId, cwd) from
    # any record that has them at the top level. Real claude 2.1.146 JSONL puts
    # `cwd` at the top level of every event from line 3 onwards (alongside
    # `sessionId`, `version`, `gitBranch`). There is NO `session_meta` record.
    function script:Get-JsonlSessionFields {
        param([Parameter(Mandatory)][string]$Path)
        $sid = $null; $cwd = $null
        try {
            $hdrLines = [System.IO.File]::ReadAllLines($Path, [System.Text.UTF8Encoding]::new($false))
        } catch { return [pscustomobject]@{ SessionId = $null; Cwd = $null } }
        $scan = [Math]::Min($hdrLines.Length, 15)
        for ($k = 0; $k -lt $scan; $k++) {
            $hl = $hdrLines[$k]
            if (-not $hl.Trim()) { continue }
            try { $hobj = $hl | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if (-not $sid) { $sid = Get-PropOrDefault $hobj 'sessionId' $null }
            if (-not $cwd) { $cwd = Get-PropOrDefault $hobj 'cwd' $null }
            if ($sid -and $cwd) { break }
        }
        [pscustomobject]@{ SessionId = $sid; Cwd = $cwd }
    }

    # Normalize cwd strings for case-insensitive trailing-slash-tolerant compare.
    $normWorkspace = (Resolve-Path -LiteralPath $Workspace).ProviderPath.TrimEnd('\', '/').ToLowerInvariant()

    # Score each in-window candidate: prefer the one whose JSONL cwd matches.
    # If -ForceSessionUuid was given, the matching one wins outright (and bypasses
    # the time window — clock skew on the JSONL mtime shouldn't drop an exact
    # session id match).
    $candidate = $null
    $sessionId = $null
    $jsonlCwd  = $null
    $matchingCwd = New-Object System.Collections.Generic.List[object]
    $cwdUnknown  = New-Object System.Collections.Generic.List[object]
    foreach ($c in $inWindow) {
        $fields = Get-JsonlSessionFields -Path $c.FullName
        $cName = [System.IO.Path]::GetFileNameWithoutExtension($c.FullName)
        # Exact UUID match (filename) wins.
        if ($ForceSessionUuid -and ($cName -eq $ForceSessionUuid -or $fields.SessionId -eq $ForceSessionUuid)) {
            $candidate = $c
            $sessionId = $fields.SessionId
            $jsonlCwd  = $fields.Cwd
            $matchingCwd.Clear(); $cwdUnknown.Clear()
            $matchingCwd.Add($c)
            break
        }
        if ($fields.Cwd) {
            $normCwd = $fields.Cwd.TrimEnd('\', '/').ToLowerInvariant()
            if ($normCwd -eq $normWorkspace) {
                $matchingCwd.Add([pscustomobject]@{ File = $c; SessionId = $fields.SessionId; Cwd = $fields.Cwd })
            }
        } else {
            $cwdUnknown.Add([pscustomobject]@{ File = $c; SessionId = $fields.SessionId; Cwd = $null })
        }
    }
    # If -ForceSessionUuid was supplied, ALSO try a wider scan ignoring the window
    # (clock skew, stale mtime). Filename match is authoritative.
    if ($ForceSessionUuid -and $matchingCwd.Count -eq 0) {
        $byName = $candidates | Where-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.FullName) -eq $ForceSessionUuid }
        if ($byName) {
            $candidate = $byName | Select-Object -First 1
            $fields = Get-JsonlSessionFields -Path $candidate.FullName
            $sessionId = $fields.SessionId
            $jsonlCwd  = $fields.Cwd
        }
    }

    if (-not $candidate) {
        # No exact UUID match; prefer cwd-matching candidates, otherwise unknown-cwd.
        $picked = $null
        if ($matchingCwd.Count -gt 0) {
            $picked = $matchingCwd |
                ForEach-Object { if ($_ -is [System.IO.FileInfo]) { $_ } else { $_.File } } |
                Sort-Object LastWriteTimeUtc -Descending |
                Select-Object -First 1
        } elseif ($cwdUnknown.Count -gt 0) {
            # If NO candidate's cwd matches but some are missing the cwd field, accept
            # the newest unknown — we don't want to drop a legitimate recovery just
            # because claude didn't write cwd in the first 15 lines.
            $picked = $cwdUnknown |
                ForEach-Object { $_.File } |
                Sort-Object LastWriteTimeUtc -Descending |
                Select-Object -First 1
        } else {
            # All candidates had wrong cwd — refuse contamination.
            return $null
        }
        $candidate = $picked
        $fields = Get-JsonlSessionFields -Path $candidate.FullName
        $sessionId = $fields.SessionId
        $jsonlCwd  = $fields.Cwd
    }

    # Mark ambiguous whenever the heuristic pool had more than one candidate, NOT just
    # cwd-matching ones — cwd-unknown fallback is also heuristic and callers should know.
    $ambiguous = ($inWindow.Count -gt 1) -and -not $forceUuidExact

    try {
        $lines = [System.IO.File]::ReadAllLines($candidate.FullName, [System.Text.UTF8Encoding]::new($false))
    } catch { return $null }

    # Walk in reverse; prefer text blocks, fall back to thinking-only as last resort.
    $textFound = $null
    $thinkingFallback = $null
    for ($i = $lines.Length - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
        if (-not $line.Trim()) { continue }
        try { $obj = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $type = Get-PropOrDefault $obj 'type' $null
        if ($type -ne 'assistant') { continue }
        $message = Get-PropOrDefault $obj 'message' $null
        if (-not $message) { continue }
        $content = Get-PropOrDefault $message 'content' $null
        if (-not $content) { continue }
        # content can be string OR array-of-blocks.
        if ($content -is [string]) {
            if ($content.Trim()) {
                $textFound = $content
                break
            }
            continue
        }
        foreach ($block in @($content)) {
            if (-not $block) { continue }
            $btype = Get-PropOrDefault $block 'type' $null
            if ($btype -eq 'text') {
                $t = Get-PropOrDefault $block 'text' $null
                if ($t -and $t.Trim()) { $textFound = $t; break }
            } elseif ($btype -eq 'thinking' -and -not $thinkingFallback) {
                $t = Get-PropOrDefault $block 'thinking' (Get-PropOrDefault $block 'text' $null)
                if ($t -and $t.Trim()) { $thinkingFallback = $t }
            }
        }
        if ($textFound) { break }
    }
    $recoveredText = if ($textFound) { $textFound } else { $thinkingFallback }
    if (-not $recoveredText) { return $null }
    return [pscustomobject]@{
        Text            = $recoveredText
        JsonlPath       = $candidate.FullName
        SessionId       = $sessionId
        SourceBlockType = if ($textFound) { 'text' } else { 'thinking' }
        AmbiguousMatch  = $ambiguous
    }
}

function Invoke-ClaudeCli {
    <#
    Run `claude --print ...` non-interactively. Captures stdout, stderr, exit code,
    duration. Writes last-prompt.txt, last-response.txt, stderr.log, session.json
    to the session dir. Deadlock-safe async I/O + timeout + native recovery.

    Three exec modes:
      - 'plain':    fresh `claude --print`
      - 'continue': `claude --print --continue`
      - 'resume':   `claude --print --resume <id-or-picker>`
    #>
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$Prompt,

        [Parameter(Mandatory)][ValidateSet('plain', 'continue', 'resume')]
        [string]$ExecMode,

        # ---- Resume targeting ----
        [string]$ResumeSessionId,
        [switch]$ForkSession,

        # ---- Permissions / tools ----
        [ValidateSet('default', 'acceptEdits', 'auto', 'bypassPermissions', 'dontAsk', 'plan')]
        [string]$PermissionMode = 'default',
        [switch]$DangerouslySkipPermissions,
        [switch]$AllowDangerouslySkipPermissions,
        [string[]]$AllowedTools,
        [string[]]$DisallowedTools,
        [string]$ToolsSpec,
        [string[]]$AddDirs,
        [string]$PermissionPromptTool,         # --permission-prompt-tool <mcp-tool>

        # ---- Model / effort / budget ----
        [string]$Model,
        [ValidateSet('low', 'medium', 'high', 'xhigh', 'max')]
        [string]$Effort,
        [string]$FallbackModel,                # --fallback-model
        [double]$MaxBudgetUsd,                 # --max-budget-usd (print only)
        [int]$MaxTurns,                        # --max-turns (print only)

        # ---- Output / format ----
        [ValidateSet('text', 'json', 'stream-json')]
        [string]$OutputFormat = 'text',
        [ValidateSet('text', 'stream-json')]
        [string]$InputFormat,                  # --input-format (rare)
        [switch]$IncludeHookEvents,            # requires --output-format stream-json
        [switch]$IncludePartialMessages,       # requires --output-format stream-json
        [string]$JsonSchemaInline,
        [string]$JsonSchemaFile,
        [switch]$VerboseOutput,                # --verbose (renamed to avoid auto common-param -Verbose)

        # ---- System prompt overrides ----
        [string]$SystemPrompt,                 # --system-prompt (replace)
        [string]$SystemPromptFile,             # --system-prompt-file (replace from file)
        [string]$AppendSystemPrompt,           # --append-system-prompt
        [string]$AppendSystemPromptFile,       # --append-system-prompt-file

        # ---- Agents ----
        [string]$Agent,                        # --agent <name>
        [string]$AgentsInline,                 # --agents '<json>'
        [string]$AgentsFile,                   # path to JSON file (read into inline)

        # ---- MCP / settings / plugins ----
        [string[]]$McpConfig,                  # --mcp-config (space-separated paths/JSON)
        [switch]$StrictMcpConfig,
        [string]$Settings,                     # path-or-json
        [string]$SettingsFile,                 # explicit file form (read into inline)
        [string]$SettingSources,               # "user,project,local"
        [string[]]$PluginDirs,                 # --plugin-dir (repeatable)
        [string[]]$PluginUrls,                 # --plugin-url (repeatable)

        # ---- Hooks lifecycle ----
        [switch]$Init,                         # --init  (Setup hooks before session)
        [switch]$InitOnly,                     # --init-only (Setup + SessionStart, then exit)
        [switch]$Maintenance,                  # --maintenance

        # ---- Persistence / cleanliness ----
        [switch]$NoSessionPersistence,
        [switch]$Bare,
        [switch]$DisableSlashCommands,
        [switch]$ExcludeDynamicSystemPromptSections,
        [string]$Name,
        [string]$ForceSessionUuid,
        [string[]]$Betas,                      # --betas <list>

        # ---- Diagnostics ----
        [string]$DebugFilter,                  # --debug [filter] (renamed to avoid auto common-param -Debug)
        [string]$DebugFile,                    # --debug-file <path>

        # ---- File resources ----
        [string[]]$Files,                      # --file <specs...> (file_id:relative)

        # ---- Multimodal (image attachments) ----
        # Claude CLI has NO -i/--image flag at 2.1.146. Multimodal works by
        # referencing absolute paths in the prompt — claude's Read tool fetches
        # the image and the multimodal model receives it as a vision block.
        # We accept -Images for ergonomics: validate paths, resolve against
        # -Workspace, auto-extend with --add-dir, prepend an instruction block.
        [string[]]$Images,

        # ---- Safety ----
        [int]$TimeoutSec = 1800
    )

    Initialize-ClaudeEnvironment

    # ---- Multimodal: validate -Images, auto-extend AddDirs, prepend prompt ----
    $resolvedImages = New-Object System.Collections.Generic.List[string]
    $imageDirsToAdd = New-Object System.Collections.Generic.List[string]
    if ($Images) {
        if ($Images.Count -gt 100) {
            throw "Claude accepts at most 100 images per request; got $($Images.Count)."
        }
        $allowedExt = '.jpg', '.jpeg', '.png', '.gif', '.webp'
        $workspaceRoot = (Resolve-Path -LiteralPath $Session.Workspace).ProviderPath.TrimEnd('\','/')
        foreach ($img in $Images) {
            if (-not $img) { continue }
            $wasRelative = -not [System.IO.Path]::IsPathRooted($img)
            $candidate = if ($wasRelative) { Join-Path $Session.Workspace $img } else { $img }
            if (-not (Test-Path -LiteralPath $candidate)) {
                throw "Image not found: $candidate (from '$img')"
            }
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                throw "Image path is a directory, not a file: $candidate"
            }
            $abs = (Resolve-Path -LiteralPath $candidate).ProviderPath
            $ext = [System.IO.Path]::GetExtension($abs).ToLowerInvariant()
            if ($ext -notin $allowedExt) {
                Write-Warning "Image '$abs' has extension '$ext' (claude vision supports $($allowedExt -join '/')); model may fail to read it."
            }
            $sizeBytes = (Get-Item -LiteralPath $abs).Length
            if ($sizeBytes -gt 5MB) {
                Write-Warning "Image '$abs' is $([Math]::Round($sizeBytes/1MB, 1))MB (claude vision limit is 5MB per image); the model may reject it."
            }
            # Sibling-prefix-safe boundary check using GetRelativePath (.NET Core 2+).
            if ($wasRelative) {
                $rel = [System.IO.Path]::GetRelativePath($workspaceRoot, $abs)
                if ($rel.StartsWith('..') -or [System.IO.Path]::IsPathRooted($rel)) {
                    throw "Image '$img' resolves to '$abs', outside -Workspace '$workspaceRoot'. Pass an absolute path to opt in to off-workspace files."
                }
            }
            [void]$resolvedImages.Add($abs)
            # Track parent dir for --add-dir extension (claude needs read access).
            $parent = [System.IO.Path]::GetDirectoryName($abs)
            if ($parent) {
                $parentNorm = $parent.TrimEnd('\','/').ToLowerInvariant()
                $wsNorm = $workspaceRoot.ToLowerInvariant()
                if (-not ($parentNorm -eq $wsNorm -or $parentNorm.StartsWith($wsNorm + [System.IO.Path]::DirectorySeparatorChar))) {
                    if ($imageDirsToAdd -notcontains $parent) { [void]$imageDirsToAdd.Add($parent) }
                }
            }
        }
        # Auto-merge image parent dirs into AddDirs.
        if ($imageDirsToAdd.Count -gt 0) {
            $merged = New-Object System.Collections.Generic.List[string]
            if ($AddDirs) { foreach ($d in $AddDirs) { if ($d) { [void]$merged.Add($d) } } }
            foreach ($d in $imageDirsToAdd) { if ($merged -notcontains $d) { [void]$merged.Add($d) } }
            $AddDirs = $merged.ToArray()
        }
        # Prepend an attachment block so the model sees the images explicitly.
        $imgBlock = "<attached_images>`n"
        foreach ($p in $resolvedImages) { $imgBlock += "- $p`n" }
        $imgBlock += @"
</attached_images>

The above images are attached for vision analysis. Use your Read tool on each
path to view the image content; claude is multimodal and the Read tool delivers
PNG/JPEG/GIF/WebP files as vision blocks. After analyzing the images, complete
the task below.

"@
        $Prompt = $imgBlock + $Prompt
    }

    $promptPath = Join-Path $Session.Dir 'last-prompt.txt'
    [System.IO.File]::WriteAllText($promptPath, $Prompt, [System.Text.UTF8Encoding]::new($false))

    $claude = Resolve-ClaudePath
    if (-not $claude) {
        $meta = @{
            mode                  = $Mode
            exit_code             = -1
            result_classification = 'host_error'
            error                 = 'claude CLI not found. Install via "npm install -g @anthropic-ai/claude-code" or set CLAUDE_CLI_PATH.'
        }
        Write-SessionMeta -Session $Session -Meta $meta
        throw $meta.error
    }

    if (-not $script:CachedClaudeVersion) {
        $script:CachedClaudeVersion = ((& $claude --version 2>$null) | Out-String).Trim()
    }
    $claudeVersion = $script:CachedClaudeVersion

    # ---- Build argument list -------------------------------------------------
    $cliArgs = New-Object System.Collections.Generic.List[string]
    [void]$cliArgs.Add('--print')
    [void]$cliArgs.Add('--output-format'); [void]$cliArgs.Add($OutputFormat)
    if ($InputFormat) { [void]$cliArgs.Add('--input-format'); [void]$cliArgs.Add($InputFormat) }

    # Resume / continue
    switch ($ExecMode) {
        'continue' { [void]$cliArgs.Add('--continue') }
        'resume'   {
            [void]$cliArgs.Add('--resume')
            if ($ResumeSessionId) { [void]$cliArgs.Add($ResumeSessionId) }
        }
    }
    if ($ForkSession) {
        if ($ExecMode -eq 'plain') {
            Write-Warning '-ForkSession ignored: only useful with -Continue / -Resume.'
        } else {
            [void]$cliArgs.Add('--fork-session')
        }
    }
    if ($ForceSessionUuid) {
        if ($ExecMode -ne 'plain') {
            Write-Warning '-ForceSessionUuid ignored: only applies to fresh plain sessions.'
        } else {
            [void]$cliArgs.Add('--session-id'); [void]$cliArgs.Add($ForceSessionUuid)
        }
    }

    # Permissions
    if ($DangerouslySkipPermissions) {
        [void]$cliArgs.Add('--dangerously-skip-permissions')
    } else {
        [void]$cliArgs.Add('--permission-mode'); [void]$cliArgs.Add($PermissionMode)
    }
    if ($AllowDangerouslySkipPermissions) { [void]$cliArgs.Add('--allow-dangerously-skip-permissions') }
    if ($PermissionPromptTool) { [void]$cliArgs.Add('--permission-prompt-tool'); [void]$cliArgs.Add($PermissionPromptTool) }

    if ($AllowedTools)    { foreach ($t in $AllowedTools)    { if ($t) { [void]$cliArgs.Add('--allowedTools');    [void]$cliArgs.Add($t) } } }
    if ($DisallowedTools) { foreach ($t in $DisallowedTools) { if ($t) { [void]$cliArgs.Add('--disallowedTools'); [void]$cliArgs.Add($t) } } }
    if ($PSBoundParameters.ContainsKey('ToolsSpec')) { [void]$cliArgs.Add('--tools'); [void]$cliArgs.Add($ToolsSpec) }
    if ($AddDirs) { foreach ($d in $AddDirs) { if ($d) { [void]$cliArgs.Add('--add-dir'); [void]$cliArgs.Add($d) } } }

    # Model / effort / budget / turns
    if ($Model)         { [void]$cliArgs.Add('--model'); [void]$cliArgs.Add($Model) }
    if ($Effort)        { [void]$cliArgs.Add('--effort'); [void]$cliArgs.Add($Effort) }
    if ($FallbackModel) { [void]$cliArgs.Add('--fallback-model'); [void]$cliArgs.Add($FallbackModel) }
    if ($PSBoundParameters.ContainsKey('MaxBudgetUsd') -and $MaxBudgetUsd -gt 0) {
        # Force invariant culture so de-DE etc. don't emit `0,5` instead of `0.5`.
        [void]$cliArgs.Add('--max-budget-usd')
        [void]$cliArgs.Add($MaxBudgetUsd.ToString([System.Globalization.CultureInfo]::InvariantCulture))
    }
    if ($PSBoundParameters.ContainsKey('MaxTurns') -and $MaxTurns -gt 0) {
        [void]$cliArgs.Add('--max-turns'); [void]$cliArgs.Add([string]$MaxTurns)
    }

    # Stream-json gated flags
    if ($IncludeHookEvents) {
        if ($OutputFormat -ne 'stream-json') {
            Write-Warning '-IncludeHookEvents requires -OutputFormat stream-json; flag dropped.'
        } else { [void]$cliArgs.Add('--include-hook-events') }
    }
    if ($IncludePartialMessages) {
        if ($OutputFormat -ne 'stream-json') {
            Write-Warning '-IncludePartialMessages requires -OutputFormat stream-json; flag dropped.'
        } else { [void]$cliArgs.Add('--include-partial-messages') }
    }

    # JSON Schema
    $jsonSchemaResolved = $null
    if ($JsonSchemaFile -and $JsonSchemaInline) {
        Write-Warning '-JsonSchemaFile and -JsonSchemaInline both given; using -JsonSchemaFile.'
    }
    if ($JsonSchemaFile) {
        $cand = $JsonSchemaFile
        if (-not [System.IO.Path]::IsPathRooted($cand)) { $cand = Join-Path $Session.Workspace $cand }
        if (-not (Test-Path -LiteralPath $cand -PathType Leaf)) { throw "JsonSchemaFile not found: $cand" }
        $jsonSchemaResolved = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $cand).ProviderPath, [System.Text.UTF8Encoding]::new($false))
    } elseif ($JsonSchemaInline) {
        $jsonSchemaResolved = $JsonSchemaInline
    }
    if ($jsonSchemaResolved) {
        [void]$cliArgs.Add('--json-schema'); [void]$cliArgs.Add($jsonSchemaResolved)
    }

    # System prompt (mutually exclusive replace flags)
    if ($SystemPrompt -and $SystemPromptFile) {
        throw '-SystemPrompt and -SystemPromptFile are mutually exclusive (both replace the default).'
    }
    if ($SystemPrompt)     { [void]$cliArgs.Add('--system-prompt'); [void]$cliArgs.Add($SystemPrompt) }
    if ($SystemPromptFile) {
        $cand = $SystemPromptFile
        if (-not [System.IO.Path]::IsPathRooted($cand)) { $cand = Join-Path $Session.Workspace $cand }
        if (-not (Test-Path -LiteralPath $cand -PathType Leaf)) { throw "SystemPromptFile not found: $cand" }
        [void]$cliArgs.Add('--system-prompt-file'); [void]$cliArgs.Add((Resolve-Path -LiteralPath $cand).ProviderPath)
    }
    if ($AppendSystemPrompt)     { [void]$cliArgs.Add('--append-system-prompt'); [void]$cliArgs.Add($AppendSystemPrompt) }
    if ($AppendSystemPromptFile) {
        $cand = $AppendSystemPromptFile
        if (-not [System.IO.Path]::IsPathRooted($cand)) { $cand = Join-Path $Session.Workspace $cand }
        if (-not (Test-Path -LiteralPath $cand -PathType Leaf)) { throw "AppendSystemPromptFile not found: $cand" }
        [void]$cliArgs.Add('--append-system-prompt-file'); [void]$cliArgs.Add((Resolve-Path -LiteralPath $cand).ProviderPath)
    }

    # Agents
    if ($Agent) { [void]$cliArgs.Add('--agent'); [void]$cliArgs.Add($Agent) }
    if ($AgentsFile -and $AgentsInline) {
        Write-Warning '-AgentsFile and -AgentsInline both given; using -AgentsFile.'
    }
    if ($AgentsFile) {
        $cand = $AgentsFile
        if (-not [System.IO.Path]::IsPathRooted($cand)) { $cand = Join-Path $Session.Workspace $cand }
        if (-not (Test-Path -LiteralPath $cand -PathType Leaf)) { throw "AgentsFile not found: $cand" }
        $agentsJson = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $cand).ProviderPath, [System.Text.UTF8Encoding]::new($false))
        [void]$cliArgs.Add('--agents'); [void]$cliArgs.Add($agentsJson)
    } elseif ($AgentsInline) {
        [void]$cliArgs.Add('--agents'); [void]$cliArgs.Add($AgentsInline)
    }

    # MCP
    if ($McpConfig) {
        foreach ($m in $McpConfig) {
            if (-not $m) { continue }
            [void]$cliArgs.Add('--mcp-config'); [void]$cliArgs.Add($m)
        }
    }
    if ($StrictMcpConfig) {
        if (-not $McpConfig) {
            Write-Warning '-StrictMcpConfig with no -McpConfig means NO MCP servers will load — usually not intended.'
        }
        [void]$cliArgs.Add('--strict-mcp-config')
    }

    # Settings
    if ($SettingsFile -and $Settings) {
        Write-Warning '-SettingsFile and -Settings both given; -SettingsFile takes precedence.'
    }
    if ($SettingsFile) {
        $cand = $SettingsFile
        if (-not [System.IO.Path]::IsPathRooted($cand)) { $cand = Join-Path $Session.Workspace $cand }
        if (-not (Test-Path -LiteralPath $cand -PathType Leaf)) { throw "SettingsFile not found: $cand" }
        [void]$cliArgs.Add('--settings'); [void]$cliArgs.Add((Resolve-Path -LiteralPath $cand).ProviderPath)
    } elseif ($Settings) {
        [void]$cliArgs.Add('--settings'); [void]$cliArgs.Add($Settings)
    }
    if ($SettingSources) { [void]$cliArgs.Add('--setting-sources'); [void]$cliArgs.Add($SettingSources) }

    # Plugins
    if ($PluginDirs) { foreach ($p in $PluginDirs) { if ($p) { [void]$cliArgs.Add('--plugin-dir'); [void]$cliArgs.Add($p) } } }
    if ($PluginUrls) { foreach ($u in $PluginUrls) { if ($u) { [void]$cliArgs.Add('--plugin-url'); [void]$cliArgs.Add($u) } } }

    # Hooks lifecycle
    if ($Init)        { [void]$cliArgs.Add('--init') }
    if ($InitOnly)    { [void]$cliArgs.Add('--init-only') }
    if ($Maintenance) { [void]$cliArgs.Add('--maintenance') }

    # Persistence / cleanliness
    if ($NoSessionPersistence) {
        [void]$cliArgs.Add('--no-session-persistence')
        if ($ExecMode -ne 'plain') {
            Write-Warning '-NoSessionPersistence with -Continue / -Resume: this turn will not be recorded; future resume from THIS turn will fail.'
        }
    }
    if ($Bare)                              { [void]$cliArgs.Add('--bare') }
    if ($DisableSlashCommands)              { [void]$cliArgs.Add('--disable-slash-commands') }
    if ($ExcludeDynamicSystemPromptSections){ [void]$cliArgs.Add('--exclude-dynamic-system-prompt-sections') }
    if ($Name)                              { [void]$cliArgs.Add('--name'); [void]$cliArgs.Add($Name) }
    if ($Betas) { foreach ($b in $Betas) { if ($b) { [void]$cliArgs.Add('--betas'); [void]$cliArgs.Add($b) } } }

    # Diagnostics
    if ($PSBoundParameters.ContainsKey('DebugFilter')) {
        if ($DebugFilter) { [void]$cliArgs.Add('--debug'); [void]$cliArgs.Add($DebugFilter) }
        else              { [void]$cliArgs.Add('--debug') }
    }
    if ($DebugFile)     { [void]$cliArgs.Add('--debug-file'); [void]$cliArgs.Add($DebugFile) }
    if ($VerboseOutput) { [void]$cliArgs.Add('--verbose') }

    # File resources
    if ($Files) { foreach ($f in $Files) { if ($f) { [void]$cliArgs.Add('--file'); [void]$cliArgs.Add($f) } } }

    # ---- Spawn process -------------------------------------------------------
    $stdoutPath = Join-Path $Session.Dir 'last-response.txt'
    $stderrPath = Join-Path $Session.Dir 'stderr.log'

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $claude
    foreach ($a in $cliArgs) { [void]$psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory       = $Session.Workspace
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.StandardInputEncoding  = [System.Text.UTF8Encoding]::new($false)   # default is Console.InputEncoding — non-UTF-8 codepages corrupt Unicode prompts
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

    $startedUtc = [datetime]::UtcNow
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = [System.Diagnostics.Process]::Start($psi)

    # CRITICAL: kick off async reads BEFORE writing stdin. Otherwise a prompt
    # larger than the OS pipe buffer (~64KB on Windows) deadlocks:
    #   stdin.Write blocks waiting for claude to drain stdin →
    #   claude blocks writing to stdout because we're not reading.
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    # Now safe to write the prompt — claude can drain stdin while we drain stdout.
    # Wrap in try/catch: if claude dies during startup (auth fail, binary missing
    # libs, etc.), the stdin pipe closes and Write throws IOException. We don't
    # want that to crash the wrapper before WaitForExit + session.json write.
    try {
        $proc.StandardInput.Write($Prompt)
    } catch { }
    try { $proc.StandardInput.Close() } catch { }

    $timeoutMs = if ($TimeoutSec -le 0) { [int]::MaxValue } else { [int]([Math]::Min($TimeoutSec * 1000L, [int]::MaxValue)) }
    $exited = $proc.WaitForExit($timeoutMs)

    $timedOut = $false
    if (-not $exited) {
        $timedOut = $true
        try { $proc.Kill($true) } catch { try { $proc.Kill() } catch { } }
        try { $proc.WaitForExit(5000) | Out-Null } catch { }
    } else {
        try { $proc.WaitForExit() } catch { }
    }
    try {
        [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 5000) | Out-Null
    } catch { }
    $sw.Stop()

    $stdoutPipe = try { if ($stdoutTask.IsCompleted) { $stdoutTask.GetAwaiter().GetResult() } else { '' } } catch { '' }
    $stderr     = try { if ($stderrTask.IsCompleted) { $stderrTask.GetAwaiter().GetResult() } else { '' } } catch { '' }

    # ---- Native session recovery if stdout is empty --------------------------
    # Defensive ExitCode access: even though `-not $timedOut` short-circuits in
    # the normal exit path, Process.ExitCode throws InvalidOperationException
    # before HasExited becomes true. Guard explicitly.
    $recovered = $null
    $recoveredFromJsonl = $false
    $recoverySource = $null
    $recoveryJsonlPath = $null
    $recoveryAmbiguous = $false
    if ((-not $stdoutPipe.Trim()) -and (-not $timedOut) -and $proc.HasExited -and ($proc.ExitCode -eq 0)) {
        try {
            $rec = Restore-ClaudeAnswerFromJsonl `
                -Workspace $Session.Workspace `
                -StartedUtc $startedUtc `
                -FinishedUtc ([datetime]::UtcNow) `
                -ForceSessionUuid $ForceSessionUuid
            if ($rec -and $rec.Text -and $rec.Text.Trim()) {
                $recovered = $rec.Text
                $recoveredFromJsonl = $true
                $recoverySource = $rec.SourceBlockType
                $recoveryJsonlPath = $rec.JsonlPath
                $recoveryAmbiguous = [bool]$rec.AmbiguousMatch
            }
        } catch { }
    }

    $stdout = if ($recovered -and $recovered.Trim()) { $recovered } else { $stdoutPipe }

    [System.IO.File]::WriteAllText($stdoutPath, $stdout, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($stderrPath, $stderr, [System.Text.UTF8Encoding]::new($false))

    # Reading $proc.ExitCode before the process has exited throws
    # InvalidOperationException. WaitForExit(5000) after Kill can return false
    # (process still alive). Guard with HasExited.
    $safeExit = if ($proc.HasExited) { $proc.ExitCode } else { -1 }

    # ---- Classify ------------------------------------------------------------
    $cls = 'usable'
    if ($timedOut) {
        $cls = 'timeout'
    } elseif ($safeExit -ne 0) {
        $cls = 'error'
        if ($stderr -match '(?i)(login|unauthorized|not authenticated|please run.*login|\b401\b|\b403\b|credentials.*(expired|invalid)|token.*(refresh|expired)|auth.*(failed|expired)|api[_-]?key)') {
            $cls = 'auth_required'
        } elseif ($stderr -match '(?i)budget.*exceed|max[_-]?budget|spent.*limit') {
            $cls = 'budget_exceeded'
        } elseif ($stderr -match '(?i)max[_-]?turns.*reach|turn[_-]?limit') {
            $cls = 'turn_limit'
        }
    } elseif (-not $stdout.Trim()) {
        $cls = 'empty'
    }

    $permissionLabel = if ($DangerouslySkipPermissions) { 'dangerously-skip' } else { $PermissionMode }

    $meta = @{
        mode                      = $Mode
        exec_mode                 = $ExecMode
        claude_version            = $claudeVersion
        cli_args                  = (Get-RedactedArgs -ArgList $cliArgs.ToArray())
        permission_mode           = $permissionLabel
        skip_permissions          = [bool]$DangerouslySkipPermissions
        model                     = $Model
        effort                    = $Effort
        fallback_model            = $FallbackModel
        resume_session_id         = $ResumeSessionId
        fork_session              = [bool]$ForkSession
        force_session_uuid        = $ForceSessionUuid
        output_format             = $OutputFormat
        input_format              = $InputFormat
        has_json_schema           = [bool]$jsonSchemaResolved
        max_budget_usd            = if ($PSBoundParameters.ContainsKey('MaxBudgetUsd')) { $MaxBudgetUsd } else { $null }
        max_turns                 = if ($PSBoundParameters.ContainsKey('MaxTurns')) { $MaxTurns } else { $null }
        no_session_persistence    = [bool]$NoSessionPersistence
        bare                      = [bool]$Bare
        disable_slash_commands    = [bool]$DisableSlashCommands
        exclude_dynamic_prompt    = [bool]$ExcludeDynamicSystemPromptSections
        system_prompt_replaced    = [bool]($SystemPrompt -or $SystemPromptFile)
        system_prompt_appended    = [bool]($AppendSystemPrompt -or $AppendSystemPromptFile)
        agent                     = $Agent
        has_agents_inline         = [bool]($AgentsInline -or $AgentsFile)
        mcp_config_count          = if ($McpConfig) { $McpConfig.Count } else { 0 }
        image_count               = $resolvedImages.Count
        image_paths               = $resolvedImages.ToArray()
        image_dirs_added          = $imageDirsToAdd.ToArray()
        strict_mcp_config         = [bool]$StrictMcpConfig
        plugin_dir_count          = if ($PluginDirs) { $PluginDirs.Count } else { 0 }
        plugin_url_count          = if ($PluginUrls) { $PluginUrls.Count } else { 0 }
        timeout_sec               = $TimeoutSec
        timed_out                 = $timedOut
        exit_code                 = $safeExit
        finished_at               = (Get-Date).ToUniversalTime().ToString('o')
        duration_ms               = $sw.ElapsedMilliseconds
        prompt_chars              = $Prompt.Length
        response_chars            = $stdout.Length
        recovered_from_jsonl      = $recoveredFromJsonl
        recovery_source_block     = $recoverySource
        recovery_jsonl_path       = $recoveryJsonlPath
        recovery_ambiguous        = $recoveryAmbiguous
        result_classification     = $cls
    }
    Write-SessionMeta -Session $Session -Meta $meta

    [pscustomobject]@{
        Session            = $Session
        Meta               = $meta
        Stdout             = $stdout
        Stderr             = $stderr
        ExitCode           = $safeExit
        Classification     = $cls
        TimedOut           = $timedOut
        RecoveredFromJsonl = $recoveredFromJsonl
    }
}

function Format-ClaudeHeader {
    param([Parameter(Mandatory)][pscustomobject]$Result)
    $lines = @(
        "# claude-supervision: $($Result.Meta.mode) ($($Result.Session.Id))"
        "workspace=$($Result.Session.Workspace)"
        "exit=$($Result.ExitCode)  classification=$($Result.Classification)  duration_ms=$($Result.Meta.duration_ms)  timed_out=$($Result.TimedOut)"
    )
    if ($Result.Meta.model)          { $lines += "model=$($Result.Meta.model)" }
    if ($Result.Meta.effort)         { $lines += "effort=$($Result.Meta.effort)" }
    if ($Result.Meta.fallback_model) { $lines += "fallback_model=$($Result.Meta.fallback_model)" }
    $lines += "permission=$($Result.Meta.permission_mode)"
    if ($Result.RecoveredFromJsonl) {
        $rsrc = if ($Result.Meta.PSObject.Properties['recovery_source_block']) { $Result.Meta.recovery_source_block } else { 'text' }
        $line = "(stdout was empty — answer recovered from ~/.claude/projects/<cwd>/*.jsonl, block_type=$rsrc"
        if ($Result.Meta.PSObject.Properties['recovery_ambiguous'] -and $Result.Meta.recovery_ambiguous) {
            $line += ' — WARNING: multiple JSONLs matched the time window; pass -ForceSessionUuid for safety'
        }
        $line += ')'
        $lines += $line
    }
    $lines += '---'
    return ($lines -join "`n")
}

function Resolve-ClaudeStreamOutput {
    param([Parameter(Mandatory)][pscustomobject]$Result)
    if ($Result.Stderr.Trim()) {
        Write-Output ''
        Write-Output '--- stderr (truncated to 4KB) ---'
        if ($Result.Stderr.Length -gt 4096) {
            Write-Output ($Result.Stderr.Substring(0, 4096) + '... [truncated; see stderr.log]')
        } else {
            Write-Output $Result.Stderr
        }
    }
}
