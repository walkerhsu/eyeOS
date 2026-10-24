import SwiftUI

/// Every agent run for the selected day: triggers, rationale, reasoning summary, tool calls and outcomes.
/// Source: agent_runs / tool_calls / outcomes in eyeos.db, loaded via history_request and kept live.
struct AgentBoard: View {
    @EnvironmentObject var store: Store
    @StateVar private var tool = "All tools"
    @StateVar private var showReasoning = false

    private var runs: [RunRow] {
        store.runs.values
            .filter { tool == "All tools" || $0.calls.values.contains { $0.str("name") == tool } }
            .sorted { $0.ts > $1.ts }
    }

    private var allCalls: [J] { store.runs.values.flatMap { $0.calls.values } }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                AppBar(title: "Agent", subtitle: store.isToday ? "Today" : store.logDay.formatted(.dateTime.weekday(.wide).month().day())) {
                    DatePicker("", selection: $store.logDay, displayedComponents: .date).labelsHidden().frame(width: 120)
                    Button { store.sidecar.command("run_agent_now") } label: {
                        Label("Run now", systemImage: store.status.bool("agent_busy") ? "hourglass" : "play.fill")
                    }
                    .controlSize(.large)
                    .disabled(!store.agentAvailable || store.status.bool("agent_busy"))
                    .help(store.agentAvailable ? "Run the agent once with the current signals" : "\(store.agentMissing) (see Settings)")
                }
                stats
                HStack(spacing: 12) {
                    scoreboard
                    Spacer(minLength: 8)
                    Toggle("Expand reasoning", isOn: $showReasoning).toggleStyle(.switch).controlSize(.small)
                }
                ForEach(runs) { RunCard(run: $0, showReasoning: showReasoning).id("\($0.id)-\(showReasoning)") }
                if runs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "brain").font(.system(size: 28)).foregroundStyle(.tertiary)
                        Text(tool == "All tools" ? "No agent runs on this day yet." : "No runs used \(toolPhrase(tool).lowercased()).")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(20)
        }
        .onChange(of: store.logDay) { store.loadDay() }
    }

    var stats: some View {
        let rs = Array(store.runs.values)
        let lat = rs.compactMap(\.latency)
        let done = allCalls.filter { $0.str("status") == "done" }.count
        let asked = allCalls.filter { ["approved", "declined", "timeout"].contains($0.str("approval") ?? "") }
        let verdicts = store.outcomes.values.compactMap { $0.str("verdict") }
        let good = verdicts.filter { isGoodVerdict($0) }.count
        let errors = rs.filter { $0.status == "error" }.count
        return HStack(spacing: 10) {
            stat("Runs", "\(rs.count)", sub: errors == 0 ? "no errors" : "\(errors) errors", icon: "brain", color: .purple, Explain.runs)
            stat("Tool calls", "\(allCalls.count)", sub: "\(done) executed", icon: "wrench.and.screwdriver", color: .teal, Explain.toolCalls)
            stat("Approvals", "\(asked.filter { $0.str("approval") == "approved" }.count)/\(asked.count)", sub: "allowed",
                 icon: "hand.raised", color: .orange, Explain.approvals)
            stat("Outcomes", "\(good)/\(verdicts.count)", sub: "helped", icon: "checkmark.seal", color: .green, Explain.outcomes)
            stat("Latency", lat.isEmpty ? "–" : fmt(lat.reduce(0, +) / Double(lat.count), 1, suffix: " s"), sub: "mean per run",
                 icon: "stopwatch", color: .blue, Explain.latency)
            stat("Tokens", "\(rs.compactMap(\.inputTokens).reduce(0, +) / 1000)k", sub: "\(rs.compactMap(\.outputTokens).reduce(0, +)) out",
                 icon: "text.word.spacing", color: .indigo, Explain.tokens)
        }
    }

    func stat(_ title: String, _ value: String, sub: String, icon: String, color: Color, _ e: Explainer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
            Text(sub).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 12)
        .explain(e)
    }

    /// Per-tool tally: how often each tool ran and how its outcomes came out. Click to filter.
    var scoreboard: some View {
        let byTool = Dictionary(grouping: allCalls) { $0.str("name") ?? "?" }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(byTool.keys.sorted(), id: \.self) { name in
                    let calls = byTool[name] ?? []
                    ToolChip(name: name, uses: calls.count,
                             verdicts: calls.compactMap { $0.int("id").flatMap { store.outcomes[$0]?.str("verdict") } },
                             selected: tool == name) { tool = tool == name ? "All tools" : name }
                }
            }
        }
    }
}

private struct ToolChip: View {
    let name: String
    let uses: Int
    let verdicts: [String]
    let selected: Bool
    let tap: () -> Void

    var body: some View {
        let helped = verdicts.filter { isGoodVerdict($0) }.count
        HStack(spacing: 6) {
            Image(systemName: toolIcons[name] ?? "wrench").foregroundStyle(.teal)
            Text(toolPhrase(name)).font(.caption)
            Text("×\(uses)").font(.caption.bold())
            if !verdicts.isEmpty { Text("\(helped)/\(verdicts.count) helped").font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(selected ? Color.teal.opacity(0.25) : Color.white.opacity(0.05), in: Capsule())
        .overlay(Capsule().strokeBorder(selected ? Color.teal.opacity(0.6) : Color.white.opacity(0.08)))
        .contentShape(Capsule())
        .onTapGesture(perform: tap)
        .explain(Explainer(title: toolPhrase(name),
                           meaning: "How often the agent used \(name) on this day, and how often it measurably helped. Click to show only those runs.",
                           math: "uses = tool calls named \(name)\nhelped = verdict improved / confirmed_break ÷ evaluated calls"))
    }
}

/// Decision card: the first sentence is the headline, the rest renders as markdown, then actions and reasoning.
private struct RunCard: View {
    @EnvironmentObject var store: Store
    let run: RunRow
    let showReasoning: Bool

    var body: some View {
        let err = run.status == "error"
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(clock(run.ts).prefix(5)).font(.callout.monospacedDigit().weight(.semibold))
                ForEach(Array(run.triggers.enumerated()), id: \.offset) { _, t in
                    let id = t.str("id") ?? ""
                    HStack(spacing: 4) {
                        Image(systemName: id == "manual" ? "hand.tap.fill" : id == "heartbeat" ? "clock" : "bolt.fill").font(.caption2)
                        Text(id == "manual" ? "Manual run" : humanize(id))
                        if let v = triggerValue(id, t.num("value")) { Text(v).foregroundStyle(.secondary) }
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.yellow.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.yellow.opacity(0.9))
                }
                Spacer()
                if run.status == "started" {
                    Pill(text: "Thinking", color: .purple, spinning: true)
                } else {
                    Pill(text: err ? "Error" : "Finished", icon: err ? "exclamationmark.triangle.fill" : "checkmark",
                         color: err ? .pink : .secondary)
                }
                Text("\(fmt(run.latency, 1)) s · \(run.inputTokens ?? 0)/\(run.outputTokens ?? 0) tok")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
            DecisionContent(run: run, showReasoning: showReasoning, headline: true)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(err ? Color.pink.opacity(0.45) : Color.white.opacity(0.08)))
    }
}
