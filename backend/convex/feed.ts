import { query } from "./_generated/server";
import { v } from "convex/values";

/** Reactive reads for the Swift app's Log and Agent pages and for the agent's own context. */

/** Everything for one local day: events plus runs with their tool calls and outcomes, newest first. */
export const day = query({
  args: { day: v.string() },
  handler: async (ctx, { day }) => {
    const events = await ctx.db.query("events").withIndex("by_day_ts", (q) => q.eq("day", day)).order("desc").take(1000);
    const runs = await ctx.db.query("agentRuns").withIndex("by_day_ts", (q) => q.eq("day", day)).order("desc").take(300);
    const calls = await ctx.db.query("toolCalls").withIndex("by_day_ts", (q) => q.eq("day", day)).collect();
    const outcomes = await ctx.db.query("outcomes").withIndex("by_day_ts", (q) => q.eq("day", day)).collect();
    const outcomeBy = new Map(outcomes.map((o) => [o.callLocalId, o]));
    const callsBy = new Map<number, unknown[]>();
    for (const c of calls) {
      const o = outcomeBy.get(c.localId);
      const row = { ...c, outcome: o ? { verdict: o.verdict, metric: o.metric, before: o.before, after: o.after } : null };
      callsBy.set(c.runLocalId, [...(callsBy.get(c.runLocalId) ?? []), row]);
    }
    const summary = await ctx.db.query("summaries").withIndex("by_day", (q) => q.eq("day", day)).unique();
    return {
      events,
      runs: runs.map(({ searchText, ...r }) => ({ ...r, calls: callsBy.get(r.localId) ?? [] })),
      summary: summary ? { text: summary.text, stats: summary.stats } : null,
    };
  },
});

/** Full-text search across a day's events and agent runs (Convex search indexes). */
export const search = query({
  args: { day: v.string(), q: v.string() },
  handler: async (ctx, { day, q }) => {
    if (!q.trim()) return { eventIds: [], runIds: [] };
    const events = await ctx.db.query("events").withSearchIndex("search_text", (s) => s.search("text", q).eq("day", day)).take(200);
    const runs = await ctx.db.query("agentRuns").withSearchIndex("search_text", (s) => s.search("searchText", q).eq("day", day)).take(100);
    return { eventIds: events.map((e) => e.localId), runIds: runs.map((r) => r.localId) };
  },
});

/** The last tool calls with their outcomes: the agent reads this so it learns what works for this person. */
export const recentActions = query({
  args: { limit: v.optional(v.number()) },
  handler: async (ctx, { limit }) => {
    const all = await ctx.db.query("toolCalls").order("desc").take(limit ?? 10);
    return Promise.all(all.reverse().map(async (c) => {
      const o = await ctx.db.query("outcomes").withIndex("by_call", (q) => q.eq("callLocalId", c.localId)).first();
      return {
        id: c.localId, ts: c.ts, tool: c.name, args: c.args, status: c.status,
        outcome: o ? { metric: o.metric, before: o.before ?? null, after: o.after ?? null, verdict: o.verdict }
          : c.status === "done" && c.targetMetric ? "pending" : null,
      };
    }));
  },
});
