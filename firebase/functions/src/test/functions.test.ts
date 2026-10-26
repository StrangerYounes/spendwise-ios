import { test } from "node:test";
import assert from "node:assert/strict";
import { NamesContext, analysisReportPrompt, basePrompts, instructionsPart, quickAddPrompt, receiptPrompt, SCHEMAS, FEATURES } from "../prompts";
import { HOLD_MS, PinnedTz, REFUSALS_RECORDED, RULES, refuse, TZ_CHANGE_MS, Usage, allowance, tzFor, attemptsCap, check, hold, langOf, message, periodFor, periodKey, release, text } from "../limits";
import { BadRequest, LIMITS, charges, readRequest } from "../request";
import { KEEP_DAYS, dayUpdate, utcDay } from "../history";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

const context: NamesContext = {
  categories: ["Groceries", "Car 🚗"],
  stores: ["Spinneys"],
  knownItems: ["Gas", "Milk"],
  openLists: [{ name: "Weekly", toBuy: ["Eggs", "Bread"] }],
  currencySymbol: "$",
  conversionRate: null,
  today: "Sunday, 2026-10-18",
  firstRecord: "2026-07-01",
};

// ---------- prompts ----------

test("quick add prompt lists existing names and today", () => {
  const prompt = quickAddPrompt("filled gas for 40", context, false);
  assert.ok(prompt.includes("Today is Sunday, 2026-10-18."));
  assert.ok(prompt.includes("Existing categories: Groceries, Car 🚗"));
  assert.ok(prompt.includes("Existing stores: Spinneys"));
  assert.ok(prompt.includes("Open lists: Weekly"));
  assert.ok(prompt.includes("Known items: Gas, Milk"));
  assert.ok(prompt.includes("Set transcript to null."));
  assert.ok(prompt.endsWith('Description:\n"""\nfilled gas for 40\n"""\nReturn JSON only.'));
});

test("voice note prompt asks for a transcript and has no description block", () => {
  const prompt = quickAddPrompt(null, context, true);
  assert.ok(prompt.includes("attached voice note"));
  assert.ok(!prompt.includes("Description:"));
  assert.ok(prompt.endsWith("Return JSON only."));
});

test("saved rate appears only when there is one", () => {
  const withRate = quickAddPrompt("2 bread for 80000 each", { ...context, conversionRate: 89_500 }, false);
  assert.ok(withRate.includes("1 $ is about 89,500 of it"));
  assert.ok(withRate.includes("(about $0.89 each)"));
  assert.ok(!quickAddPrompt("bread", context, false).includes("89,500"));
});

test("receipt prompt carries open lists with their items", () => {
  const prompt = receiptPrompt(context);
  assert.ok(prompt.includes("The person's currency is $."));
  assert.ok(prompt.includes("- Weekly: Eggs, Bread"));
  assert.ok(receiptPrompt({ ...context, openLists: [] }).includes("Open lists with their items to buy:\n(none)"));
});

test("report prompt carries the request, language and data", () => {
  const prompt = analysisReportPrompt({
    said: "habits in September", periodLabel: "Sep 1 – Sep 30, 2026", focus: ["shopping habits"],
    question: "Do I shop too often?", currencyExample: "$4.50", language: "English", data: "TOTALS\nPeriod: $5",
  });
  assert.ok(prompt.includes("in English."));
  assert.ok(prompt.includes('They asked: "habits in September"'));
  assert.ok(prompt.includes("Make sure the report answers: Do I shop too often?"));
  assert.ok(prompt.endsWith("DATA\nTOTALS\nPeriod: $5"));
});

test("no prompt or schema mentions who the person is", () => {
  const all = [quickAddPrompt("x", context, true), receiptPrompt(context), JSON.stringify(SCHEMAS)].join("\n").toLowerCase();
  for (const word of ["uid", "email", "user id", "account"]) assert.ok(!all.includes(word), word);
  assert.deepEqual(Object.keys(SCHEMAS).sort(), [...FEATURES].sort());
});

// ---------- limits ----------

test("plans follow PLAN.md", () => {
  assert.equal(RULES.free.quickAdd.limit, 10);
  assert.equal(RULES.free.receipt.limit, null);
  assert.equal(RULES.free.analysisReport.limit, null);
  assert.equal(RULES.premium.quickAdd.limit, 100);
  assert.equal(RULES.premium.receipt.limit, 20);
  assert.deepEqual(RULES.premium.analysisReport, { limit: 3, per: "week" });
});

test("Max is at least Premium everywhere, with reports by the day, and still capped", () => {
  for (const f of Object.keys(RULES.premium) as (keyof typeof RULES.premium)[]) {
    assert.ok(RULES.max[f].limit! >= RULES.premium[f].limit!);
    assert.ok(Number.isFinite(RULES.max[f].limit!));
  }
  assert.deepEqual(RULES.max.analysisReport, { limit: 50, per: "day" });
});

test("periods use the phone's local day and Monday-started weeks", () => {
  // 2026-10-18 22:30 UTC is already Monday the 19th in Beirut (UTC+3)
  const t = Date.UTC(2026, 9, 18, 22, 30);
  assert.equal(periodKey("day", t, 0), "2026-10-18");
  assert.equal(periodKey("day", t, 180), "2026-10-19");
  assert.equal(periodKey("week", t, 0), "2026-10-12");
  assert.equal(periodKey("week", t, 180), "2026-10-19");
});

test("only answers use the allowance, and a new period starts fresh", () => {
  const rule = RULES.free.quickAdd;
  let usage: Usage | undefined = undefined;
  for (let i = 0; i < 10; i++) {
    const v = check(rule, usage, "2026-10-18");
    assert.ok(v.ok && v.remaining === 10 - i);
    usage = release(hold(usage, "2026-10-18", `r${i}`), "2026-10-18", `r${i}`, true);
  }
  const used = check(rule, usage, "2026-10-18");
  assert.ok(!used.ok && used.reason === "used");
  assert.equal(message("quickAdd", used as never), "You've used today's 10 quick adds. They reset at midnight.");
  assert.ok(check(rule, usage, "2026-10-19").ok);
});

test("failed tries are capped too", () => {
  const rule = RULES.premium.analysisReport;
  let usage: Usage | undefined = undefined;
  for (let i = 0; i < attemptsCap(3); i++) usage = release(hold(usage, "2026-10-12", `r${i}`), "2026-10-12", `r${i}`, false);
  const v = check(rule, usage, "2026-10-12");
  assert.ok(!v.ok && v.reason === "tries");
});

test("requests in flight hold their place, so sending many at once gets no more", () => {
  const rule = RULES.free.quickAdd;
  const now = Date.UTC(2026, 9, 18, 12);
  let usage: Usage | undefined = undefined;
  let let_through = 0;
  for (let i = 0; i < 40; i++) {
    if (check(rule, usage, "2026-10-18", now).ok) {
      usage = hold(usage, "2026-10-18", `r${i}`, now);
      let_through++;
    }
  }
  assert.equal(let_through, 10);
  // One fails and gives its place back; the rest answer
  usage = release(usage, "2026-10-18", "r0", false, now);
  assert.ok(check(rule, usage, "2026-10-18", now).ok);
  for (let i = 1; i < 10; i++) usage = release(usage, "2026-10-18", `r${i}`, true, now);
  assert.equal(usage!.count, 9);
  assert.deepEqual(usage!.held, {});
});

test("a request that never ends gives its place back after a while", () => {
  const rule = RULES.premium.analysisReport;
  const now = Date.UTC(2026, 9, 18, 12);
  let usage: Usage | undefined = undefined;
  for (let i = 0; i < 3; i++) usage = hold(usage, "2026-10-12", `r${i}`, now);
  assert.ok(!check(rule, usage, "2026-10-12", now).ok);
  assert.ok(check(rule, usage, "2026-10-12", now + HOLD_MS + 1).ok);
});

test("switching the time zone back and forth doesn't start a fresh day", () => {
  const rule = RULES.free.quickAdd;
  const t = Date.UTC(2026, 9, 18, 12);
  let usage: Usage | undefined = undefined;
  let answered = 0;
  for (let round = 0; round < 10; round++) {
    for (const tz of [840, -840, 0]) {
      const period = periodFor("day", t, tz, usage);
      if (check(rule, usage, period, t).ok) {
        usage = release(hold(usage, period, "r", t), period, "r", true, t);
        answered++;
      }
    }
  }
  // The first +14 h request moved this account to tomorrow; earlier days aren't reopened
  assert.equal(answered, 10);
  assert.equal(usage!.period, "2026-10-19");
  // Tomorrow's own count carries on rather than starting again
  assert.equal(periodFor("day", t + 86_400_000, 0, usage), "2026-10-19");
  assert.ok(!check(rule, usage, "2026-10-19", t + 86_400_000).ok);
});

test("requests in flight when the day moves forward keep their places and count there", () => {
  // The review's case: at 12:00 UTC, 10 Free quick adds held on yesterday (tz -14 h), then one on today
  const rule = RULES.free.quickAdd;
  const t = Date.UTC(2026, 9, 21, 12);
  let usage: Usage | undefined = undefined;
  const yesterday = periodFor("day", t, -840, usage);
  for (let i = 0; i < 10; i++) {
    assert.ok(check(rule, usage, yesterday, t).ok);
    usage = hold(usage, yesterday, `r${i}`, t);
  }
  const today = periodFor("day", t, 0, usage);
  assert.notEqual(today, yesterday);
  assert.ok(!check(rule, usage, today, t).ok, "the 10 in flight still hold today's places");
  // They answer after the day moved on: counted on the day they moved to
  usage = { ...usage!, period: today, held: usage!.held };
  for (let i = 0; i < 10; i++) usage = release(usage, yesterday, `r${i}`, true, t);
  assert.equal(usage!.period, today);
  assert.equal(usage!.count, 10);
  assert.ok(!check(rule, usage, periodFor("day", t, 840, usage), t).ok || periodFor("day", t, 840, usage) !== today);
});

test("across the review's whole burst, the time zone stays put and the day doesn't move", () => {
  // Everything any offset allows, one after another and with answers held until another request moves the day
  const rule = RULES.free.quickAdd;
  const t = Date.UTC(2026, 9, 21, 12);
  let usage: Usage | undefined = undefined;
  let pinned: PinnedTz | undefined = undefined;
  let answered = 0;
  for (const tz of [-840, 0, 840, -840, 0, 840]) {
    const z = tzFor(pinned, tz, t);
    if (z.pin) pinned = z.pin;
    const period = periodFor("day", t, z.offset, usage);
    const ids: string[] = [];
    for (let i = 0; i < 20; i++) {
      if (!check(rule, usage, period, t).ok) break;
      const id = `${tz}-${i}-${answered}`;
      usage = hold(usage, period, id, t);
      ids.push(id);
    }
    for (const id of ids) { usage = release(usage, period, id, true, t); answered++; }
  }
  assert.equal(answered, 10);
});

test("a new time zone counts after it has stayed 20 hours (travel)", () => {
  const t = Date.UTC(2026, 9, 21, 12);
  const pinned = { offset: 180, at: t };
  assert.equal(tzFor(pinned, -300, t + 3600_000).offset, 180);
  const later = tzFor(pinned, -300, t + TZ_CHANGE_MS);
  assert.equal(later.offset, -300);
  assert.deepEqual(later.pin, { offset: -300, at: t + TZ_CHANGE_MS });
  assert.equal(tzFor(undefined, 180, t).pin!.offset, 180);
  assert.equal(tzFor(pinned, 180, t).pin, null);
});

test("features outside the plan are locked", () => {
  const v = check(RULES.free.receipt, undefined, "2026-10-18");
  assert.ok(!v.ok && v.reason === "locked");
  assert.equal(message("receipt", v as never), "Reading receipts with AI is part of Premium.");
});

// ---------- requests ----------

const base = { tzOffsetMin: 180, context: { today: "Sunday, 2026-10-18" } };

test("a quick add needs words or a voice note", () => {
  assert.throws(() => readRequest({ ...base, feature: "quickAdd", text: "  " }), BadRequest);
  assert.equal(readRequest({ ...base, feature: "quickAdd", text: "milk 2" }).text, "milk 2");
  assert.ok(readRequest({ ...base, feature: "quickAdd", audio: "AAAA" }).audio);
});

test("each feature takes only its own kind of input", () => {
  assert.throws(() => readRequest({ ...base, feature: "receipt" }), BadRequest);
  assert.throws(() => readRequest({ ...base, feature: "quickAdd", text: "x", image: "AAAA" }), BadRequest);
  assert.throws(() => readRequest({ ...base, feature: "analysisReport", audio: "AAAA" }), BadRequest);
  assert.throws(() => readRequest({ ...base, feature: "nope", text: "x" }), BadRequest);
  assert.throws(() => readRequest({ ...base, feature: "quickAdd", audio: "not base64!" }), BadRequest);
});

test("a receipt takes up to three photos and an optional note", () => {
  const one = readRequest({ ...base, feature: "receipt", image: "AAAA" });
  assert.deepEqual(one.images, ["AAAA"]);
  assert.equal(one.text, null);
  const three = readRequest({ ...base, feature: "receipt", images: ["AAAA", "BBBB", "CCCC"], audio: "AAAA", text: "translate the names" });
  assert.equal(three.images.length, 3);
  assert.equal(three.text, "translate the names");
  assert.ok(three.audio);
  assert.throws(() => readRequest({ ...base, feature: "receipt", images: ["AAAA", "AAAA", "AAAA", "AAAA"] }), BadRequest);
  assert.throws(() => readRequest({ ...base, feature: "receipt", images: [] }), BadRequest);
  assert.throws(() => readRequest({ ...base, feature: "receipt", images: ["AAAA", "no!"] }), BadRequest);
  assert.throws(() => readRequest({ ...base, feature: "receipt", image: "AAAA", images: ["AAAA"] }), BadRequest);
  const big = "A".repeat(LIMITS.imageBase64);
  assert.throws(() => readRequest({ ...base, feature: "receipt", images: [big, big, "AAAA"] }), BadRequest);
});

test("a follow-up carries the result so far and what to change", () => {
  const previous = JSON.stringify({ purchases: [] });
  const r = readRequest({ ...base, feature: "quickAdd", text: "make it 3 milks", previous });
  assert.equal(r.previous, previous);
  assert.throws(() => readRequest({ ...base, feature: "quickAdd", previous }), BadRequest);
  assert.throws(() => readRequest({ ...base, feature: "receipt", image: "AAAA", previous }), BadRequest);
  assert.ok(readRequest({ ...base, feature: "receipt", image: "AAAA", audio: "AAAA", previous }).previous);
  assert.throws(() => readRequest({ ...base, feature: "quickAdd", text: "x", previous: "not json" }), BadRequest);
  assert.throws(() => readRequest({ ...base, feature: "quickAdd", text: "x", previous: "[1]" }), BadRequest);
  assert.throws(() => readRequest({ ...base, feature: "analysisRequest", text: "x", previous }), BadRequest);
  assert.throws(() => readRequest({ ...base, feature: "quickAdd", text: "x", previous: "x".repeat(LIMITS.previous + 1) }), BadRequest);
});

test("receipt prompt: photos, the note, known items and follow-ups", () => {
  const plain = receiptPrompt(context);
  assert.ok(plain.startsWith("This is a photo of a shop receipt."));
  assert.ok(plain.includes("Known items: "));
  assert.ok(plain.includes("Set transcript to null."));
  const long = receiptPrompt(context, { photos: 2, note: "names in English please", hasAudio: false, previous: null });
  assert.ok(long.includes("2 photos of one long shop receipt"));
  assert.ok(long.includes("never count it twice"));
  assert.ok(long.endsWith('Note:\n"""\nnames in English please\n"""\nReturn JSON only.'));
  const voice = receiptPrompt(context, { photos: 1, note: null, hasAudio: true, previous: null });
  assert.ok(voice.includes("attached a voice note"));
  const fix = receiptPrompt(context, { photos: 1, note: "the store is Spinneys", hasAudio: false, previous: '{"items":[]}' });
  assert.ok(fix.includes("FOLLOW-UP"));
  assert.ok(fix.includes('Result so far:\n{"items":[]}'));
  assert.ok(fix.includes("the store is Spinneys"));
  const qa = quickAddPrompt("rename milk", context, false, '{"purchases":[]}');
  assert.ok(qa.includes("FOLLOW-UP") && qa.includes("Changes asked:") && !qa.includes("Description:"));
});

test("sizes are capped", () => {
  assert.throws(() => readRequest({ ...base, feature: "quickAdd", text: "x".repeat(LIMITS.text + 1) }), BadRequest);
  assert.throws(() => readRequest({ ...base, feature: "quickAdd", text: "x", context: { ...base.context, stores: Array(LIMITS.names + 1).fill("s") } }), BadRequest);
  assert.throws(() => readRequest({ ...base, feature: "quickAdd", text: "x", tzOffsetMin: 15 * 60 }), BadRequest);
  assert.throws(() => readRequest({ ...base, feature: "quickAdd", text: "x", context: { today: "today" } }), BadRequest);
  // Many long names in open lists: each list is allowed, the total isn't
  const lists = Array(LIMITS.openLists).fill(0).map((_, i) => ({ name: `L${i}`, toBuy: Array(LIMITS.listItems).fill("x".repeat(LIMITS.name)) }));
  assert.throws(() => readRequest({ ...base, feature: "quickAdd", text: "x", context: { ...base.context, openLists: lists } }), BadRequest);
  assert.throws(() => readRequest({ ...base, feature: "quickAdd", text: "x", context: { ...base.context, openLists: [...lists, ...lists] } }), BadRequest);
  assert.ok(readRequest({ ...base, feature: "quickAdd", text: "x", context: { ...base.context, openLists: lists.slice(0, 1) } }));
});

test("a report needs its prepared data and no names", () => {
  const r = readRequest({ tzOffsetMin: 0, feature: "analysisReport", report: { periodLabel: "Sep", data: "TOTALS" } });
  assert.equal(r.context, null);
  assert.equal(r.report!.language, "English");
  assert.throws(() => readRequest({ tzOffsetMin: 0, feature: "analysisReport", report: { periodLabel: "Sep" } }), BadRequest);
});

test("the allowance shown counts this period's answers only", () => {
  const rule = RULES.premium.analysisReport;
  assert.deepEqual(allowance(rule, { period: "2026-10-19", count: 2, attempts: 4 }, "2026-10-19"), { used: 2, limit: 3, per: "week" });
  assert.deepEqual(allowance(rule, { period: "2026-10-12", count: 3, attempts: 3 }, "2026-10-19"), { used: 0, limit: 3, per: "week" });
  assert.deepEqual(allowance(RULES.free.receipt, undefined, "2026-10-21"), { used: 0, limit: null, per: "day" });
});

// ---------- usage history ----------

test("the day record counts requests and tokens, never what was said", () => {
  const now = Date.UTC(2026, 9, 21, 23, 30);
  assert.equal(utcDay(now), "2026-10-21");
  const answered = dayUpdate("receipt", { kind: "answered", promptTokens: 1200, outputTokens: 300, thoughtTokens: 0 }, "premium", now);
  assert.deepEqual(Object.keys(answered).sort(), ["expireAt", "receipt", "tier"]);
  assert.deepEqual(Object.keys(answered.receipt as object).sort(), ["answers", "outputTokens", "promptTokens", "thoughtTokens"]);
  assert.ok((answered.receipt as Record<string, unknown>).answers instanceof FieldValue);
  assert.equal((answered.expireAt as Timestamp).toMillis(), now + KEEP_DAYS * 86_400_000);
  assert.deepEqual(Object.keys(dayUpdate("quickAdd", { kind: "refused" }, "free", now).quickAdd as object), ["refused"]);
  // A failed request still records what Gemini billed for its tries
  assert.deepEqual(Object.keys(dayUpdate("quickAdd", { kind: "failed", promptTokens: 900, outputTokens: 16000, thoughtTokens: 0 }, "free", now).quickAdd as object).sort(),
    ["failed", "outputTokens", "promptTokens", "thoughtTokens"]);
});

test("messages come in the app's language", () => {
  const used = check(RULES.free.quickAdd, { period: "2026-10-18", count: 10, attempts: 10 }, "2026-10-18");
  assert.ok(!used.ok);
  assert.equal(message("quickAdd", used as never), "You've used today's 10 quick adds. They reset at midnight.");
  assert.equal(message("quickAdd", used as never, "ar"), "استخدمت كل ما لديك اليوم من الإضافات السريعة (10). يُعاد العدّ عند منتصف الليل.");
  assert.equal(text("busy", langOf("ar")), "الذكاء الاصطناعي مشغول الآن. حاول مرة أخرى بعد قليل.");
  assert.equal(text("busy", langOf("fr")), "The AI is busy right now. Try again in a moment.");
});

test("an Arabic report asks for Western digits", () => {
  const input = { said: "", periodLabel: "Oct", focus: ["spending"], question: null, currencyExample: "$4.50", data: "TOTALS" };
  assert.ok(analysisReportPrompt({ ...input, language: "Arabic" }).includes("Western digits (0-9)"));
  assert.ok(!analysisReportPrompt({ ...input, language: "English" }).includes("Western digits"));
});

test("refusals are counted per period, so only the first few go into the history", () => {
  let usage: Usage | undefined = { period: "2026-10-21", count: 10, attempts: 10 };
  for (let i = 0; i < REFUSALS_RECORDED + 5; i++) usage = refuse(usage, "2026-10-21");
  assert.equal(usage!.refused, REFUSALS_RECORDED + 5);
  assert.equal(usage!.count, 10);
  assert.equal(refuse(usage, "2026-10-22").refused, 1);
});

test("what a request uses: one per photo, a note is a quick add, a follow-up is one quick add", () => {
  const ctx = { context: base.context };
  assert.deepEqual(charges(readRequest({ ...base, feature: "quickAdd", text: "milk" })), [["quickAdd", 1]]);
  assert.deepEqual(charges(readRequest({ ...base, ...ctx, feature: "receipt", images: ["AAAA", "BBBB"] })), [["receipt", 2]]);
  assert.deepEqual(charges(readRequest({ ...base, ...ctx, feature: "receipt", images: ["AAAA", "BBBB"], text: "English names" })), [["receipt", 2], ["quickAdd", 1]]);
  assert.deepEqual(charges(readRequest({ ...base, ...ctx, feature: "receipt", image: "AAAA", audio: "AAAA" })), [["receipt", 1], ["quickAdd", 1]]);
  const previous = JSON.stringify({ items: [] });
  assert.deepEqual(charges(readRequest({ ...base, ...ctx, feature: "receipt", images: ["AAAA", "BBBB"], text: "fix", previous })), [["quickAdd", 1]]);
});

test("a request can hold several of the allowance, and is refused when fewer are left", () => {
  const rule = RULES.premium.receipt; // 20 a day
  const day = "2026-10-25";
  const now = Date.parse("2026-10-25T10:00:00Z");
  let u = hold(undefined, day, "a", now, 3);
  assert.equal(Object.keys(u.held!).length, 3);
  assert.equal(u.attempts, 1);
  u = release(u, day, "a", true, now, 3);
  assert.equal(u.count, 3);
  assert.equal(Object.keys(u.held!).length, 0);
  const nearlyDone: Usage = { period: day, count: 19, attempts: 19 };
  const v = check(rule, nearlyDone, day, now, 2);
  assert.deepEqual(v, { ok: false, reason: "short", per: "day", left: 1, need: 2 });
  assert.equal(message("receipt", v as never), "This uses 2 receipt scans (one per photo), and 1 is left today.");
  assert.ok(check(rule, nearlyDone, day, now, 1).ok);
  // A failed request gives all its holds back
  const failed = release(hold(nearlyDone, day, "b", now, 1), day, "b", false, now, 1);
  assert.equal(failed.count, 19);
});

test("the person's own instructions: capped, trimmed, and shown with the base prompts", () => {
  assert.equal(readRequest({ ...base, feature: "quickAdd", text: "x", instructions: "  Names in English  " }).instructions, "Names in English");
  assert.equal(readRequest({ ...base, feature: "quickAdd", text: "x", instructions: "   " }).instructions, null);
  assert.throws(() => readRequest({ ...base, feature: "quickAdd", text: "x", instructions: "x".repeat(LIMITS.instructions + 1) }), BadRequest);
  assert.ok(instructionsPart("Names in English").includes('"""\nNames in English\n"""'));
  const p = basePrompts();
  assert.ok(p.quickAdd.includes("[your item library, most bought first]"));
  assert.ok(p.receipt.includes("[your note, if you add one]"));
  assert.ok(p.analysisReport.includes("[your figures for the period"));
});
