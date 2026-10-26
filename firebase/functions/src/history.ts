// What each account uses, kept by the day so pricing and limits can follow real use (FEATURES.md
// §5.0.2). Counts and token sizes only, never what was asked or answered.
//
//   usage_history/{uid}              {tier, lastDay, expireAt}   (so the report can list accounts)
//   usage_history/{uid}/days/{day}   {tier, expireAt, quickAdd: {answers, failed, refused, promptTokens,
//                                     outputTokens, thoughtTokens}, ...}   day: UTC "2026-10-21"
//
// Both expire after [KEEP_DAYS] (Firestore TTL policies on expireAt, for the days and usage_history
// collection groups) and go with
// the account (forgetAccount).

import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { Feature } from "./prompts";

export const KEEP_DAYS = 400;

/** How a request ended: answered, failed after it was allowed, or refused by the allowance; with every try's tokens. */
export type Outcome =
  | { kind: "answered" | "failed"; promptTokens: number; outputTokens: number; thoughtTokens: number }
  | { kind: "refused" };

/** The day record's increments for one request (merged into the day's document). */
export function dayUpdate(feature: Feature, outcome: Outcome, tier: string, nowMs: number): Record<string, unknown> {
  const inc = FieldValue.increment;
  // Tokens count for every try Gemini billed, answered or not (cut off, broken), so costs add up
  const counts: Record<string, unknown> =
    outcome.kind === "refused"
      ? { refused: inc(1) }
      : {
        [outcome.kind === "answered" ? "answers" : "failed"]: inc(1),
        promptTokens: inc(outcome.promptTokens),
        outputTokens: inc(outcome.outputTokens),
        thoughtTokens: inc(outcome.thoughtTokens),
      };
  return {
    tier,
    expireAt: Timestamp.fromMillis(nowMs + KEEP_DAYS * 86_400_000),
    [feature]: counts,
  };
}

export function utcDay(nowMs: number): string {
  return new Date(nowMs).toISOString().slice(0, 10);
}
