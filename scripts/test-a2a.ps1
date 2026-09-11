# =====================================================================
#  Test client A2A du pont Copilot Studio
#  Joue 3 tours via JSON-RPC message/send en reutilisant le contextId.
#  Le pont doit tourner dans une autre fenetre (npm start).
# =====================================================================

$uri = "http://localhost:3000/"

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

    Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType "application/json"
}

function Show-Turn($reponse, $texteEnvoye) {
    Write-Host ""
    Write-Host ">>> moi : $texteEnvoye" -ForegroundColor Yellow

    if ($reponse.error) {
        Write-Host "    ERREUR $($reponse.error.code) : $($reponse.error.message)" -ForegroundColor Red
        return
    }

    $r = $reponse.result
    Write-Host "    kind      : $($r.kind)"
    Write-Host "    state     : $($r.status.state)"
    Write-Host "    contextId : $($r.contextId)"
    Write-Host "    taskId    : $($r.id)"
    Write-Host "    reponse   : $($r.status.message.parts[0].text)" -ForegroundColor Green
}

# --- Tour 1 : pas de contextId, le pont en cree un -------------------
$t1 = Send-A2A -Text "Bonjour"
Show-Turn $t1 "Bonjour"

$ctx = $t1.result.contextId
if (-not $ctx) {
    Write-Host ""
    Write-Host "Aucun contextId retourne, on ne peut pas enchainer." -ForegroundColor Red
    return
}

# --- Tours 2 et 3 : meme contextId, donc meme conversation -----------
$t2 = Send-A2A -Text "Je veux un remboursement" -ContextId $ctx
Show-Turn $t2 "Je veux un remboursement"

$t3 = Send-A2A -Text "Ma commande est la 12345ABCDE" -ContextId $ctx
Show-Turn $t3 "Ma commande est la 12345ABCDE"

Write-Host ""
Write-Host "Ce qu'il faut verifier :" -ForegroundColor Cyan
Write-Host "  - les trois tours partagent le meme contextId"
Write-Host "  - les taskId sont differents a chaque tour"
Write-Host "  - la reponse du tour 3 tient compte des tours 1 et 2"
Write-Host "  - aucune reponse ne contient l'echo de ton propre message"
Write-Host ""
