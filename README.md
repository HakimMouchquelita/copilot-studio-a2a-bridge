# Copilot Studio A2A Bridge

Expose un agent Microsoft Copilot Studio publié comme un agent **A2A 0.3.0**.

Copilot Studio sait appeler un agent A2A externe. L'inverse n'existe pas : aucun
moyen documenté d'exposer un agent Copilot Studio comme endpoint A2A appelable
de l'extérieur. Ce pont comble ce manque.

```
Client A2A  ──JSON-RPC──▶  Pont  ──Direct Line──▶  Agent Copilot Studio
                                                    └── Dataverse, flows, outils
```

Un `contextId` A2A correspond à une conversation Direct Line, ce qui préserve la
mémoire de l'agent d'un tour à l'autre.

## Prérequis

- Node.js 20 ou plus
- Un agent Copilot Studio **publié**, avec l'authentification réglée sur
  **Aucune authentification** (Paramètres → Sécurité et accès)
- L'URL de token de cet agent

## Installation

```bash
npm install
cp .env.example .env    # puis renseigner TOKEN_ENDPOINT
npm start
```

## Vérifier que le pont répond

La carte :

```bash
curl http://localhost:3000/.well-known/agent-card.json
```

Un premier tour, qui renvoie un `contextId` dans la réponse :

```bash
curl -s http://localhost:3000/ -H "Content-Type: application/json" -d '{
  "jsonrpc": "2.0", "id": 1, "method": "message/send",
  "params": { "message": {
    "kind": "message", "role": "user", "messageId": "m1",
    "parts": [{ "kind": "text", "text": "Bonjour" }]
  }}
}'
```

Un second tour dans la même conversation, en reprenant le `contextId` reçu :

```bash
curl -s http://localhost:3000/ -H "Content-Type: application/json" -d '{
  "jsonrpc": "2.0", "id": 2, "method": "message/send",
  "params": { "message": {
    "kind": "message", "role": "user", "messageId": "m2",
    "contextId": "COLLER-LE-CONTEXTID-RECU",
    "parts": [{ "kind": "text", "text": "Je veux un remboursement" }]
  }}
}'
```

Si l'agent répond en tenant compte du premier tour, le pont fonctionne.

## Exposer publiquement

```bash
devtunnel user login -d
devtunnel create copilot-bridge -a
devtunnel port create copilot-bridge -p 3000
devtunnel host copilot-bridge
```

Un tunnel **nommé** garde la même URL publique d'un lancement à l'autre, ce qui
n'est pas le cas de `devtunnel host -p 3000 --allow-anonymous`. L'URL doit être
stable, puisqu'elle est communiquée au client A2A.

Démarrer le pont **avant** le tunnel : dans l'ordre inverse, le tunnel ne trouve
rien sur le port 3000 et renvoie `502` au client.

Reporter l'URL publique dans `PUBLIC_URL`, redémarrer, puis la donner au client
A2A. Le champ `url` de la carte doit pointer vers l'endpoint de communication,
pas vers la carte elle-même.

## Vérification indépendante

Pointer un **autre** agent Copilot Studio sur ce pont, via Agents → Ajouter un
agent → Se connecter à un agent externe → Agent2Agent, en saisissant l'URL
publique. Si Copilot Studio récupère le nom et la description depuis la carte,
le serveur est conforme face à un client A2A tiers.

## Options

| Variable | Rôle |
|---|---|
| `TOKEN_ENDPOINT` | URL de token de l'agent Copilot Studio |
| `DIRECTLINE_BASE` | Endpoint Direct Line régional. Un bot européen rejette l'endpoint global |
| `PUBLIC_URL` | URL publiée dans la carte |
| `TURN_TIMEOUT_MS` | Délai maximum d'un tour |
| `RESPONSE_SHAPE` | `task` ou `message`, selon ce qu'attend le client |

## Comportements Direct Line pris en compte

- Le chemin du token endpoint a changé avec la nouvelle expérience Copilot
  Studio : `copilotstudio/agenticruntime/botsbyschema/`. L'ancien chemin
  `powervirtualagents/` renvoie `ObjectNotFound`.
- Un bot européen rejette l'endpoint Direct Line global avec `RegionNotAllowed`.
  Le `conversationId` porte le suffixe de région.
- La fin d'un tour est signalée par un `event` nommé `turn.complete`, dont le
  `replyToId` pointe vers le message déclencheur. Le pont s'en sert au lieu
  d'attendre un délai fixe.
- Direct Line renvoie en écho le message de l'utilisateur et réécrit son
  `from.id`. L'écho est filtré sur l'identifiant d'activité retourné par le
  POST, seul critère fiable.
- Les activités présentes à l'ouverture de la conversation sont consommées
  avant le premier tour, pour qu'un message de bienvenue ne se colle pas
  devant la première réponse.

## Limites connues

- Pas de streaming. `message/stream` renvoie une erreur explicite.
- État en mémoire : tout est perdu au redémarrage.
- Un jeton par conversation, valable une heure. Pas de rafraîchissement.
- Seules les parts de type texte sont traitées. Les pièces jointes et les
  suggested actions sont détectées et journalisées, pas converties.
