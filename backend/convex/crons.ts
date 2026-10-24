import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";
import { internalMutation } from "./_generated/server";

/** Housekeeping and the evening summary, all server-side. */

export const pruneSamples = internalMutation({
  args: {},
  handler: async (ctx) => {
    const cutoff = Date.now() / 1000 - 48 * 3600; // samples only feed outcome evaluation; 48 h is plenty
    const old = await ctx.db.query("samples").withIndex("by_ts", (q) => q.lt("ts", cutoff)).take(4000);
    for (const s of old) await ctx.db.delete(s._id);
  },
});

export const closeStale = internalMutation({
  args: {},
  handler: async (ctx) => {
    const now = Date.now() / 1000;
    // runs the app quit in the middle of, and jobs a crashed sidecar claimed but never finished
    for (const r of await ctx.db.query("agentRuns").withIndex("by_status", (q) => q.eq("status", "started")).collect()) {
      if (now - r.tsStart > 15 * 60) await ctx.db.patch(r._id, { status: "abandoned", tsEnd: now });
    }
    for (const j of await ctx.db.query("jobs").withIndex("by_status", (q) => q.eq("status", "claimed")).collect()) {
      if (now - (j.claimedAt ?? j.createdAt) > 10 * 60) await ctx.db.patch(j._id, { status: "failed", result: "timed out" });
    }
  },
});

const crons = cronJobs();
crons.hourly("prune old samples", { minuteUTC: 7 }, internal.crons.pruneSamples, {});
crons.interval("close stale runs and jobs", { minutes: 10 }, internal.crons.closeStale, {});
// 04:00 UTC = 21:00 in California (PDT). The sidecar writes the summary for the user's local day.
crons.daily("evening summary", { hourUTC: 4, minuteUTC: 0 }, internal.jobs.enqueueDailySummary, {});
export default crons;
