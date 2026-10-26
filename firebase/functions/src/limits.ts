// Allowances per plan (PLAN.md, Tiers). Counted per account on the server, so reinstalling the app
// or clearing its data doesn't reset them. Only answered requests count; failed tries are capped
// separately so a broken phone can't loop forever.

import { Feature } from "./prompts";

export type Tier = "free" | "premium" | "max";

export interface Rule {
  /** null: not in this plan. */
  limit: number | null;
  per: "day" | "week";
}

export const RULES: Record<Tier, Record<Feature, Rule>> = {
  free: {
    quickAdd: { limit: 10, per: "day" },
    receipt: { limit: null, per: "day" },
    analysisRequest: { limit: null, per: "day" },
    analysisReport: { limit: null, per: "week" },
  },
  premium: {
    quickAdd: { limit: 100, per: "day" },
    receipt: { limit: 20, per: "day" },
    // Understanding what report is wanted; the report itself is the weekly allowance
    analysisRequest: { limit: 20, per: "day" },
    analysisReport: { limit: 3, per: "week" },
  },
  // The owner and anyone they choose (grant_premium.py --max), for testing: Premium with high
  // daily ceilings instead of the weekly reports. Ceilings stay, so a stuck phone or a bug can't
  // spend the credits.
  max: {
    quickAdd: { limit: 1000, per: "day" },
    receipt: { limit: 200, per: "day" },
    analysisRequest: { limit: 200, per: "day" },
    analysisReport: { limit: 50, per: "day" },
  },
};

/** Tries (answered or not) allowed per period before even trying stops. */
export const attemptsCap = (limit: number) => limit * 2 + 5;

/** The local day ("2026-10-21"), or the Monday starting the local week, for a period. */
export function periodKey(per: "day" | "week", nowMs: number, tzOffsetMin: number): string {
  const local = new Date(nowMs + tzOffsetMin * 60_000);
  if (per === "week") {
    const sinceMonday = (local.getUTCDay() + 6) % 7;
    local.setUTCDate(local.getUTCDate() - sinceMonday);
  }
  return local.toISOString().slice(0, 10);
}

/**
 * The period a request counts against: the phone's local one, but never earlier than the one this
 * account already used. The phone says its own time zone, so without this, switching it back and
 * forth (any offset up to 14 h either side) would start a fresh day every time. Someone flying west
 * keeps counting on the day they had until their local day catches up.
 */
export function periodFor(per: "day" | "week", nowMs: number, tzOffsetMin: number, usage: Usage | undefined): string {
  const local = periodKey(per, nowMs, tzOffsetMin);
  return usage && usage.period > local ? usage.period : local;
}

/** The time zone an account counts its days in, and since when. */
export interface PinnedTz {
  offset: number;
  at: number;
}

/** A new time zone is accepted only this long after the last one was (travel, not switching). */
export const TZ_CHANGE_MS = 20 * 3600_000;

/**
 * The time zone to count in: the phone's, unless the account's changed less than [TZ_CHANGE_MS]
 * ago. Without this, three offsets in a row (-14 h, 0, +14 h) give yesterday's, today's and
 * tomorrow's allowance at once. [pin] is what to store when it changes.
 */
export function tzFor(pinned: PinnedTz | undefined, requested: number, nowMs: number): { offset: number; pin: PinnedTz | null } {
  if (!pinned) return { offset: requested, pin: { offset: requested, at: nowMs } };
  if (pinned.offset === requested) return { offset: requested, pin: null };
  if (nowMs - pinned.at < TZ_CHANGE_MS) return { offset: pinned.offset, pin: null };
  return { offset: requested, pin: { offset: requested, at: nowMs } };
}

/** How long a request in flight holds its place (longer than the function's 300 s timeout). */
export const HOLD_MS = 6 * 60_000;

export interface Usage {
  period: string;
  /** Answered requests. */
  count: number;
  /** Tries, answered or not. */
  attempts: number;
  /**
   * Requests in flight: when each started. Each key holds one of the allowance until the request ends;
   * a request using several (a receipt's photos) holds "id#0", "id#1"…
   */
  held?: Record<string, number>;
  /** Requests refused this period because the allowance ran out. */
  refused?: number;
}

/** Refusals per period that go into the usage history; past that they're only counted. */
export const REFUSALS_RECORDED = 20;

/** The usage once one more request was refused, and how many were this period. */
export function refuse(usage: Usage | undefined, period: string, nowMs = Date.now()): Usage {
  const c = current(usage, period, nowMs);
  return { ...c, refused: (c.refused ?? 0) + 1 };
}

export type Verdict =
  | { ok: true; remaining: number }
  | { ok: false; reason: "locked" }
  | { ok: false; reason: "used"; per: "day" | "week"; limit: number }
  /** Some are left, but fewer than the request uses (two photos, one receipt scan left). */
  | { ok: false; reason: "short"; per: "day" | "week"; left: number; need: number }
  | { ok: false; reason: "tries"; per: "day" | "week" };

/**
 * This period's usage. When a later period starts, requests still in flight keep their holds in it
 * (and are counted there when they answer), so moving the day forward can't free their places.
 */
function current(usage: Usage | undefined, period: string, nowMs: number): Usage {
  if (usage && usage.period === period) return usage;
  const carried = live(usage?.held, nowMs);
  return { period, count: 0, attempts: 0, ...(Object.keys(carried).length ? { held: carried } : {}) };
}

/** The holds still running (a crashed request's hold lapses after [HOLD_MS]). */
function live(held: Record<string, number> | undefined, nowMs: number): Record<string, number> {
  return Object.fromEntries(Object.entries(held ?? {}).filter(([, at]) => at > nowMs - HOLD_MS));
}

/**
 * Whether another request may go to the AI now, given what this period has used and what's still
 * in flight: requests sent at the same moment can't share the last one.
 */
export function check(rule: Rule, usage: Usage | undefined, period: string, nowMs = Date.now(), need = 1): Verdict {
  if (rule.limit === null) return { ok: false, reason: "locked" };
  const c = current(usage, period, nowMs);
  const taken = c.count + Object.keys(live(c.held, nowMs)).length;
  if (taken >= rule.limit) return { ok: false, reason: "used", per: rule.per, limit: rule.limit };
  if (taken + need > rule.limit) return { ok: false, reason: "short", per: rule.per, left: rule.limit - taken, need };
  if (c.attempts >= attemptsCap(rule.limit)) return { ok: false, reason: "tries", per: rule.per };
  return { ok: true, remaining: rule.limit - taken };
}

/** The keys request [id] holds [n] of the allowance under. */
const holdKeys = (id: string, n: number) => (n === 1 ? [id] : Array.from({ length: n }, (_, i) => `${id}#${i}`));

/** The usage once request [id] starts: one more try, and [n] of the allowance held for it. */
export function hold(usage: Usage | undefined, period: string, id: string, nowMs = Date.now(), n = 1): Usage {
  const c = current(usage, period, nowMs);
  const held = live(c.held, nowMs);
  for (const key of holdKeys(id, n)) held[key] = nowMs;
  return { ...c, attempts: c.attempts + 1, held };
}

/**
 * The usage once request [id] ends: its hold is given back, and an answer ([answered]) counts. If a
 * later period started meanwhile, the request's hold moved there with it, and so does its answer.
 */
export function release(usage: Usage | undefined, period: string, id: string, answered: boolean, nowMs = Date.now(), n = 1): Usage {
  const c = usage && usage.period >= period ? usage : current(usage, period, nowMs);
  const held = live(c.held, nowMs);
  for (const key of holdKeys(id, n)) delete held[key];
  return { ...c, count: c.count + (answered ? n : 0), held };
}

/** What the app shows: this period's answers against the plan's limit (null: not in the plan). */
export interface Allowance {
  used: number;
  limit: number | null;
  per: "day" | "week";
}

export function allowance(rule: Rule, usage: Usage | undefined, period: string): Allowance {
  const used = usage && usage.period === period ? usage.count : 0;
  return { used, limit: rule.limit, per: rule.per };
}

const NAMES: Record<Feature, [string, string]> = {
  quickAdd: ["quick add", "quick adds"],
  receipt: ["receipt scan", "receipt scans"],
  analysisRequest: ["report request", "report requests"],
  analysisReport: ["AI report", "AI reports"],
};

/** Arabic names, as plural nouns: the sentences below avoid number agreement. */
const NAMES_AR: Record<Feature, string> = {
  quickAdd: "الإضافات السريعة",
  receipt: "مسح الإيصالات",
  analysisRequest: "أسئلة التقارير",
  analysisReport: "تقارير الذكاء الاصطناعي",
};

/** The languages the app is in; anything else gets English. */
export type Lang = "en" | "ar";

/** What the person reads when a request isn't allowed, in the app's language. */
export function message(feature: Feature, v: Exclude<Verdict, { ok: true }>, lang: Lang = "en"): string {
  if (lang === "ar") {
    const noun = NAMES_AR[feature];
    switch (v.reason) {
      case "locked":
        return feature === "receipt" ? "قراءة الإيصالات بالذكاء الاصطناعي ضمن Premium." : "تقارير الذكاء الاصطناعي ضمن Premium.";
      case "used":
        return v.per === "day"
          ? `استخدمت كل ما لديك اليوم من ${noun} (${v.limit}). يُعاد العدّ عند منتصف الليل.`
          : `استخدمت كل ما لديك هذا الأسبوع من ${noun} (${v.limit}). يُعاد العدّ يوم الاثنين.`;
      case "short":
        return `يحتاج هذا الطلب ${v.need} من ${noun} (واحد لكل صورة)، وبقي لك ${v.left} ${v.per === "day" ? "اليوم" : "هذا الأسبوع"}.`;
      case "tries":
        return `محاولات كثيرة في ${noun} ${v.per === "day" ? "اليوم" : "هذا الأسبوع"}. حاول مرة أخرى ${v.per === "day" ? "غدًا" : "الأسبوع القادم"}.`;
    }
  }
  const [one, many] = NAMES[feature];
  switch (v.reason) {
    case "locked":
      return feature === "receipt"
        ? "Reading receipts with AI is part of Premium."
        : "AI reports are part of Premium.";
    case "used":
      return v.per === "day"
        ? `You've used today's ${v.limit} ${v.limit === 1 ? one : many}. They reset at midnight.`
        : `You've used this week's ${v.limit} ${v.limit === 1 ? one : many}. They reset on Monday.`;
    case "short":
      return `This uses ${v.need} ${many} (one per photo), and ${v.left} ${v.left === 1 ? "is" : "are"} left ${v.per === "day" ? "today" : "this week"}.`;
    case "tries":
      return `Too many tries for ${many} ${v.per === "day" ? "today" : "this week"}. Try again ${v.per === "day" ? "tomorrow" : "next week"}.`;
  }
}

/** The backend's other messages, in the app's language. */
const TEXT = {
  busy: ["The AI is busy right now. Try again in a moment.", "الذكاء الاصطناعي مشغول الآن. حاول مرة أخرى بعد قليل."],
  slow: ["The AI took too long to answer. Try again.", "تأخّر ردّ الذكاء الاصطناعي كثيرًا. حاول مرة أخرى."],
  network: ["Couldn't reach the AI. Try again in a moment.", "تعذّر الوصول إلى الذكاء الاصطناعي. حاول مرة أخرى بعد قليل."],
  broken: ["The AI's answer came back broken. Try again.", "جاء ردّ الذكاء الاصطناعي ناقصًا. حاول مرة أخرى."],
  blocked: ["The AI couldn't answer that one. Try saying it differently.", "لم يتمكّن الذكاء الاصطناعي من الإجابة على هذا. جرّب صياغة أخرى."],
  rejected: ["The AI service refused the request. Try again later.", "رفضت خدمة الذكاء الاصطناعي الطلب. حاول لاحقًا."],
  signIn: ["Sign in again to use the AI.", "سجّل الدخول مجددًا لاستخدام الذكاء الاصطناعي."],
  featurePaused: ["This AI feature is paused for now. Try again later.", "هذه الميزة متوقفة مؤقتًا. حاول لاحقًا."],
  dayPaused: ["The AI is paused for today. Try again tomorrow.", "الذكاء الاصطناعي متوقف اليوم. حاول غدًا."],
  tooMany: ["Too many requests at once. Try again in a moment.", "طلبات كثيرة في وقت واحد. حاول مرة أخرى بعد قليل."],
} as const;

export function text(key: keyof typeof TEXT, lang: Lang = "en"): string {
  return TEXT[key][lang === "ar" ? 1 : 0];
}

export function langOf(v: unknown): Lang {
  return v === "ar" ? "ar" : "en";
}
