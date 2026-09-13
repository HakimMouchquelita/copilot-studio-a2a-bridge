# =====================================================================
#  AgentQA demo: conversation through the A2A bridge, then a
#  deterministic backend assertion against Dataverse.
#
#  An LLM judge scores the conversation. This scores the database.
#  "The agent was polite" is debatable. "The record exists" is not.
#
#  Usage:
#    .\scripts\demo-assertion.ps1
#    .\scripts\demo-assertion.ps1 -OrderNumber "ABC123" -BridgeUri http://localhost:3000
#
#  Requires DV_TENANT_ID / DV_CLIENT_ID / DV_CLIENT_SECRET in the session.
# =====================================================================

param(
    [string] $OrderNumber,
    [string] $BridgeUri,
    [string] $CustomerName = "Hakim Mouchquelita",
    [string] $Reason       = "the item arrived damaged",
    [string] $EntitySet    = "aqa_refundrequests",
    [string] $FilterColumn = "aqa_ordernumber"
)

$ErrorActionPreference = "Stop"

# A fresh order number per run, so a stale record can never make the
# assertion pass by accident.
if (-not $OrderNumber) {
    $OrderNumber = "DEMO" + (Get-Date -Format "HHmmss")
}

if (-not $BridgeUri) {
    $envFile = Join-Path $PSScriptRoot "..\.env"
    if (Test-Path $envFile) {
        $line = Select-String -Path $envFile -Pattern '^\s*PUBLIC_URL\s*=\s*(.+)$' |
                Select-Object -First 1
        if ($line) { $BridgeUri = $line.Matches[0].Groups[1].Value.Trim() }
    }
}
if (-not $BridgeUri) { $BridgeUri = "http://localhost:3000" }
$BridgeUri = $BridgeUri.TrimEnd('/') + '/'

$text = "I would like a refund for order $OrderNumber, my name is $CustomerName, $Reason."

Write-Host ""
Write-Host "=== 1. Conversation through the A2A bridge ===" -ForegroundColor Cyan
Write-Host "Bridge : $BridgeUri" -ForegroundColor DarkGray
Write-Host ""
Write-Host ">>> user  : $text" -ForegroundColor Yellow

$body = @{
    jsonrpc = "2.0"
    id      = 1
    method  = "message/send"
    params  = @{ message = @{
        kind      = "message"
        role      = "user"
        messageId = [guid]::NewGuid().ToString()
        parts     = @(@{ kind = "text"; text = $text })
    }}
} | ConvertTo-Json -Depth 10

try {
    $r = Invoke-RestMethod -Uri $BridgeUri -Method Post -Body $body -ContentType "application/json"
}
catch {
    Write-Host "Call failed on $BridgeUri" -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Check that 'npm start' is running." -ForegroundColor Yellow
    exit 1
}

if ($r.error) {
    Write-Host "    ERROR $($r.error.code) : $($r.error.message)" -ForegroundColor Red
    exit 1
}

Write-Host "    state     : $($r.result.status.state)"
Write-Host "    contextId : $($r.result.contextId)"
Write-Host "    agent     : $($r.result.status.message.parts[0].text)" -ForegroundColor Green

Write-Host ""
Write-Host "=== 2. Deterministic backend assertion ===" -ForegroundColor Cyan
Write-Host "The agent claims the request was created. Now ask the database." -ForegroundColor DarkGray
Write-Host ""

& (Join-Path $PSScriptRoot "assert-dataverse.ps1") `
    -EntitySet $EntitySet `
    -Filter "$FilterColumn eq '$OrderNumber'" `
    -ExpectAtLeast 1
