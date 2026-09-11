# =====================================================================
#  Test multi-tours Direct Line - agent Copilot Studio
#  Objectif : 3 tours dans UNE SEULE conversation, chaque tour detecte
#             par l'evenement turn.complete, sans attente arbitraire.
#
#  Hakim Mouchquelita - etape 1 du pont A2A Copilot Studio
# =====================================================================

# ---------------------------------------------------------------------
#  1. CONFIGURATION  -  la seule partie que tu dois modifier
# ---------------------------------------------------------------------

# Colle ici l'URL de token que tu as deja validee le 6 septembre.
$tokenEndpoint = "https://fd9bb0f5385eeb32a5af8fb1e67e39.4b.environment.api.powerplatform.com/copilotstudio/agenticruntime/botsbyschema/cr717_testdirectline_dU4zjA/directline/token?api-version=2022-03-01-preview"

# Endpoint Direct Line regional. Europe pour un bot cree dans un
# environnement europeen. L'endpoint global renvoie RegionNotAllowed.
$directLineBase = "https://europe.directline.botframework.com/v3/directline"

# Les messages envoyes, dans l'ordre. Modifie-les librement.
$messages = @(
    "Bonjour",
    "Je veux un remboursement",
    "Ma commande est la 12345ABCDE"
)

# Delai maximum d'attente d'un tour, en secondes.
$timeoutSeconds = 60

# ---------------------------------------------------------------------
#  2. PREPARATION  -  ne pas modifier
# ---------------------------------------------------------------------

$ErrorActionPreference = "Stop"

# Utile sur Windows PowerShell 5.1, sans effet ailleurs.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch { }

$userId    = "test-runner"
$watermark = $null
$journal   = @()

function Write-Section($titre) {
    Write-Host ""
    Write-Host "=== $titre ===" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------
#  3. OBTENIR LE JETON
# ---------------------------------------------------------------------

Write-Section "1/4  Jeton"

try {
    $tokenResponse = Invoke-RestMethod -Uri $tokenEndpoint -Method Get
} catch {
    Write-Host "ECHEC de la demande de jeton." -ForegroundColor Red
    Write-Host "Verifie que l'agent est PUBLIE et que le chemin du token endpoint"
    Write-Host "utilise bien copilotstudio/agenticruntime/ et non powervirtualagents/."
    Write-Host $_.Exception.Message
    return
}

$token = $tokenResponse.token
if (-not $token) {
    Write-Host "Reponse recue mais aucun jeton dedans." -ForegroundColor Red
    $tokenResponse | ConvertTo-Json -Depth 5
    return
}

Write-Host "Jeton obtenu.   Debut : $($token.Substring(0,25))..."
if ($tokenResponse.expires_in) {
    Write-Host "Duree de vie du jeton : $($tokenResponse.expires_in) secondes"
}

$headers = @{ Authorization = "Bearer $token" }

# ---------------------------------------------------------------------
#  4. OUVRIR UNE CONVERSATION
# ---------------------------------------------------------------------

Write-Section "2/4  Conversation"

try {
    $conv = Invoke-RestMethod -Uri "$directLineBase/conversations" -Method Post -Headers $headers
} catch {
    Write-Host "ECHEC de l'ouverture de conversation." -ForegroundColor Red
    Write-Host "Si le message contient RegionNotAllowed, change `$directLineBase."
    Write-Host $_.Exception.Message
    return
}

$convId = $conv.conversationId
Write-Host "Conversation ouverte : $convId"

if ($convId -match "-(\w+)$") {
    Write-Host "Suffixe de region detecte : -$($Matches[1])"
}

# ---------------------------------------------------------------------
#  5. LA FONCTION QUI JOUE UN TOUR
# ---------------------------------------------------------------------
#  Elle envoie un message, puis interroge Direct Line en boucle courte
#  jusqu'a voir l'evenement turn.complete. Le watermark garantit qu'on
#  ne relit jamais deux fois les memes activites.
# ---------------------------------------------------------------------

function Send-Turn {
    param(
        [Parameter(Mandatory = $true)][string] $Text,
        [Parameter(Mandatory = $true)][int]    $Numero
    )

    Write-Host ""
    Write-Host ">>> Tour $Numero  -  moi : $Text" -ForegroundColor Yellow

    $chrono = [System.Diagnostics.Stopwatch]::StartNew()

    $body = @{
        type = "message"
        from = @{ id = $userId }
        text = $Text
    } | ConvertTo-Json

    $sent = Invoke-RestMethod -Uri "$directLineBase/conversations/$convId/activities" `
        -Method Post -Headers $headers -Body $body -ContentType "application/json"

    $triggerId = $sent.id
    Write-Host "    id du message envoye : $triggerId" -ForegroundColor DarkGray

    $reponses       = @()
    $nbActivites    = 0
    $typesVus       = @()
    $replyToIdVu    = $null
    $deadline       = (Get-Date).AddSeconds($timeoutSeconds)

    while ((Get-Date) -lt $deadline) {

        $url = "$directLineBase/conversations/$convId/activities"
        if ($script:watermark) { $url += "?watermark=$($script:watermark)" }

        $res = Invoke-RestMethod -Uri $url -Method Get -Headers $headers
        if ($res.watermark) { $script:watermark = $res.watermark }

        foreach ($a in $res.activities) {

            # On ignore ce qu'on a envoye soi-meme.
            if ($a.from.id -eq $userId) { continue }

            $nbActivites++
            $typesVus += $a.type

            if ($a.type -eq "message") {
                $reponses += $a.text
                Write-Host "    [message] $($a.text)"
                if ($a.attachments -and $a.attachments.Count -gt 0) {
                    Write-Host "    [attachments] $($a.attachments.Count) piece(s) jointe(s)" -ForegroundColor Magenta
                }
                if ($a.suggestedActions) {
                    Write-Host "    [suggestedActions] presentes" -ForegroundColor Magenta
                }
            }
            elseif ($a.type -eq "typing") {
                Write-Host "    [typing]" -ForegroundColor DarkGray
            }
            elseif ($a.type -eq "event") {
                Write-Host "    [event] name=$($a.name)  replyToId=$($a.replyToId)" -ForegroundColor DarkGray

                if ($a.name -eq "turn.complete") {
                    $replyToIdVu = $a.replyToId
                    $chrono.Stop()

                    $script:journal += [pscustomobject]@{
                        Tour               = $Numero
                        Secondes           = [math]::Round($chrono.Elapsed.TotalSeconds, 1)
                        Activites          = $nbActivites
                        Messages           = $reponses.Count
                        Types              = ($typesVus | Select-Object -Unique) -join ","
                        ReplyToIdCorrespond = ($replyToIdVu -eq $triggerId)
                    }

                    Write-Host "    turn.complete recu en $([math]::Round($chrono.Elapsed.TotalSeconds,1))s" -ForegroundColor Green
                    return ($reponses -join "`n")
                }
            }
            else {
                Write-Host "    [$($a.type)]" -ForegroundColor DarkGray
            }
        }

        Start-Sleep -Milliseconds 500
    }

    $chrono.Stop()
    Write-Host "    AUCUN turn.complete recu en $timeoutSeconds s." -ForegroundColor Red

    $script:journal += [pscustomobject]@{
        Tour                = $Numero
        Secondes            = [math]::Round($chrono.Elapsed.TotalSeconds, 1)
        Activites           = $nbActivites
        Messages            = $reponses.Count
        Types               = ($typesVus | Select-Object -Unique) -join ","
        ReplyToIdCorrespond = "timeout"
    }

    return ($reponses -join "`n")
}

# ---------------------------------------------------------------------
#  6. JOUER LES TOURS
# ---------------------------------------------------------------------

Write-Section "3/4  Conversation multi-tours"

$numero = 0
foreach ($m in $messages) {
    $numero++
    Send-Turn -Text $m -Numero $numero | Out-Null
}

# ---------------------------------------------------------------------
#  7. BILAN
# ---------------------------------------------------------------------

Write-Section "4/4  Bilan"

$journal | Format-Table -AutoSize

Write-Host ""
Write-Host "Ce qu'il faut regarder :" -ForegroundColor Cyan
Write-Host "  - ReplyToIdCorrespond : si VRAI partout, on peut filtrer sur replyToId."
Write-Host "    Si FAUX, il faudra accepter tout turn.complete arrive apres l'envoi."
Write-Host "  - Activites et Types : combien d'activites compose un tour, et lesquelles."
Write-Host "  - Secondes : le temps reel d'un tour, utile pour calibrer les timeouts."
Write-Host "  - L'agent se souvient-il du contexte entre les tours ? Relis les reponses."
Write-Host ""
