import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

/**
 * eyeOS's agent memory and activity. The Python sidecar writes here as things happen; the Swift app subscribes
 * for the Log, Agent and Memory views; scheduled functions evaluate outcomes and crons keep things tidy.
 * Raw camera frames and screenshots never come here, only numbers and short text.
 *
 * `localId` ties a row to the sidecar's SQLite row (offline cache). `day` is the user's local YYYY-MM-DD.
 */
export default defineSchema({
  // Things the camera/metrics noticed: triggers, breaks, rubs, Zen start/end (+ recap), system events.
  events: defineTable({
    localId: v.number(),
    ts: v.number(),
    day: v.string(),
    kind: v.string(),
    triggerId: v.optional(v.string()),
    value: v.optional(v.number()),
    details: v.any(),
    text: v.string(), // flattened for search
  })
    .index("by_localId", ["localId"])
    .index("by_day_ts", ["day", "ts"])
    .searchIndex("search_text", { searchField: "text", filterFields: ["day"] }),

  // One agent wake-up (Claude or Codex): why it woke, what it said, what it cost.
  agentRuns: defineTable({
    localId: v.number(),
    tsStart: v.number(),
    tsEnd: v.optional(v.number()),
    day: v.string(),
    status: v.string(), // started | finished | error | abandoned
    triggers: v.any(),
    provider: v.optional(v.string()),
    model: v.optional(v.string()),
    text: v.optional(v.string()),
    thinking: v.optional(v.string()),
    inputTokens: v.optional(v.number()),
    outputTokens: v.optional(v.number()),
    error: v.optional(v.string()),
    searchText: v.string(),
  })
    .index("by_localId", ["localId"])
    .index("by_day_ts", ["day", "tsStart"])
    .index("by_status", ["status"])
    .searchIndex("search_text", { searchField: "searchText", filterFields: ["day"] }),

  // Every tool the agent asked for and what happened at the approval gate.
  toolCalls: defineTable({
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
    evaluationScheduled: v.optional(v.boolean()),
  })
    .index("by_localId", ["localId"])
    .index("by_run", ["runLocalId"])
    .index("by_day_ts", ["day", "ts"]),

  // Did the action help? Computed server-side by outcomes.evaluate, ~195 s after the action.
  outcomes: defineTable({
    callLocalId: v.number(),
    ts: v.number(),
    day: v.string(),
    tool: v.string(),
    metric: v.string(),
    before: v.optional(v.number()),
    after: v.optional(v.number()),
    verdict: v.string(),
  })
    .index("by_call", ["callLocalId"])
    .index("by_day_ts", ["day", "ts"]),

  // 1 Hz metric samples (numbers only), the input for outcome evaluation. Pruned after 48 h by a cron.
  samples: defineTable({
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
  }).index("by_ts", ["ts"]),

  // Rules the agent must follow (learned from declines, ask_user answers, or added by the user).
  preferences: defineTable({
    ts: v.number(),
    rule: v.string(),
    app: v.optional(v.string()),
    source: v.string(),
  }),

  approvals: defineTable({ tool: v.string(), state: v.string(), ts: v.number() }).index("by_tool", ["tool"]),

  // Coordination between the app, crons and the sidecar's agent: anyone enqueues, the sidecar claims and runs.
  jobs: defineTable({
    kind: v.string(), // run_agent | daily_summary | describe_screen
    args: v.any(),
    status: v.string(), // pending | claimed | done | failed
    source: v.string(), // app | cron | menu
    createdAt: v.number(),
    claimedAt: v.optional(v.number()),
    finishedAt: v.optional(v.number()),
    result: v.optional(v.any()),
  }).index("by_status", ["status", "createdAt"]),

  summaries: defineTable({ day: v.string(), ts: v.number(), text: v.string(), stats: v.any() }).index("by_day", ["day"]),
});
