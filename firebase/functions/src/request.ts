// Reads what the phone sent, with a cap on every field: a request can only carry what its
// feature needs, and never so much that it costs more than the feature is meant to.

import { Feature, FEATURES, NamesContext, ReportInput } from "./prompts";

export class BadRequest extends Error {}

export interface AiRequest {
  feature: Feature;
  text: string | null;
  /** Base64 AAC voice note. */
  audio: string | null;
  /** Base64 JPEG photos of one receipt, top to bottom. */
  images: string[];
  /** A follow-up: the result the person has now (JSON), which [text] or [audio] asks to change. */
  previous: string | null;
  /** The person's names; reports get prepared figures instead. */
  context: NamesContext | null;
  report: ReportInput | null;
  /** Minutes the phone's clock is ahead of UTC, for "today" and "this week". */
  tzOffsetMin: number;
  /** The person's own additions to this feature's prompt (Settings → Your AI instructions). */
  instructions: string | null;
  /** Debug builds' plan switch; only the local emulator listens to it. */
  debugTier: string | null;
}

export const LIMITS = {
  // The app stops typing at 1,000 (PLAN.md, Guards)
  text: 1_000,
  // A 2 minute note at 32 kbps is about 0.5 MB, so 0.7 MB in base64
  audioBase64: 1_500_000,
  // 2560 px JPEG at 85% is usually 0.5 to 2 MB
  imageBase64: 8_000_000,
  // A long receipt in up to three photos
  images: 3,
  imagesBase64: 16_000_000,
  // The review being corrected: a big receipt is about 60 lines of ~150 characters
  previous: 20_000,
  // The person's own instructions for one feature
  instructions: 1_000,
  name: 120,
  names: 400,
  // What the app sends at most (AiGateway.names)
  openLists: 50,
  listItems: 150,
  knownItems: 200,
  // All the names together: about 8k tokens, so one request can't cost much more than a normal one
  contextChars: 30_000,
  reportData: 300_000,
  short: 300,
};

type Obj = Record<string, unknown>;

const isObj = (v: unknown): v is Obj => typeof v === "object" && v !== null && !Array.isArray(v);

function str(o: Obj, key: string, max: number, required = false): string | null {
  const v = o[key];
  if (v === undefined || v === null || v === "") {
    if (required) throw new BadRequest(`${key} is missing`);
    return null;
  }
  if (typeof v !== "string") throw new BadRequest(`${key} must be text`);
  if (v.length > max) throw new BadRequest(`${key} is too long`);
  return v;
}

function names(o: Obj, key: string, max = LIMITS.names): string[] {
  const v = o[key];
  if (v === undefined || v === null) return [];
  if (!Array.isArray(v) || v.length > max) throw new BadRequest(`${key} must be a short list`);
  return v.map((x) => {
    if (typeof x !== "string" || x.length > LIMITS.name) throw new BadRequest(`${key} has a bad name`);
    return x;
  });
}

const BASE64 = /^[A-Za-z0-9+/]+=*$/;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const TODAY = /^[A-Za-z]+, \d{4}-\d{2}-\d{2}$/;

function base64(o: Obj, key: string, max: number): string | null {
  const v = str(o, key, max);
  if (v !== null && !BASE64.test(v)) throw new BadRequest(`${key} isn't base64`);
  return v;
}

/** `images`, or the single `image` that app versions before 25 Oct send. */
function photos(o: Obj): string[] {
  const one = base64(o, "image", LIMITS.imageBase64);
  const v = o.images;
  if (v === undefined || v === null) return one ? [one] : [];
  if (one) throw new BadRequest("send image or images, not both");
  if (!Array.isArray(v) || v.length > LIMITS.images) throw new BadRequest("too many photos");
  const all = v.map((x, i) => {
    if (typeof x !== "string" || !x) throw new BadRequest(`photo ${i + 1} is missing`);
    if (x.length > LIMITS.imageBase64) throw new BadRequest(`photo ${i + 1} is too big`);
    if (!BASE64.test(x)) throw new BadRequest(`photo ${i + 1} isn't base64`);
    return x;
  });
  if (all.reduce((n, x) => n + x.length, 0) > LIMITS.imagesBase64) throw new BadRequest("the photos are too big together");
  return all;
}

function context(v: unknown): NamesContext {
  const o = isObj(v) ? v : {};
  const rawLists = o.openLists ?? [];
  if (!Array.isArray(rawLists) || rawLists.length > LIMITS.openLists) throw new BadRequest("too many open lists");
  const openLists = rawLists.map((l) => {
    if (!isObj(l)) throw new BadRequest("bad open list");
    return { name: str(l, "name", LIMITS.name, true)!, toBuy: names(l, "toBuy", LIMITS.listItems) };
  });
  const today = str(o, "today", 40, true)!;
  if (!TODAY.test(today)) throw new BadRequest("today must look like 'Sunday, 2026-10-18'");
  const firstRecord = str(o, "firstRecord", 10);
  if (firstRecord !== null && !DAY.test(firstRecord)) throw new BadRequest("firstRecord must be YYYY-MM-DD");
  const rate = o.conversionRate;
  if (rate !== undefined && rate !== null && (typeof rate !== "number" || !(rate > 0) || rate > 1e9)) {
    throw new BadRequest("conversionRate must be a positive number");
  }
  const categories = names(o, "categories");
  const stores = names(o, "stores");
  const knownItems = names(o, "knownItems", LIMITS.knownItems);
  const chars = (xs: string[]) => xs.reduce((n, x) => n + x.length + 2, 0);
  const total = chars(categories) + chars(stores) + chars(knownItems) +
    openLists.reduce((n, l) => n + l.name.length + chars(l.toBuy), 0);
  if (total > LIMITS.contextChars) throw new BadRequest("too many names");
  return {
    categories,
    stores,
    knownItems,
    openLists,
    currencySymbol: str(o, "currencySymbol", 8) ?? "$",
    conversionRate: typeof rate === "number" ? rate : null,
    today,
    firstRecord,
  };
}

function report(v: unknown): ReportInput {
  if (!isObj(v)) throw new BadRequest("report is missing");
  const focus = names(v, "focus", 5);
  return {
    said: str(v, "said", LIMITS.text) ?? "",
    periodLabel: str(v, "periodLabel", 80, true)!,
    focus: focus.length ? focus : ["spending", "price trends", "shopping habits"],
    question: str(v, "question", LIMITS.text),
    currencyExample: str(v, "currencyExample", 30) ?? "$4.50",
    language: str(v, "language", 40) ?? "English",
    data: str(v, "data", LIMITS.reportData, true)!,
  };
}

export function readRequest(data: unknown): AiRequest {
  if (!isObj(data)) throw new BadRequest("expected an object");
  const feature = data.feature;
  if (typeof feature !== "string" || !FEATURES.includes(feature as Feature)) throw new BadRequest("unknown feature");
  const f = feature as Feature;
  const tz = data.tzOffsetMin;
  if (typeof tz !== "number" || !Number.isInteger(tz) || Math.abs(tz) > 14 * 60) throw new BadRequest("bad tzOffsetMin");

  const text = str(data, "text", LIMITS.text);
  const audio = base64(data, "audio", LIMITS.audioBase64);
  const images = photos(data);
  const previous = str(data, "previous", LIMITS.previous);
  if (previous !== null) {
    if (f !== "quickAdd" && f !== "receipt") throw new BadRequest("this feature takes no follow-up");
    let parsed: unknown;
    try {
      parsed = JSON.parse(previous);
    } catch {
      throw new BadRequest("previous isn't JSON");
    }
    if (!isObj(parsed)) throw new BadRequest("previous must be an object");
  }
  // A receipt's note is optional; a follow-up has to say what to change
  const needsWords = f === "quickAdd" || f === "analysisRequest" || previous !== null;
  const takesWords = needsWords || f === "receipt";
  if (needsWords && !text?.trim() && !audio) throw new BadRequest("say or type something first");
  if (f === "receipt" && !images.length) throw new BadRequest("image is missing");
  if (!takesWords && audio) throw new BadRequest("this feature takes no voice note");
  if (f !== "receipt" && images.length) throw new BadRequest("this feature takes no photo");

  return {
    feature: f,
    text: takesWords ? text : null,
    audio,
    images,
    previous,
    context: f === "analysisReport" ? null : context(data.context),
    report: f === "analysisReport" ? report(data.report) : null,
    tzOffsetMin: tz,
    instructions: str(data, "instructions", LIMITS.instructions)?.trim() || null,
    debugTier: str(data, "debugTier", 20),
  };
}

/**
 * What a request uses of the allowance: one of its feature, except that a receipt uses one receipt
 * scan per photo and one quick add for its note (typed or spoken), and a follow-up ("ask for
 * changes", with or without photos) is one quick add.
 */
export function charges(r: AiRequest): [Feature, number][] {
  if (r.previous !== null) return [["quickAdd", 1]];
  if (r.feature === "receipt") {
    const note = !!r.text?.trim() || !!r.audio;
    return note ? [["receipt", r.images.length], ["quickAdd", 1]] : [["receipt", r.images.length]];
  }
  return [[r.feature, 1]];
}
