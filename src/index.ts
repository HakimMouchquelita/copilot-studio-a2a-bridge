/**
 * Pont A2A pour Microsoft Copilot Studio.
 *
 * Cote client A2A : une agent card et un endpoint JSON-RPC 2.0.
 * Cote Copilot Studio : Direct Line.
 *
 * Le mapping central : un contextId A2A = une conversation Direct Line.
 * La specification A2A dit que tout ce qui partage un contextId appartient
 * a la meme session conversationnelle, et une conversation Direct Line
 * porte bien la memoire de l'agent d'un tour a l'autre (verifie).
 */

import "dotenv/config";
import express from "express";
import { randomUUID } from "node:crypto";
import { openConversation, type CopilotStudioConversation } from "./directline.js";

// ---------------------------------------------------------------------
//  Configuration
// ---------------------------------------------------------------------

const config = {
  tokenEndpoint: required("TOKEN_ENDPOINT"),
  directLineBase:
    process.env.DIRECTLINE_BASE ?? "https://europe.directline.botframework.com/v3/directline",
  port: Number(process.env.PORT ?? 3000),
  publicUrl: process.env.PUBLIC_URL ?? `http://localhost:${process.env.PORT ?? 3000}`,
  agentName: process.env.AGENT_NAME ?? "Copilot Studio Bridge",
  agentDescription:
    process.env.AGENT_DESCRIPTION ??
    "Exposes a published Microsoft Copilot Studio agent as an A2A agent.",
  turnTimeoutMs: Number(process.env.TURN_TIMEOUT_MS ?? 45_000),
  pollIntervalMs: Number(process.env.POLL_INTERVAL_MS ?? 400),
  quietPeriodMs: Number(process.env.QUIET_PERIOD_MS ?? 1_500),
  responseShape: (process.env.RESPONSE_SHAPE ?? "task") as "task" | "message",
  // Un agent sous test attend toujours le message suivant du persona.
  // "completed" ferait terminer l'execution du runner des le premier tour.
  turnState: (process.env.TURN_STATE ?? "input-required") as "input-required" | "completed"
};

function required(name: string): string {
  const value = process.env[name];
  if (!value || value.includes("REMPLACE-MOI")) {
    console.error(`\n  ${name} n'est pas renseigne. Copie .env.example en .env.\n`);
    process.exit(1);
  }
  return value;
}

// ---------------------------------------------------------------------
//  Agent card
// ---------------------------------------------------------------------

const agentCard = {
  protocolVersion: "0.3.0",
  name: config.agentName,
  description: config.agentDescription,
  url: config.publicUrl.replace(/\/$/, "") + "/",
  preferredTransport: "JSONRPC",
  version: "0.1.0",
  capabilities: {
    streaming: false,
    pushNotifications: false,
    stateTransitionHistory: false
  },
  defaultInputModes: ["text/plain"],
  defaultOutputModes: ["text/plain"],
  skills: [
    {
      id: "conversation",
      name: "Conversation",
      description:
        "Holds a multi-turn conversation with a published Copilot Studio agent and returns its replies.",
      tags: ["copilot-studio", "customer-service", "chat"],
      examples: ["I would like a refund for order 12345ABCDE"],
      inputModes: ["text/plain"],
      outputModes: ["text/plain"]
    }
  ]
};

// ---------------------------------------------------------------------
//  Etat en memoire
// ---------------------------------------------------------------------

/** contextId A2A -> conversation Direct Line et tache associee. */
const sessions = new Map<string, { conv: CopilotStudioConversation; taskId: string }>();
/** taskId -> tache, pour tasks/get et pour retrouver un contexte. */
const tasks = new Map<string, { contextId: string; task: unknown }>();
/** Verrou par contextId : un seul tour a la fois sur une conversation. */
const locks = new Map<string, Promise<unknown>>();

async function withLock<T>(key: string, fn: () => Promise<T>): Promise<T> {
  const previous = locks.get(key) ?? Promise.resolve();
  const current = previous.then(fn, fn);
  locks.set(
    key,
    current.catch(() => undefined)
  );
  return current;
}

// ---------------------------------------------------------------------
//  Traitement de message/send
// ---------------------------------------------------------------------

interface A2APart {
  kind?: string;
  type?: string;
  text?: string;
}

interface A2AMessage {
  role?: string;
  parts?: A2APart[];
  messageId?: string;
  taskId?: string;
  contextId?: string;
}

function extractText(message: A2AMessage | undefined): string {
  return (message?.parts ?? [])
    .filter((p) => (p.kind ?? p.type) === "text")
    .map((p) => p.text ?? "")
    .join("\n")
    .trim();
}

async function handleMessageSend(params: { message?: A2AMessage }) {
  const message = params?.message;
  const text = extractText(message);
  if (!text) throw new Error("Aucune part de type text dans le message recu.");

  // Resolution du contexte : contextId d'abord, taskId en repli,
  // nouveau contexte sinon. La spec interdit au client de fixer
  // lui-meme un taskId pour une nouvelle tache.
  let contextId = message?.contextId;
  if (!contextId && message?.taskId) {
    contextId = tasks.get(message.taskId)?.contextId;
  }
  if (!contextId) contextId = randomUUID();

  return withLock(contextId, async () => {
    let entry = sessions.get(contextId!);
    if (!entry) {
      const conv = await openConversation({
        tokenEndpoint: config.tokenEndpoint,
        baseUrl: config.directLineBase,
        turnTimeoutMs: config.turnTimeoutMs,
        pollIntervalMs: config.pollIntervalMs,
        quietPeriodMs: config.quietPeriodMs
      });
      // Un seul taskId pour toute la conversation : le client relance la
      // meme tache, laissee en input-required entre deux tours.
      entry = { conv, taskId: randomUUID() };
      sessions.set(contextId!, entry);
      console.log(`[${contextId}] nouvelle conversation ${conv.conversationId}`);
    }

    const turn = await entry.conv.sendTurn(text);

    console.log(
      `[${contextId}] "${text.slice(0, 50)}" -> ${turn.messages.length} message(s), ` +
        `${turn.activityCount} activite(s) [${turn.activityTypes.join(",")}], ` +
        `${turn.elapsedMs} ms, fin: ${turn.endedBy}` +
        `${turn.hasAttachments ? "  +attachments" : ""}` +
        `${turn.hasSuggestedActions ? "  +suggestedActions" : ""}`
    );

    const taskId = entry.taskId;
    const replyText = turn.text || (turn.timedOut ? "(no reply before timeout)" : "");

    const agentMessage = {
      kind: "message",
      role: "agent",
      parts: [{ kind: "text", text: replyText }],
      messageId: randomUUID(),
      taskId,
      contextId
    };

    if (config.responseShape === "message") {
      tasks.set(taskId, { contextId: contextId!, task: agentMessage });
      return agentMessage;
    }

    const task = {
      kind: "task",
      id: taskId,
      contextId,
      status: {
        state: turn.timedOut ? "failed" : config.turnState,
        message: agentMessage,
        timestamp: new Date().toISOString()
      },
      artifacts: [
        {
          artifactId: randomUUID(),
          name: "reply",
          parts: [{ kind: "text", text: replyText }]
        }
      ],
      history: []
    };

    tasks.set(taskId, { contextId: contextId!, task });
    return task;
  });
}

// ---------------------------------------------------------------------
//  Serveur HTTP
// ---------------------------------------------------------------------

const app = express();
app.use(express.json({ limit: "1mb" }));

// La spec 0.3.0 publie la carte sur agent-card.json.
// Le client A2A de Copilot Studio la cherche historiquement sur agent.json.
// On sert les deux, ca ne coute rien.
function serveCard(req: express.Request, res: express.Response) {
  console.log(
    `[card] ${req.path}  accept=${req.get("accept") ?? "-"}  ua=${req.get("user-agent") ?? "-"}`
  );
  res.json(agentCard);
}

app.get("/.well-known/agent-card.json", serveCard);
app.get("/.well-known/agent.json", serveCard);

app.get("/health", (_req, res) =>
  res.json({ ok: true, sessions: sessions.size, tasks: tasks.size })
);

app.post("/", async (req, res) => {
  const { id = null, method, params } = req.body ?? {};

  const fail = (code: number, msg: string) =>
    res.json({ jsonrpc: "2.0", id, error: { code, message: msg } });

  try {
    switch (method) {
      case "message/send":
        return res.json({ jsonrpc: "2.0", id, result: await handleMessageSend(params) });

      case "tasks/get": {
        const entry = tasks.get(params?.id);
        if (!entry) return fail(-32001, `Task not found: ${params?.id}`);
        return res.json({ jsonrpc: "2.0", id, result: entry.task });
      }

      case "tasks/cancel":
        return fail(-32002, "Task cannot be canceled: turns are synchronous.");

      case "message/stream":
        return fail(-32004, "Streaming is not supported. Use message/send.");

      default:
        return fail(-32601, `Method not found: ${method}`);
    }
  } catch (error) {
    console.error(error);
    return fail(-32603, (error as Error).message);
  }
});

app.listen(config.port, () => {
  console.log(`\n  Pont A2A Copilot Studio`);
  console.log(`  ecoute sur       http://localhost:${config.port}`);
  console.log(`  URL publiee      ${agentCard.url}`);
  console.log(`  agent card       ${agentCard.url}.well-known/agent-card.json`);
  console.log(`  Direct Line      ${config.directLineBase}`);
  console.log(`  forme de reponse ${config.responseShape}`);
  console.log(`  etat par tour    ${config.turnState}\n`);
});
