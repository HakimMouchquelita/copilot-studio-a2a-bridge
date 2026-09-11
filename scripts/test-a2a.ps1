# =====================================================================
#  A2A client test for the Copilot Studio bridge
#  Plays 3 turns over JSON-RPC message/send, reusing the same contextId.
#  The bridge must be running in another window (npm start).
#
#  Usage:
#    .\scripts\test-a2a.ps1              -> reads PUBLIC_URL from .env
#    .\scripts\test-a2a.ps1 -Uri http://localhost:3000/   -> forces the URL
# =====================================================================

param([string] $Uri)

# Single source of truth: the PUBLIC_URL from .env, the same value the bridge
# publishes in its agent card. Prevents drift between the two.
if (-not $Uri) {
    $envFile = Join-Path $PSScriptRoot "..\.env"
    if (Test-Path $envFile) {
        $line = Select-String -Path $envFile -Pattern '^\s*PUBLIC_URL\s*=\s*(.+)$' |
                Select-Object -First 1
        if ($line) { $Uri = $line.Matches[0].Groups[1].Value.Trim() }
    }
}
if (-not $Uri) { $Uri = "http://localhost:3000" }
$uri = $Uri.TrimEnd('/') + '/'

Write-Host "Target : $uri" -ForegroundColor DarkGray

function Send-A2A {
    param(
        [Parameter(Mandatory = $true)][string] $Text,
        [string] $ContextId
    )

    $message = @{
        kind      = "message"
        role      = "user"
        messageId = [guid]::NewGuid().ToString()
        parts     = @(@{ kind = "text"; text = $Text })
    }
    if ($ContextId) { $message.contextId = $ContextId }

    $body = @{
        jsonrpc = "2.0"
        id      = 1
        method  = "message/send"
        params  = @{ message = $message }
    } | ConvertTo-Json -Depth 10

    try {
        Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType "application/json"
    }
    catch {
        # A 502 almost always means the tunnel was started before the bridge.
        Write-Host "Call failed on $uri" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Check that 'npm start' is running, then restart the tunnel." -ForegroundColor Yellow
        exit 1
    }
}

function Show-Turn($response, $sentText) {
    Write-Host ""
    Write-Host ">>> user  : $sentText" -ForegroundColor Yellow

    if ($response.error) {
        Write-Host "    ERROR $($response.error.code) : $($response.error.message)" -ForegroundColor Red
        return
    }

    $r = $response.result
    Write-Host "    kind      : $($r.kind)"
    Write-Host "    state     : $($r.status.state)"
    Write-Host "    contextId : $($r.contextId)"
    Write-Host "    taskId    : $($r.id)"
    Write-Host "    agent     : $($r.status.message.parts[0].text)" -ForegroundColor Green
}

# --- Turn 1: no contextId, the bridge creates one --------------------
$m1 = "Hello"
$t1 = Send-A2A -Text $m1
Show-Turn $t1 $m1

$ctx = $t1.result.contextId
if (-not $ctx) {
    Write-Host ""
    Write-Host "No contextId returned, cannot chain the conversation." -ForegroundColor Red
    return
}

# --- Turns 2 and 3: same contextId, therefore same conversation ------
$m2 = "I would like a refund"
$t2 = Send-A2A -Text $m2 -ContextId $ctx
Show-Turn $t2 $m2

$m3 = "My order number is 12345ABCDE"
$t3 = Send-A2A -Text $m3 -ContextId $ctx
Show-Turn $t3 $m3

Write-Host ""
Write-Host "What to look at:" -ForegroundColor Cyan
Write-Host "  - all three turns share the same contextId"
Write-Host "    => one A2A context = one Direct Line conversation"
Write-Host "  - all three turns share the same taskId, state = input-required"
Write-Host "    => the runner keeps the conversation going instead of ending it"
Write-Host "  - turn 3 takes turns 1 and 2 into account (the agent remembers)"
Write-Host "  - no reply echoes back the user's own message"
Write-Host ""
