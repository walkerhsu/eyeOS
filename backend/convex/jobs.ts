import { internalMutation, mutation, query } from "./_generated/server";
import { v } from "convex/values";

/**
 * A tiny work queue that coordinates the app, crons and the agent. Anyone enqueues (the Swift app's "Run now",
 * the daily-summary cron); the Python sidecar subscribes to `pending`, claims a job atomically and reports back.
 */

export const enqueue = mutation({
  args: { kind: v.string(), args: v.optional(v.any()), source: v.string() },
  handler: async (ctx, { kind, args, source }) => {
    // one pending job of a kind is enough (double-clicks, overlapping crons)
    const dup = (await ctx.db.query("jobs").withIndex("by_status", (q) => q.eq("status", "pending")).collect())
      .find((j) => j.kind === kind);
    if (dup) return dup._id;
    return ctx.db.insert("jobs", { kind, args: args ?? {}, status: "pending", source, createdAt: Date.now() / 1000 });
  },
});

export const pending = query({
  args: {},
  handler: async (ctx) => ctx.db.query("jobs").withIndex("by_status", (q) => q.eq("status", "pending")).take(20),
});

/** Atomic: returns true only for the first claimer. */
export const claim = mutation({
  args: { id: v.id("jobs") },
  handler: async (ctx, { id }) => {
    const j = await ctx.db.get(id);
    if (!j || j.status !== "pending") return false;
    await ctx.db.patch(id, { status: "claimed", claimedAt: Date.now() / 1000 });
    return true;
  },
});

export const finish = mutation({
  args: { id: v.id("jobs"), ok: v.boolean(), result: v.optional(v.any()) },
  handler: async (ctx, { id, ok, result }) =>
    ctx.db.patch(id, { status: ok ? "done" : "failed", result, finishedAt: Date.now() / 1000 }),
});

export const recent = query({
  args: {},
  handler: async (ctx) => ctx.db.query("jobs").order("desc").take(10),
});

export const enqueueDailySummary = internalMutation({
  args: {},
  handler: async (ctx) => {
    await ctx.db.insert("jobs", { kind: "daily_summary", args: {}, status: "pending", source: "cron", createdAt: Date.now() / 1000 });
  },
});
