import { mutation } from "./_generated/server";
import { internal } from "./_generated/api";
import { v } from "convex/values";

/** Writes from the Python sidecar. Each upserts by `localId`, so retries and later status changes are safe. */

const OUTCOME_DELAY_MS = 195_000; // 15 s settle + 180 s observation window, same as the sidecar's old evaluator

function flatten(value: unknown): string {
  if (value === null || value === undefined) return "";
  if (typeof value === "object") return Object.values(value as Record<string, unknown>).map(flatten).join(" ");
  return String(value);
}

export const logEvent = mutation({
  args: {
    localId: v.number(),
    ts: v.number(),
    day: v.string(),
    kind: v.string(),
    triggerId: v.optional(v.string()),
    value: v.optional(v.number()),
    details: v.any(),
  },
  handler: async (ctx, a) => {
    const text = [a.kind, a.triggerId ?? "", flatten(a.details)].join(" ").replace(/_/g, " ");
    const existing = await ctx.db.query("events").withIndex("by_localId", (q) => q.eq("localId", a.localId)).unique();
    if (existing) await ctx.db.patch(existing._id, { ...a, text });
    else await ctx.db.insert("events", { ...a, text });
  },
});

export const upsertRun = mutation({
  args: {
    localId: v.number(),
    tsStart: v.number(),
    day: v.string(),
    status: v.string(),
    triggers: v.any(),
    tsEnd: v.optional(v.number()),
    provider: v.optional(v.string()),
    model: v.optional(v.string()),
    text: v.optional(v.string()),
    thinking: v.optional(v.string()),
    inputTokens: v.optional(v.number()),
    outputTokens: v.optional(v.number()),
    error: v.optional(v.string()),
  },
  handler: async (ctx, a) => {
    const ids = Array.isArray(a.triggers) ? a.triggers.map((t: { id?: string }) => t?.id ?? "").join(" ") : "";
    const searchText = [ids.replace(/_/g, " "), a.text ?? "", a.thinking ?? "", a.error ?? ""].join(" ");
    const existing = await ctx.db.query("agentRuns").withIndex("by_localId", (q) => q.eq("localId", a.localId)).unique();
    if (existing) await ctx.db.patch(existing._id, { ...a, searchText });
    else await ctx.db.insert("agentRuns", { ...a, searchText });
  },
});

export const upsertToolCall = mutation({
  args: {
    localId: v.number(),
    runLocalId: v.number(),
    ts: v.number(),
    day: v.string(),
    name: v.string(),
    args: v.any(),
    status: v.string(),
    tier: v.optional(v.string()),
    approval: v.optional(v.string()),
    result: v.optional(v.any()),
    targetMetric: v.optional(v.string()),
  },
  handler: async (ctx, a) => {
    const existing = await ctx.db.query("toolCalls").withIndex("by_localId", (q) => q.eq("localId", a.localId)).unique();
    let id = existing?._id;
    const { ts, ...rest } = a;
    if (existing) await ctx.db.patch(existing._id, rest); // keep the original request time
    else id = await ctx.db.insert("toolCalls", a);
    // Once an action with a target metric has run, schedule its before/after evaluation on the server.
    const row = (await ctx.db.get(id!))!;
    if (a.status === "done" && row.targetMetric && !row.evaluationScheduled) {
      await ctx.db.patch(row._id, { evaluationScheduled: true });
      await ctx.scheduler.runAfter(OUTCOME_DELAY_MS, internal.outcomes.evaluate, { callLocalId: a.localId, doneAt: Date.now() / 1000 });
    }
  },
});

const sample = v.object({
  ts: v.number(),
  face: v.boolean(),
  blinkRate: v.optional(v.number()),
  distanceCm: v.optional(v.number()),
  squintDelta: v.optional(v.number()),
  perclos: v.optional(v.number()),
  incompletePct: v.optional(v.number()),
  eyeScore: v.optional(v.number()),
  yawDeg: v.optional(v.number()),
  gazeOnScreen: v.optional(v.boolean()),
  sinceBreakS: v.optional(v.number()),
  postureIssues: v.optional(v.number()),
});

/** The sidecar batches its 1 Hz samples (every ~10 s). */
export const addSamples = mutation({
  args: { samples: v.array(sample) },
  handler: async (ctx, { samples }) => {
    for (const s of samples) await ctx.db.insert("samples", s);
  },
});

export const setApproval = mutation({
  args: { tool: v.string(), state: v.string() },
  handler: async (ctx, { tool, state }) => {
    const existing = await ctx.db.query("approvals").withIndex("by_tool", (q) => q.eq("tool", tool)).unique();
    if (existing) await ctx.db.patch(existing._id, { state, ts: Date.now() / 1000 });
    else await ctx.db.insert("approvals", { tool, state, ts: Date.now() / 1000 });
  },
});

export const upsertSummary = mutation({
  args: { day: v.string(), text: v.string(), stats: v.any() },
  handler: async (ctx, a) => {
    const existing = await ctx.db.query("summaries").withIndex("by_day", (q) => q.eq("day", a.day)).unique();
    if (existing) await ctx.db.patch(existing._id, { ...a, ts: Date.now() / 1000 });
    else await ctx.db.insert("summaries", { ...a, ts: Date.now() / 1000 });
  },
});
