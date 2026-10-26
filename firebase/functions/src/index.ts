// SpendWise's AI, behind the backend. The phone calls `ai` (a callable function) instead of Gemini:
// the key stays here (Secret Manager), the prompts and models are chosen here, and each account's
// allowance is counted here.
//
// Privacy: Gemini gets only the request (prompt + the person's text, voice note or photo and the
// names or figures it needs). The account is used to count the allowance and is never sent to
// Gemini. Logs keep sizes, counts and timings, never what was said, shown or answered.
//
// Firestore (admin only, the rules give phones no access except reading their own plan):
//   usage/{uid}           {quickAdd: {period, count, attempts, held}, ..., tz: {offset, at}}  this period's use per feature, and the time zone it counts in
//   usage_global/{day}    {calls}                                     every account's tries that UTC day
//   entitlements/{uid}    {tier: "premium"|"max", until?}             who is Premium (set by billing later); max = owner/testing
//   config/ai             {paused?: [feature] | true, dailyCap?: n}   kill switch and global cap, editable in the console
//   usage_history/{uid}   each account's use by the day, for pricing (history.ts)

import { onCall, HttpsError, CallableRequest, FunctionsErrorCode } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import * as logger from "firebase-functions/logger";
import * as v1 from "firebase-functions/v1";
import { initializeApp } from "firebase-admin/app";
import { getFirestore, FieldValue, Timestamp } from "firebase-admin/firestore";
import { randomUUID } from "node:crypto";
import { Feature, MODELS, SCHEMAS, analysisReportPrompt, analysisRequestPrompt, basePrompts, instructionsPart, quickAddPrompt, receiptPrompt } from "./prompts";
import { AiRequest, BadRequest, charges, readRequest } from "./request";
import { Lang, PinnedTz, REFUSALS_RECORDED, RULES, Tier, Usage, Verdict, allowance, check, hold, langOf, message, periodFor, periodKey, refuse, release, text, tzFor } from "./limits";
import { Answer, GeminiError, NO_TOKENS, Part, Tokens, generate } from "./gemini";
import { KEEP_DAYS, Outcome, dayUpdate, utcDay } from "./history";

initializeApp();
const db = getFirestore();

const GEMINI_API_KEY = defineSecret("GEMINI_API_KEY");
const REGION = "europe-west1";
const EMULATOR = process.env.FUNCTIONS_EMULATOR === "true";

/** Every account's tries per UTC day before the AI pauses for everyone (config/ai.dailyCap overrides). */
const DEFAULT_DAILY_CAP = 3000;

interface Settings {
  paused: true | Feature[];
  dailyCap: number;
}

let settings: { value: Settings; at: number } | null = null;

/** config/ai, read at most once a minute per instance. */
async function aiSettings(): Promise<Settings> {
  if (settings && Date.now() - settings.at < 60_000) return settings.value;
  const d = (await db.doc("config/ai").get()).data() ?? {};
  const value: Settings = {
    paused: d.paused === true ? true : Array.isArray(d.paused) ? (d.paused as Feature[]) : [],
    dailyCap: typeof d.dailyCap === "number" ? d.dailyCap : DEFAULT_DAILY_CAP,
  };
  settings = { value, at: Date.now() };
  return value;
}

async function tierOf(request: CallableRequest, debugTier: string | null): Promise<Tier> {
  // The debug builds' plan switch, so both plans can be tried against the local emulators
  if (EMULATOR && (debugTier === "free" || debugTier === "premium")) return debugTier;
  if (request.auth!.token.firebase?.sign_in_provider === "anonymous") return "free";
  const d = (await db.doc(`entitlements/${request.auth!.uid}`).get()).data();
  const until = d?.until instanceof Timestamp ? d.until.toMillis() : Infinity;
  if (until <= Date.now()) return "free";
  return d?.tier === "premium" || d?.tier === "max" ? d.tier : "free";
}

function parts(r: AiRequest): Part[] {
  const audio = r.audio ? [{ inlineData: { mimeType: "audio/aac", data: r.audio } }] : [];
  // The person's own instructions come right after the prompt
  const own = r.instructions ? [{ text: instructionsPart(r.instructions) }] : [];
  switch (r.feature) {
    case "quickAdd":
      return [{ text: quickAddPrompt(r.text, r.context!, !!r.audio, r.previous) }, ...own, ...audio];
    case "receipt":
      return [
        { text: receiptPrompt(r.context!, { photos: r.images.length, note: r.text, hasAudio: !!r.audio, previous: r.previous }) },
        ...own,
        ...r.images.map((data) => ({ inlineData: { mimeType: "image/jpeg", data } })),
        ...audio,
      ];
    case "analysisRequest":
      return [{ text: analysisRequestPrompt(r.text, r.context!, !!r.audio) }, ...audio];
    case "analysisReport":
      return [{ text: analysisReportPrompt(r.report!) }, ...own];
  }
}

/** Sizes only: how big the request was, never what was in it. */
function sizes(r: AiRequest) {
  return {
    textChars: r.text?.length ?? 0,
    audioKb: Math.round(((r.audio?.length ?? 0) * 3) / 4 / 1024),
    imageKb: Math.round((r.images.reduce((n, x) => n + x.length, 0) * 3) / 4 / 1024),
    photos: r.images.length,
    followUp: r.previous !== null,
    dataChars: r.report?.data.length ?? 0,
    instructionChars: r.instructions?.length ?? 0,
    names: r.context ? r.context.categories.length + r.context.stores.length + r.context.knownItems.length : 0,
  };
}

/** An error whose message was written for people (in their language): the app shows it as it is. */
function shown(code: FunctionsErrorCode, message: string, details: Record<string, unknown> = {}): HttpsError {
  return new HttpsError(code, message, { ...details, shown: true });
}

function failure(e: GeminiError, lang: Lang): HttpsError {
  switch (e.kind) {
    case "busy":
    case "quota":
      return shown("unavailable", text("busy", lang));
    case "slow":
      return shown("deadline-exceeded", text("slow", lang));
    case "network":
      return shown("unavailable", text("network", lang));
    case "cut":
    case "malformed":
      return shown("internal", text("broken", lang));
    case "blocked":
      return shown("aborted", text("blocked", lang));
    case "rejected":
      return shown("internal", text("rejected", lang));
  }
}

/**
 * Adds one request to the account's day record. Never fails the request: the person's answer
 * matters more than the statistics.
 */
async function record(uid: string, feature: Feature, tier: Tier, outcome: Outcome): Promise<void> {
  const now = Date.now();
  const day = utcDay(now);
  const account = db.doc(`usage_history/${uid}`);
  try {
    const batch = db.batch();
    batch.set(account.collection("days").doc(day), dayUpdate(feature, outcome, tier, now), { merge: true });
    // The account's own line expires with its last day (same TTL policy, on usage_history)
    batch.set(account, { tier, lastDay: day, expireAt: Timestamp.fromMillis(now + KEEP_DAYS * 86_400_000) }, { merge: true });
    await batch.commit();
  } catch (e) {
    logger.warn("usage history not recorded", { feature, err: String(e) });
  }
}

export const ai = onCall(
  {
    region: REGION,
    secrets: [GEMINI_API_KEY],
    // Only the real app (Play Integrity) or a registered debug build may call. The local
    // emulator can't verify App Check tokens, so it relies on sign-in alone.
    enforceAppCheck: !EMULATOR,
    timeoutSeconds: 300,
    memory: "512MiB",
    maxInstances: 10,
    concurrency: 20,
  },
  async (request) => {
    // The app's language, for every message below
    const lang = langOf((request.data as Record<string, unknown> | null)?.lang);
    if (!request.auth) throw shown("unauthenticated", text("signIn", lang));
    let r: AiRequest;
    try {
      r = readRequest(request.data);
    } catch (e) {
      if (e instanceof BadRequest) throw new HttpsError("invalid-argument", e.message);
      throw e;
    }
    const f = r.feature;

    const config = await aiSettings();
    if (config.paused === true || config.paused.includes(f)) {
      throw shown("failed-precondition", text("featurePaused", lang), { reason: "paused" });
    }
    const tier = await tierOf(request, r.debugTier);
    // Correcting a receipt still needs receipts in the plan, though it counts as a quick add
    if (f === "receipt" && r.previous !== null && RULES[tier].receipt.limit === null) {
      throw shown("permission-denied", message("receipt", { ok: false, reason: "locked" }, lang), { reason: "locked" });
    }
    const uses = charges(r);
    const usageDoc = db.doc(`usage/${request.auth.uid}`);
    const global = db.doc(`usage_global/${periodKey("day", Date.now(), 0)}`);
    const id = randomUUID();

    // Everyone's tries today. Read outside the transaction so one busy counter doesn't make every
    // account's requests queue on it; at worst the requests in flight at that moment go over the cap.
    const calls = ((await global.get()).data()?.calls as number | undefined) ?? 0;
    if (calls >= config.dailyCap) {
      logger.error("ai daily cap reached", { cap: config.dailyCap });
      throw shown("failed-precondition", text("dayPaused", lang), { reason: "paused" });
    }

    // Hold what the request uses before asking the AI, in a transaction, so requests sent at the
    // same moment can't share the last one
    let held: { refusal: { feature: Feature; verdict: Exclude<Verdict, { ok: true }> } | null; periods: Partial<Record<Feature, string>>; refused: number };
    try {
      held = await db.runTransaction(async (t) => {
        const doc = (await t.get(usageDoc)).data();
        const tz = tzFor(doc?.tz as PinnedTz | undefined, r.tzOffsetMin, Date.now());
        const writes: Record<string, unknown> = {};
        const periods: Partial<Record<Feature, string>> = {};
        let refusal: { feature: Feature; verdict: Exclude<Verdict, { ok: true }> } | null = null;
        for (const [feature, n] of uses) {
          const usage = doc?.[feature] as Usage | undefined;
          const rule = RULES[tier][feature];
          const period = periodFor(rule.per, Date.now(), tz.offset, usage);
          const v = check(rule, usage, period, Date.now(), n);
          periods[feature] = period;
          if (!v.ok) {
            refusal = { feature, verdict: v };
            break;
          }
        }
        if (refusal) {
          if (refusal.verdict.reason !== "locked") {
            const feature = refusal.feature;
            writes[feature] = refuse(doc?.[feature] as Usage | undefined, periods[feature]!);
          }
        } else {
          for (const [feature, n] of uses) writes[feature] = hold(doc?.[feature] as Usage | undefined, periods[feature]!, id, Date.now(), n);
        }
        if (tz.pin) writes.tz = tz.pin;
        if (Object.keys(writes).length) t.set(usageDoc, writes, { mergeFields: Object.keys(writes) });
        const refused = refusal ? ((writes[refusal.feature] as Usage | undefined)?.refused ?? 0) : 0;
        return { refusal, periods, refused };
      });
    } catch (e) {
      // Many requests from one account at the same moment: the rest wait their turn
      logger.warn("ai hold failed", { feature: f, err: String(e) });
      throw shown("unavailable", text("tooMany", lang));
    }
    if (held.refusal) {
      const { feature, verdict } = held.refusal;
      logger.info("ai refused", { feature, tier, reason: verdict.reason });
      // Running out is what pricing most needs to know
      // A feature outside the plan isn't use; repeated refusals past the first few are only counted
      if (verdict.reason !== "locked" && held.refused <= REFUSALS_RECORDED) await record(request.auth.uid, feature, tier, { kind: "refused" });
      const code = verdict.reason === "locked" ? "permission-denied" : "resource-exhausted";
      throw shown(code, message(feature, verdict, lang), { reason: verdict.reason, feature });
    }
    const periods = held.periods;
    await global.set({ calls: FieldValue.increment(1) }, { merge: true });
    /** Gives the holds back, counting them if the AI answered; returns each feature's allowance after. */
    const settle = (answered: boolean) => db.runTransaction(async (t) => {
      const doc = (await t.get(usageDoc)).data();
      const writes: Record<string, Usage> = {};
      for (const [feature, n] of uses) writes[feature] = release(doc?.[feature] as Usage | undefined, periods[feature]!, id, answered, Date.now(), n);
      t.set(usageDoc, writes, { mergeFields: Object.keys(writes) });
      return Object.fromEntries(uses.map(([feature]) => [feature, allowance(RULES[tier][feature], writes[feature], periods[feature]!)]));
    });

    const started = Date.now();
    let tries = 0;
    // Everything Gemini billed for this request, over its tries
    const spent = { ...NO_TOKENS };
    const add = (t: Tokens) => {
      spent.promptTokens += t.promptTokens;
      spent.outputTokens += t.outputTokens;
      spent.thoughtTokens += t.thoughtTokens;
    };
    for (;;) {
      tries++;
      let answer: Answer;
      try {
        answer = await generate(parts(r), SCHEMAS[f], MODELS[f], GEMINI_API_KEY.value());
      } catch (e) {
        if (e instanceof GeminiError) add(e.tokens);
        const last = !(e instanceof GeminiError) || !e.retryable || tries >= 2;
        if (last) {
          await settle(false).catch((err) => logger.error("ai hold not given back", { feature: f, err: String(err) }));
          await record(request.auth.uid, f, tier, { kind: "failed", ...spent });
        }
        if (!(e instanceof GeminiError)) throw e;
        logger.warn("ai failed", { feature: f, tier, tries, kind: e.kind, status: e.status ?? null, ms: Date.now() - started, ...sizes(r), ...e.tokens });
        if (last) throw failure(e, lang);
        // An overloaded model often recovers within a second or two
        await new Promise((resolve) => setTimeout(resolve, 1500));
        continue;
      }
      add(answer);
      // The answer is paid for: the person gets it even if counting it fails (logged, and the
      // hold lapses on its own)
      const after = await settle(true).catch((err) => {
        logger.error("ai answer not counted", { feature: f, err: String(err) });
        return undefined;
      });
      const counted = after ?? {};
      await record(request.auth.uid, f, tier, { kind: "answered", ...spent });
      logger.info("ai answered", {
        feature: f, tier, tries, ms: Date.now() - started, ...sizes(r),
        promptTokens: answer.promptTokens, outputTokens: answer.outputTokens, thoughtTokens: answer.thoughtTokens,
      });
      // `allowance`: the request's own feature, as app versions before 25 Oct read it; `allowances`: every feature it used
      return { json: answer.json, allowance: counted[f] ?? null, allowances: counted };
    }
  },
);

/**
 * How much of each AI feature this account has used this period, for the app to show before
 * asking. Reads only the counts; nothing goes to the AI.
 */
export const aiAllowance = onCall(
  { region: REGION, enforceAppCheck: !EMULATOR, maxInstances: 10, concurrency: 40 },
  async (request) => {
    const data = (request.data ?? {}) as Record<string, unknown>;
    if (!request.auth) throw shown("unauthenticated", text("signIn", langOf(data.lang)));
    const tz = data.tzOffsetMin;
    if (typeof tz !== "number" || !Number.isInteger(tz) || Math.abs(tz) > 14 * 60) throw new HttpsError("invalid-argument", "bad tzOffsetMin");
    const debugTier = typeof data.debugTier === "string" ? data.debugTier.slice(0, 20) : null;
    const tier = await tierOf(request, debugTier);
    const usage = (await db.doc(`usage/${request.auth.uid}`).get()).data() ?? {};
    const features = Object.fromEntries(
      (Object.keys(RULES[tier]) as Feature[]).map((f) => {
        const rule = RULES[tier][f];
        const u = usage[f] as Usage | undefined;
        return [f, allowance(rule, u, periodFor(rule.per, Date.now(), tzFor(usage.tz as PinnedTz | undefined, tz, Date.now()).offset, u))];
      }),
    );
    return { tier, features };
  },
);

/**
 * The prompts as the person sees them in Settings (with placeholders for their own names). Nothing
 * of theirs is read or sent anywhere, so no sign-in is needed.
 */
export const aiPrompts = onCall(
  { region: REGION, enforceAppCheck: !EMULATOR, maxInstances: 5, concurrency: 40 },
  async () => ({ prompts: basePrompts() }),
);

/**
 * When an account is deleted (in the app, the console or on request), everything that still names it
 * goes too: its allowance, usage history and plan records, its invites, and its place in a family. A family it
 * started is closed and erased, as Close the family does; members keep the copy on their phones.
 * The app erases users/{uid} itself before deleting the sign-in.
 */
export const forgetAccount = v1.region(REGION).auth.user().onDelete(async (user) => {
  const uid = user.uid;
  const [spaces, made, used] = await Promise.all([
    db.collection("spaces").where(`members.${uid}.role`, "in", ["owner", "member"]).get(),
    db.collection("invites").where("by", "==", uid).get(),
    db.collection("invites").where("usedBy", "==", uid).get(),
  ]);
  await Promise.all([
    db.doc(`usage/${uid}`).delete(),
    db.doc(`entitlements/${uid}`).delete(),
    db.recursiveDelete(db.doc(`users/${uid}`)),
    db.recursiveDelete(db.doc(`usage_history/${uid}`)),
    ...[...made.docs, ...used.docs].map((d) => d.ref.delete()),
    ...spaces.docs.map((s) =>
      s.get("owner") === uid ? db.recursiveDelete(s.ref) : s.ref.update({ [`members.${uid}`]: FieldValue.delete() })),
  ]);
  logger.info("account forgotten", { families: spaces.size, invites: made.size + used.size });
});
