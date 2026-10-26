// The one place that talks to Gemini. Each call stands alone: Gemini's API keeps nothing between
// requests, and the model gets no tools, so a request can only ever see what it carries.

import { ModelConfig } from "./prompts";

export interface Part {
  text?: string;
  inlineData?: { mimeType: string; data: string };
}

export class GeminiError extends Error {
  constructor(
    message: string,
    /** "busy" and "slow" are worth one more try; "blocked" and "rejected" aren't. */
    readonly kind: "busy" | "slow" | "network" | "cut" | "malformed" | "blocked" | "rejected" | "quota",
    readonly status?: number,
    /** What Gemini billed for an answer that came back but couldn't be used (cut off, broken, blocked). */
    readonly tokens: Tokens = NO_TOKENS,
  ) {
    super(message);
  }

  get retryable() {
    return ["busy", "slow", "network", "cut", "malformed"].includes(this.kind);
  }
}

export interface Tokens {
  promptTokens: number;
  outputTokens: number;
  thoughtTokens: number;
}

export const NO_TOKENS: Tokens = { promptTokens: 0, outputTokens: 0, thoughtTokens: 0 };

export interface Answer extends Tokens {
  json: string;
}

const endpoint = (model: string) => `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`;

/** One request; the answer's JSON text, checked to parse. */
export async function generate(parts: Part[], schema: object, config: ModelConfig, apiKey: string): Promise<Answer> {
  const body = {
    contents: [{ parts }],
    generationConfig: {
      // No temperature override: very low values can make some Gemini models loop
      maxOutputTokens: config.maxOutputTokens,
      responseMimeType: "application/json",
      responseSchema: schema,
      thinkingConfig: { thinkingLevel: config.thinkingLevel },
    },
  };
  let response: Response;
  try {
    response = await fetch(endpoint(config.model), {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-goog-api-key": apiKey },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(config.timeoutMs),
    });
  } catch (e) {
    const timedOut = e instanceof Error && (e.name === "TimeoutError" || e.name === "AbortError");
    throw timedOut ? new GeminiError("Gemini timed out", "slow") : new GeminiError("Couldn't reach Gemini", "network");
  }
  if (!response.ok) {
    // The error body can echo the request, so only its status goes any further
    await response.body?.cancel();
    const s = response.status;
    if (s === 429) throw new GeminiError("Gemini quota", "quota", s);
    if (s >= 500) throw new GeminiError("Gemini busy", "busy", s);
    throw new GeminiError("Gemini rejected the request", "rejected", s);
  }
  const root = (await response.json()) as {
    candidates?: { finishReason?: string; content?: { parts?: { text?: string; thought?: boolean }[] } }[];
    usageMetadata?: { promptTokenCount?: number; candidatesTokenCount?: number; thoughtsTokenCount?: number };
  };
  const candidate = root.candidates?.[0];
  const u = root.usageMetadata ?? {};
  // Billed whether or not the answer can be used
  const tokens: Tokens = {
    promptTokens: u.promptTokenCount ?? 0,
    outputTokens: u.candidatesTokenCount ?? 0,
    thoughtTokens: u.thoughtsTokenCount ?? 0,
  };
  const textParts = candidate?.content?.parts?.filter((p) => typeof p.text === "string" && !p.thought);
  if (!textParts?.length) throw new GeminiError("Gemini returned nothing", "blocked", undefined, tokens);
  if (candidate?.finishReason === "MAX_TOKENS") throw new GeminiError("Gemini's answer was cut off", "cut", undefined, tokens);
  const json = textParts.map((p) => p.text).join("").trim()
    .replace(/^```(json)?/, "").replace(/```$/, "").trim();
  try {
    JSON.parse(json);
  } catch {
    throw new GeminiError("Gemini returned malformed JSON", "malformed", undefined, tokens);
  }
  return { json, ...tokens };
}
