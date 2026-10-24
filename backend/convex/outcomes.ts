import { internalMutation } from "./_generated/server";
import { v } from "convex/values";
import type { Doc } from "./_generated/dataModel";

/**
 * Did an action help? Scheduled by ingest.upsertToolCall ~195 s after the action ran. Compares the target metric
 * over the 2 min before the action with 15-195 s after it, using the 1 Hz samples. Same rules as the sidecar's
 * metrics.verdict(): blink rate needs a change of >= 2/min, others a 15 % relative change.
 */

const FIELD: Record<string, (s: Doc<"samples">) => number | undefined> = {
  blink_rate: (s) => s.blinkRate,
  distance_cm: (s) => s.distanceCm,
  squint_delta: (s) => s.squintDelta,
  perclos: (s) => s.perclos,
  incomplete_pct: (s) => s.incompletePct,
  yaw_deg: (s) => (s.yawDeg === undefined ? undefined : Math.abs(s.yawDeg)),
  gaze_on_screen_pct: (s) => (s.gazeOnScreen === undefined ? undefined : s.gazeOnScreen ? 1 : 0),
};
const BREAK_TOOLS = new Set(["suggest_look_out_window", "start_guided_eye_exercise"]);

const mean = (xs: number[]) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : undefined);

export function verdict(metric: string, before?: number, after?: number, faceFrac = 1): string {
  if (faceFrac < 0.5 || before === undefined || after === undefined) return "inconclusive";
  const upIsGood = metric === "blink_rate" || metric === "distance_cm";
  const delta = upIsGood ? after - before : before - after;
  if (metric === "blink_rate" && Math.abs(after - before) >= 2) return delta > 0 ? "improved" : "worse";
  const rel = before ? delta / Math.abs(before) : Math.sign(delta);
  return rel >= 0.15 ? "improved" : rel <= -0.15 ? "worse" : "neutral";
}

export const evaluate = internalMutation({
  args: { callLocalId: v.number(), doneAt: v.number() },
  handler: async (ctx, { callLocalId, doneAt }) => {
    const call = await ctx.db.query("toolCalls").withIndex("by_localId", (q) => q.eq("localId", callLocalId)).unique();
    if (!call || (await ctx.db.query("outcomes").withIndex("by_call", (q) => q.eq("callLocalId", callLocalId)).first())) return;
    const t = doneAt;
    const rows = await ctx.db.query("samples").withIndex("by_ts", (q) => q.gte("ts", t - 120).lte("ts", t + 195)).collect();
    let metric = call.targetMetric ?? "blink_rate";
    let before: number | undefined, after: number | undefined, result: string;
    if (BREAK_TOOLS.has(call.name)) {
      // a real break = the time-since-break counter reset after the suggestion
      metric = "since_real_break_s";
      const reset = rows.some((s) => s.ts > t && s.sinceBreakS !== undefined && s.sinceBreakS < s.ts - t);
      result = reset ? "confirmed_break" : "no_break";
    } else {
      const known = metric in FIELD;
      const get = FIELD[metric];
      const values = (xs: Doc<"samples">[]) => (known ? xs.map(get).filter((x): x is number => x !== undefined) : []);
      const postAll = rows.filter((s) => s.ts >= t + 15);
      before = mean(values(rows.filter((s) => s.ts < t && s.face)));
      after = mean(values(postAll.filter((s) => s.face)));
      const faceFrac = postAll.length ? postAll.filter((s) => s.face).length / postAll.length : 0;
      result = known ? verdict(metric, before, after, faceFrac) : "inconclusive";
    }
    await ctx.db.insert("outcomes", {
      callLocalId, ts: Date.now() / 1000, day: call.day, tool: call.name, metric, verdict: result,
      ...(before === undefined ? {} : { before: Math.round(before * 1000) / 1000 }),
      ...(after === undefined ? {} : { after: Math.round(after * 1000) / 1000 }),
    });
  },
});
