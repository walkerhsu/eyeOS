import Charts
import SwiftUI

private enum FeedItem: Identifiable {
    case event(J), run(RunRow)
    var id: String {
        switch self {
        case .event(let e): "e\(e.int("id") ?? Int((e.num("ts") ?? 0) * 1000))"
        case .run(let r): "r\(r.id)"
        }
    }
    var ts: Double {
        switch self { case .event(let e): e.num("ts") ?? 0; case .run(let r): r.ts }
    }
}

struct LogView: View {
    @EnvironmentObject var store: Store
    @StateVar private var filters: Set<String> = ["Events", "Runs", "Actions", "Errors"]
    @StateVar private var search = ""
    @StateVar private var range: ClosedRange<Date>?
    @StateVar private var expanded: Set<Int> = []
    @StateVar private var summarizing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Timeline(range: $range).frame(height: 240)
            filterBar
            feed
        }
        .padding(16)
        .navigationTitle("Log")
        .onChange(of: store.logDay) { store.loadDay() }
        .onChange(of: store.summary?.str("text")) { summarizing = false }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                DatePicker("", selection: $store.logDay, displayedComponents: .date).labelsHidden().frame(width: 130)
                Button { summarizing = true; store.sidecar.command("generate_summary", ["date": store.dayString]) } label: {
                    Label("Daily summary", systemImage: "text.badge.star")
                }
                if summarizing { ProgressView().controlSize(.small) }
                Spacer()
                if range != nil { Button("Clear selection") { range = nil } }
            }
            if let text = store.summary?.str("text") {
                Text(text).font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    var filterBar: some View {
        HStack {
            ForEach(["Events", "Runs", "Actions", "Errors"], id: \.self) { f in
                Toggle(f, isOn: Binding(get: { filters.contains(f) }, set: { if $0 { filters.insert(f) } else { filters.remove(f) } }))
                    .toggleStyle(.button)
            }
            Spacer()
            TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
        }
    }

    private var items: [FeedItem] {
        let q = search.lowercased()
        var out: [FeedItem] = []
        if filters.contains("Events") || filters.contains("Errors") {
            for e in store.events {
                let isErr = e.str("kind") == "system" && (e.obj("details")?.str("event") ?? "").contains("error")
                if isErr ? filters.contains("Errors") : filters.contains("Events") { out.append(.event(e)) }
            }
        }
        for r in store.runs.values {
            let isErr = r.status == "error"
            let hasAction = !r.calls.isEmpty
            if (filters.contains("Runs")) || (filters.contains("Actions") && hasAction) || (filters.contains("Errors") && isErr) {
                out.append(.run(r))
            }
        }
        return out.filter { item in
            if let range {
                let d = Date(timeIntervalSince1970: item.ts)
                if !range.contains(d) { return false }
            }
            guard !q.isEmpty else { return true }
            switch item {
            case .event(let e): return "\(e.str("kind") ?? "") \(e.str("trigger_id") ?? "") \(e.obj("details") ?? [:])".lowercased().contains(q)
            case .run(let r):
                return (r.texts + r.thinking + r.triggers.compactMap { $0.str("id") } + r.calls.values.compactMap { $0.str("name") })
                    .joined(separator: " ").lowercased().contains(q)
            }
        }.sorted { $0.ts > $1.ts }
    }

    var feed: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(items) { item in
                    switch item {
                    case .event(let e): EventRow(e: e).id(item.id)
                    case .run(let r):
                        RunRowView(run: r, expanded: Binding(get: { expanded.contains(r.id) },
                                                             set: { if $0 { expanded.insert(r.id) } else { expanded.remove(r.id) } }))
                            .id(item.id)
                    }
                }
            }
            .listStyle(.inset)
            .onChange(of: range) {
                // clicking/brushing the chart jumps the feed to that moment and opens the run there
                if let first = items.first {
                    if case .run(let r) = first { expanded.insert(r.id) }
                    withAnimation { proxy.scrollTo(first.id, anchor: .top) }
                }
            }
        }
    }
}

struct EventRow: View {
    let e: J
    var body: some View {
        HStack(spacing: 10) {
            Text(clock(e.num("ts"))).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Image(systemName: icon).foregroundStyle(color).frame(width: 18)
            Text(title).font(.callout)
            if let v = e.num("value") { Text(fmt(v, v < 1 ? 2 : 1)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            Spacer()
        }
    }
    var title: String {
        switch e.str("kind") {
        case "trigger": "Trigger · \(e.str("trigger_id") ?? "")"
        case "break": "Real break"
        case "rub": "Eye rub"
        case "yawn": "Yawn"
        case "blink_anomaly": e.obj("details")?.str("event") == "eyes_closed" ? "Eyes closed" : "Long blink"
        default: "System · \(e.obj("details")?.str("event") ?? "")"
        }
    }
    var icon: String {
        switch e.str("kind") {
        case "trigger": "bolt.fill"; case "break": "figure.walk"; case "rub": "hand.raised.fill"; case "yawn": "mouth"
        case "blink_anomaly": "eye.slash"; default: "gearshape"
        }
    }
    var color: Color { e.str("kind") == "trigger" ? .gray : e.str("kind") == "break" ? .green : .orange }
}

struct RunRowView: View {
    @EnvironmentObject var store: Store
    let run: RunRow
    @Binding var expanded: Bool
    @StateVar private var showThinking = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if !run.thinking.isEmpty {
                    DisclosureGroup("Thinking", isExpanded: $showThinking) {
                        Text(run.thinking.joined(separator: "\n\n")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                ForEach(Array(run.texts.enumerated()), id: \.offset) { _, t in
                    Text(t).font(.callout).textSelection(.enabled)
                }
                ForEach(Array(run.sortedCalls.enumerated()), id: \.offset) { _, c in ToolCallRow(c: c) }
                if let err = run.error { Text(err).font(.caption).foregroundStyle(.red) }
                Text("tokens \(run.inputTokens ?? 0) in · \(run.outputTokens ?? 0) out · \(fmt(run.latency, 1)) s")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.leading, 8)
        } label: {
            HStack(spacing: 10) {
                Text(clock(run.ts)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                Circle().fill(run.status == "error" ? .red : .purple).frame(width: 9, height: 9).frame(width: 18)
                Text("Agent · " + run.triggers.compactMap { $0.str("id") }.joined(separator: ", ")).font(.callout.weight(.medium))
                if run.status == "started" { ProgressView().controlSize(.mini) }
                ForEach(Array(run.sortedCalls.enumerated()), id: \.offset) { _, c in
                    Image(systemName: toolIcons[c.str("name") ?? ""] ?? "wrench").foregroundStyle(statusColor(c.str("status")))
                }
                Spacer()
            }
        }
    }
}

func statusColor(_ s: String?) -> Color {
    switch s {
    case "done": .green
    case "failed": .red
    case "declined", "blocked_tier", "blocked_suppressed": .gray
    case "awaiting_approval": .orange
    default: .blue
    }
}

struct ToolCallRow: View {
    @EnvironmentObject var store: Store
    let c: J
    var body: some View {
        let outcome = c.int("id").flatMap { store.outcomes[$0] }
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: toolIcons[c.str("name") ?? ""] ?? "wrench")
                Text(c.str("name") ?? "").font(.callout.monospaced())
                Text(c.str("status") ?? "").font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(statusColor(c.str("status")).opacity(0.2), in: Capsule())
                if let a = c.str("approval"), a != "never_asked" { Text(a).font(.caption2).foregroundStyle(.secondary) }
                if let v = outcome?.str("verdict") { VerdictBadge(verdict: v) }
            }
            Text(argString).font(.caption.monospaced()).foregroundStyle(.secondary)
            if let r = c["result"], !(r is NSNull) { Text("→ \(String(describing: r))").font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            if let o = outcome, let m = o.str("metric") {
                Text("\(m): \(fmt(o.num("before"), 2)) → \(fmt(o.num("after"), 2))").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(Color(white: 0.5, opacity: 0.06), in: RoundedRectangle(cornerRadius: 8))
    }
    var argString: String {
        guard let a = c["args"], let d = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys]) else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }
}

struct VerdictBadge: View {
    let verdict: String
    var body: some View {
        let good = ["improved", "confirmed_break"].contains(verdict), bad = ["worse", "no_break"].contains(verdict)
        Text(verdict.replacingOccurrences(of: "_", with: " ")).font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background((good ? Color.green : bad ? .red : .gray).opacity(0.25), in: Capsule())
    }
}

/// Day timeline: metric lines sharing one x-axis + trigger / run / tool markers (SPEC §11.2).
struct Timeline: View {
    @EnvironmentObject var store: Store
    @Binding var range: ClosedRange<Date>?
    @StateVar private var selection: ClosedRange<Date>?

    var body: some View {
        let rows = store.chartMetrics
        VStack(spacing: 4) {
            series("Blink rate /min", rows, "blink_rate", .teal, markers: true)
            series("PERCLOS", rows, "perclos", .purple)
            series("Distance cm", rows, "distance_cm", .orange)
        }
    }

    func series(_ title: String, _ rows: [J], _ key: String, _ color: Color, markers: Bool = false) -> some View {
        Chart {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                if let v = r.num(key), let ts = r.num("ts") {
                    LineMark(x: .value("t", Date(timeIntervalSince1970: ts)), y: .value(title, v)).foregroundStyle(color)
                        .interpolationMethod(.monotone)
                }
            }
            if markers {
                ForEach(Array(store.events.filter { $0.str("kind") == "trigger" }.enumerated()), id: \.offset) { _, e in
                    RuleMark(x: .value("t", Date(timeIntervalSince1970: e.num("ts") ?? 0))).foregroundStyle(.gray.opacity(0.35))
                        .lineStyle(.init(lineWidth: 1))
                }
                ForEach(Array(store.runs.values), id: \.id) { r in
                    PointMark(x: .value("t", Date(timeIntervalSince1970: r.ts)), y: .value(title, 0)).foregroundStyle(.purple)
                        .symbolSize(30)
                    ForEach(Array(r.sortedCalls.enumerated()), id: \.offset) { i, c in
                        PointMark(x: .value("t", Date(timeIntervalSince1970: c.num("ts") ?? r.ts + 1)), y: .value(title, 2 + Double(i) * 2))
                            .foregroundStyle(statusColor(c.str("status")))
                            .symbol { Image(systemName: toolIcons[c.str("name") ?? ""] ?? "wrench").font(.caption2)
                                .foregroundStyle(statusColor(c.str("status"))) }
                            .annotation(position: .top) {
                                if let v = c.int("id").flatMap({ store.outcomes[$0]?.str("verdict") }) {
                                    Circle().fill(["improved", "confirmed_break"].contains(v) ? .green : .gray).frame(width: 5)
                                }
                            }
                    }
                }
            }
            if let s = selection {
                RectangleMark(xStart: .value("a", s.lowerBound), xEnd: .value("b", s.upperBound)).foregroundStyle(.teal.opacity(0.12))
            }
        }
        .chartXScale(domain: dayDomain)
        .chartYAxis { AxisMarks(position: .leading) }
        .chartLegend(.hidden)
        .chartOverlay { _ in Text(title).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing) }
        .chartXSelection(range: $selection)
        .onChange(of: selection) { if let s = selection { range = s } }
    }

    var dayDomain: ClosedRange<Date> {
        let start = store.logDay
        let times = store.chartMetrics.compactMap { $0.num("ts") } + store.runs.values.map(\.ts)
        guard let lo = times.min(), let hi = times.max(), hi > lo else { return start...start.addingTimeInterval(86400) }
        return Date(timeIntervalSince1970: lo - 60)...Date(timeIntervalSince1970: hi + 60)
    }
}
