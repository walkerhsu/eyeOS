import SwiftUI

/// Every agent run for the selected day: triggers, rationale, reasoning summary, tool calls and outcomes.
/// Source: agent_runs / tool_calls / outcomes in eyeos.db, loaded via history_request and kept live.
struct AgentBoard: View {
    @EnvironmentObject var store: Store
    @StateVar private var tool = "All tools"
    @StateVar private var showReasoning = true

    private var runs: [RunRow] {
        store.runs.values
            .filter { tool == "All tools" || $0.calls.values.contains { $0.str("name") == tool } }
            .sorted { $0.ts > $1.ts }
    }

    private var allCalls: [J] { store.runs.values.flatMap { $0.calls.values } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                DatePicker("", selection: $store.logDay, displayedComponents: .date).labelsHidden().frame(width: 130)
                Picker("", selection: $tool) {
                    Text("All tools").tag("All tools")
                    ForEach(Set(allCalls.compactMap { $0.str("name") }).sorted(), id: \.self) { Text($0).tag($0) }
                }.frame(width: 240)
                Toggle("Reasoning summaries", isOn: $showReasoning).toggleStyle(.switch).controlSize(.small)
                Spacer()
                Button { store.sidecar.command("run_agent_now") } label: { Label("Run agent now", systemImage: "play.fill") }
            }
            stats
            scoreboard
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(runs) { RunCard(run: $0, showReasoning: showReasoning) }
                    if runs.isEmpty {
                        Text("No agent runs on this day yet.").foregroundStyle(.secondary).padding(40)
                    }
                }
            }
        }
        .padding(16)
        .navigationTitle("Agent")
        .onChange(of: store.logDay) { store.loadDay() }
    }

    var stats: some View {
        let rs = Array(store.runs.values)
        let lat = rs.compactMap(\.latency)
        let done = allCalls.filter { $0.str("status") == "done" }.count
        let asked = allCalls.filter { ["approved", "declined", "timeout"].contains($0.str("approval") ?? "") }
        let verdicts = store.outcomes.values.compactMap { $0.str("verdict") }
        let good = verdicts.filter { ["improved", "confirmed_break"].contains($0) }.count
        return HStack(spacing: 10) {
            stat("Runs", "\(rs.count)", sub: "\(rs.filter { $0.status == "error" }.count) errors")
            stat("Tool calls", "\(allCalls.count)", sub: "\(done) executed")
            stat("Approvals", "\(asked.filter { $0.str("approval") == "approved" }.count)/\(asked.count)", sub: "allowed")
            stat("Outcomes", "\(good)/\(verdicts.count)", sub: "helped")
            stat("Latency", lat.isEmpty ? "–" : fmt(lat.reduce(0, +) / Double(lat.count), 1, suffix: " s"), sub: "mean")
            stat("Tokens", "\(rs.compactMap(\.inputTokens).reduce(0, +) / 1000)k", sub: "\(rs.compactMap(\.outputTokens).reduce(0, +)) out")
        }
    }

    func stat(_ title: String, _ value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
            Text(sub).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.5, opacity: 0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Per-tool tally: how often each tool ran and how its outcomes came out.
    var scoreboard: some View {
        let byTool = Dictionary(grouping: allCalls) { $0.str("name") ?? "?" }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(byTool.keys.sorted(), id: \.self) { name in
                    let calls = byTool[name] ?? []
                    let vs = calls.compactMap { $0.int("id").flatMap { store.outcomes[$0]?.str("verdict") } }
                    HStack(spacing: 6) {
                        Image(systemName: toolIcons[name] ?? "wrench").foregroundStyle(.teal)
                        Text(name).font(.caption.monospaced())
                        Text("×\(calls.count)").font(.caption.bold())
                        if !vs.isEmpty {
                            Text("\(vs.filter { ["improved", "confirmed_break"].contains($0) }.count)✓ \(vs.filter { ["worse", "no_break"].contains($0) }.count)✗")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(tool == name ? Color.teal.opacity(0.25) : Color(white: 0.5, opacity: 0.08), in: Capsule())
                    .onTapGesture { tool = tool == name ? "All tools" : name }
                }
            }
        }
    }
}

private struct RunCard: View {
    @EnvironmentObject var store: Store
    let run: RunRow
    let showReasoning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(clock(run.ts)).font(.callout.monospacedDigit().weight(.semibold))
                ForEach(Array(run.triggers.enumerated()), id: \.offset) { _, t in
                    Text(t.str("id") ?? "").font(.caption).padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.gray.opacity(0.2), in: Capsule())
                }
                Spacer()
                if run.status == "started" { ProgressView().controlSize(.small) }
                Text(run.status).font(.caption).foregroundStyle(run.status == "error" ? .red : .secondary)
                Text("\(fmt(run.latency, 1)) s · \(run.inputTokens ?? 0)/\(run.outputTokens ?? 0) tok")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
            if !run.texts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(run.texts.enumerated()), id: \.offset) { _, t in Text(t).textSelection(.enabled) }
                }
            } else if run.status != "started" && run.calls.isEmpty {
                Text("No rationale recorded.").font(.caption).foregroundStyle(.secondary)
            }
            if showReasoning && !run.thinking.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Reasoning summary", systemImage: "brain").font(.caption.weight(.semibold)).foregroundStyle(.purple)
                    Text(run.thinking.joined(separator: "\n\n")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(Array(run.sortedCalls.enumerated()), id: \.offset) { _, c in ToolCallRow(c: c) }
            if let e = run.error { Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding(12)
        .background(Color(white: 0.5, opacity: 0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(run.status == "error" ? .red.opacity(0.4) : .white.opacity(0.06)))
    }
}
