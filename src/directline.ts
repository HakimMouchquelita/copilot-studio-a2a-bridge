/**
 * Client Direct Line pour un agent Microsoft Copilot Studio publie.
 *
 * Comportements verifies le 11 septembre 2026 contre un agent reel :
 *  - un tour = 3 activites : l'echo du message utilisateur, la reponse de
 *    l'agent, puis un event nomme "turn.complete" ;
 *  - le replyToId du turn.complete est egal a l'id de l'activite envoyee ;
 *  - Direct Line reecrit le from.id de l'emetteur, donc on NE PEUT PAS
 *    filtrer l'echo sur from.id. On le filtre sur l'id d'activite ;
 *  - le jeton vit 3600 s, largement suffisant pour une conversation de test.
 */

export interface DirectLineOptions {
  tokenEndpoint: string;
  baseUrl: string;
  userId?: string;
  turnTimeoutMs?: number;
  pollIntervalMs?: number;
}

export interface TurnResult {
  /** Les messages de l'agent, concatenes. C'est ce qu'on remonte en A2A. */
  text: string;
  /** Chaque message de l'agent separement, si on veut les inspecter. */
  messages: string[];
  /** Nombre d'activites de l'agent vues pendant le tour, echo exclu. */
  activityCount: number;
  /** Types d'activites rencontres, pour le diagnostic. */
  activityTypes: string[];
  elapsedMs: number;
  /** Vrai si aucun turn.complete n'est arrive dans le delai imparti. */
  timedOut: boolean;
  hasAttachments: boolean;
  hasSuggestedActions: boolean;
}

interface DirectLineActivity {
  id?: string;
  type?: string;
  name?: string;
  text?: string;
  replyToId?: string;
  from?: { id?: string; name?: string; role?: string };
  attachments?: unknown[];
  suggestedActions?: unknown;
}

interface ActivitiesResponse {
  activities?: DirectLineActivity[];
  watermark?: string;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export class CopilotStudioConversation {
  private watermark: string | undefined;
  /** Ids des activites que nous avons envoyees, pour ignorer leur echo. */
  private readonly sentIds = new Set<string>();

  constructor(
    readonly conversationId: string,
    private readonly token: string,
    private readonly opts: Required<DirectLineOptions>
  ) {}

  private get headers(): Record<string, string> {
    return { Authorization: `Bearer ${this.token}` };
  }

  /**
   * Consomme les activites deja presentes sans les traiter.
   * Sert a jeter un eventuel message de bienvenue emis a l'ouverture,
   * qui sinon se collerait devant la reponse du premier tour.
   */
  async drain(): Promise<void> {
    const res = await this.readActivities();
    if (res.watermark) this.watermark = res.watermark;
  }

  private async readActivities(): Promise<ActivitiesResponse> {
    const url = new URL(`${this.opts.baseUrl}/conversations/${this.conversationId}/activities`);
    if (this.watermark) url.searchParams.set("watermark", this.watermark);

    const res = await fetch(url, { headers: this.headers });
    if (!res.ok) {
      throw new Error(`Lecture des activites : HTTP ${res.status} ${await res.text()}`);
    }
    return (await res.json()) as ActivitiesResponse;
  }

  /**
   * Envoie un message et attend la fin du tour.
   * Ne rend la main qu'apres le turn.complete correspondant, ou apres
   * expiration du delai.
   */
  async sendTurn(text: string): Promise<TurnResult> {
    const startedAt = Date.now();

    const postRes = await fetch(
      `${this.opts.baseUrl}/conversations/${this.conversationId}/activities`,
      {
        method: "POST",
        headers: { ...this.headers, "Content-Type": "application/json" },
        body: JSON.stringify({
          type: "message",
          from: { id: this.opts.userId },
          text
        })
      }
    );

    if (!postRes.ok) {
      throw new Error(`Envoi du message : HTTP ${postRes.status} ${await postRes.text()}`);
    }

    const sent = (await postRes.json()) as { id?: string };
    const triggerId = sent.id;
    if (triggerId) this.sentIds.add(triggerId);

    const messages: string[] = [];
    const activityTypes: string[] = [];
    let activityCount = 0;
    let hasAttachments = false;
    let hasSuggestedActions = false;

    const deadline = startedAt + this.opts.turnTimeoutMs;

    while (Date.now() < deadline) {
      const res = await this.readActivities();
      if (res.watermark) this.watermark = res.watermark;

      for (const a of res.activities ?? []) {
        // L'echo de notre propre message porte le meme id que celui
        // renvoye par le POST. C'est le seul filtre fiable :
        // Direct Line reecrit le from.id.
        if (a.id && this.sentIds.has(a.id)) continue;

        activityCount++;
        if (a.type) activityTypes.push(a.type);

        if (a.type === "message") {
          if (a.text) messages.push(a.text);
          if (a.attachments && a.attachments.length > 0) hasAttachments = true;
          if (a.suggestedActions) hasSuggestedActions = true;
        }

        if (a.type === "event" && a.name === "turn.complete") {
          // replyToId est fiable sur Copilot Studio, mais on reste
          // tolerant : un turn.complete sans replyToId termine aussi
          // le tour plutot que de laisser le pont bloquer.
          if (!a.replyToId || !triggerId || a.replyToId === triggerId) {
            return {
              text: messages.join("\n\n"),
              messages,
              activityCount,
              activityTypes: [...new Set(activityTypes)],
              elapsedMs: Date.now() - startedAt,
              timedOut: false,
              hasAttachments,
              hasSuggestedActions
            };
          }
        }
      }

      await sleep(this.opts.pollIntervalMs);
    }

    return {
      text: messages.join("\n\n"),
      messages,
      activityCount,
      activityTypes: [...new Set(activityTypes)],
      elapsedMs: Date.now() - startedAt,
      timedOut: true,
      hasAttachments,
      hasSuggestedActions
    };
  }
}

/**
 * Demande un jeton puis ouvre une conversation Direct Line.
 * Un jeton par conversation : c'est le plus simple et le jeton vit 1 h.
 */
export async function openConversation(
  options: DirectLineOptions
): Promise<CopilotStudioConversation> {
  const opts: Required<DirectLineOptions> = {
    userId: "a2a-bridge",
    turnTimeoutMs: 45_000,
    pollIntervalMs: 400,
    ...options
  };

  const tokenRes = await fetch(opts.tokenEndpoint);
  if (!tokenRes.ok) {
    throw new Error(
      `Token endpoint : HTTP ${tokenRes.status}. ` +
        `Verifie que l'agent est publie et que le chemin utilise ` +
        `copilotstudio/agenticruntime/. Corps : ${await tokenRes.text()}`
    );
  }

  const { token } = (await tokenRes.json()) as { token?: string };
  if (!token) throw new Error("Le token endpoint a repondu sans jeton.");

  const convRes = await fetch(`${opts.baseUrl}/conversations`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` }
  });

  if (!convRes.ok) {
    throw new Error(
      `Ouverture de conversation : HTTP ${convRes.status}. ` +
        `Si la reponse contient RegionNotAllowed, corrige DIRECTLINE_BASE. ` +
        `Corps : ${await convRes.text()}`
    );
  }

  const conv = (await convRes.json()) as { conversationId?: string };
  if (!conv.conversationId) throw new Error("Aucun conversationId dans la reponse.");

  const conversation = new CopilotStudioConversation(conv.conversationId, token, opts);
  await conversation.drain();
  return conversation;
}
