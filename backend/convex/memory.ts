import { mutation, query } from "./_generated/server";
import { v } from "convex/values";

/** The rules the agent must follow. Written by the agent (save_user_preference), by declines, or by the user. */

export const list = query({
  args: {},
  handler: async (ctx) => (await ctx.db.query("preferences").collect()).sort((a, b) => a.ts - b.ts),
});

export const add = mutation({
  args: { rule: v.string(), app: v.optional(v.string()), source: v.string() },
  handler: async (ctx, a) => ctx.db.insert("preferences", { ...a, ts: Date.now() / 1000 }),
});

export const remove = mutation({
  args: { id: v.id("preferences") },
  handler: async (ctx, { id }) => ctx.db.delete(id),
});

export const approvals = query({
  args: {},
  handler: async (ctx) => Object.fromEntries((await ctx.db.query("approvals").collect()).map((a) => [a.tool, a.state])),
});
