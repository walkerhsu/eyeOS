import Charts
import SwiftUI

enum FeedItem: Identifiable {
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

private enum LogFilter: Hashable { case all, events, agent, actions, errors }

private func isErrorEvent(_ e: J) -> Bool {
    e.str("kind") == "system" && (e.obj("details")?.str("event") ?? "").contains("error")
}

struct LogView: View {
    @EnvironmentObject var store: Store
    @StateVar private var filter: LogFilter = .all
    @StateVar private var search = ""
    @StateVar private var range: ClosedRange<Date>?
    @StateVar private var expanded: Set<Int> = []
    @StateVar private var summarizing = false

    var body: some View {
        let all = allItems
        let shown = all.filter { matches($0, filter) }
        VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 12) {
            AppBar(title: "Log", subtitle: dayLabel) { dayControls }
            // the day chart stays put: brushing it scrolls the feed below, never the chart itself
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionTitle(text: "Day at a glance", icon: "chart.xyaxis.line")
                    Spacer()
                    if let r = range {
                        Text("\(r.lowerBound.formatted(date: .omitted, time: .shortened)) – \(r.upperBound.formatted(date: .omitted, time: .shortened))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.teal)
                        Button { range = nil } label: { Label("Clear", systemImage: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                    } else {
                        Text("Drag across the chart (or click) to jump to that time").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Timeline(range: $range).frame(height: 170)
            }
            .card(padding: 14)
        }
        .padding(.horizontal, 20).padding(.top, 20)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                    if let text = store.summary?.str("text") { summaryCard(text) }
                    Section {
                        ForEach(shown) { item in
                            switch item {
                            case .event(let e): EventCard(e: e).id(item.id)
                            case .run(let r):
                                RunLogCard(run: r, expanded: Binding(get: { expanded.contains(r.id) },
                                                                     set: { if $0 { expanded.insert(r.id) } else { expanded.remove(r.id) } }))
                                    .id(item.id)
                            }
                        }
                        if shown.isEmpty { empty }
                    } header: {
                        filterBar(all).padding(.vertical, 8).background(.background)
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
            .onChange(of: range) {
                // brushing the chart jumps the feed to that moment and opens the run there
                if let first = allItems.first(where: { matches($0, filter) }) {
                    if case .run(let r) = first { expanded.insert(r.id) }
                    withAnimation { proxy.scrollTo(first.id, anchor: .top) }
                }
            }
        }
        }
        .onChange(of: store.logDay) { store.loadDay() }
        .onChange(of: store.summary?.str("text")) { summarizing = false }
    }

    var dayLabel: String {
        store.isToday ? "Today" : store.logDay.formatted(.dateTime.weekday(.wide).month().day())
    }

    @ViewBuilder var dayControls: some View {
        DatePicker("", selection: $store.logDay, displayedComponents: .date).labelsHidden().frame(width: 120)
        Button { summarizing = true; store.sidecar.command("generate_summary", ["date": store.dayString]) } label: {
            HStack(spacing: 6) {
                if summarizing { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") }
                Text("Daily summary")
            }
        }
        .controlSize(.large)
        .disabled(summarizing || !store.agentAvailable)
        .help(store.agentAvailable ? "Ask the agent to summarize this day" : "Needs an agent provider (see Settings)")
    }

    func summaryCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles").font(.system(size: 14, weight: .semibold)).foregroundStyle(.teal)
                .frame(width: 30, height: 30).background(Color.teal.opacity(0.16), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text("Daily summary").font(.caption.weight(.semibold)).foregroundStyle(.teal)
                MarkdownText(text: text, font: .callout)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 14, accent: .teal)
    }

    func filterBar(_ all: [FeedItem]) -> some View {
        let n = { (f: LogFilter) in all.filter { matches($0, f, ignoringSearch: true) }.count }
        return HStack(spacing: 12) {
            CountSegmented(options: [
                (LogFilter.all, "All", "square.stack.3d.up", n(.all), Color.primary),
                (.events, "Events", "bolt.fill", n(.events), .teal),
                (.agent, "Agent", "brain", n(.agent), .purple),
                (.actions, "Actions", "hand.tap.fill", n(.actions), .green),
                (.errors, "Errors", "exclamationmark.triangle.fill", n(.errors), .pink),
            ], selection: $filter)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(width: 220)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.08)))
        }
    }

    var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: filter == .errors ? "checkmark.seal" : "tray").font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(filter == .errors ? "No errors. Nice." : search.isEmpty ? "Nothing logged here yet." : "No matches for \"\(search)\".")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(40)
    }

    private var allItems: [FeedItem] {
        (store.events.map { FeedItem.event($0) } + store.runs.values.map { FeedItem.run($0) }).sorted { $0.ts > $1.ts }
    }

    private func matches(_ item: FeedItem, _ f: LogFilter, ignoringSearch: Bool = false) -> Bool {
        let inFilter: Bool
        switch (item, f) {
        case (_, .all): inFilter = true
        case (.event(let e), .events): inFilter = !isErrorEvent(e)
        case (.event(let e), .errors): inFilter = isErrorEvent(e)
        case (.run, .agent): inFilter = true
        case (.run(let r), .actions): inFilter = !r.calls.isEmpty
        case (.run(let r), .errors): inFilter = r.status == "error"
        default: inFilter = false
        }
        guard inFilter else { return false }
        if let range, !range.contains(Date(timeIntervalSince1970: item.ts)) { return false }
        let q = search.lowercased()
        guard !ignoringSearch, !q.isEmpty else { return true }
        switch item {
        case .event(let e): return "\(e.str("kind") ?? "") \(e.str("trigger_id") ?? "") \(e.obj("details") ?? [:])".lowercased().contains(q)
        case .run(let r):
            return (r.texts + r.thinking + r.triggers.compactMap { $0.str("id") } + r.calls.values.compactMap { $0.str("name") })
                .joined(separator: " ").lowercased().contains(q)
        }
    }
}

/// The shared card shell for Log rows: tinted icon badge, title + subtitle, trailing time / value.
private struct LogCardShell<Trailing: View, Detail: View>: View {
    let icon: String
    let color: Color
    var spinning = false
    let title: String
    let subtitle: String?
    var accent: Color? = nil
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    if spinning { ProgressView().controlSize(.small) } else {
                        Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
                    }
                }
                .frame(width: 34, height: 34).background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            detail
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(accent?.opacity(0.45) ?? Color.white.opacity(0.07)))
    }
}

private struct TimeLabel: View {
    let ts: Double?
    var body: some View {
        Text(clock(ts).prefix(5)).font(.caption.monospacedDigit().weight(.medium)).foregroundStyle(.secondary)
            .help(clock(ts))
    }
}

struct EventCard: View {
    let e: J
    @StateVar private var expanded = false

    var highlights: [J] {
        let d = e.obj("details") ?? [:]
        if let rules = d["rules"] as? [String] {  // a reflection: the rules it learned, plus what to try next
            return rules.map { ["icon": "brain.head.profile", "text": $0, "level": "warn"] }
                + (d.str("try_next").map { [["icon": "lightbulb", "text": "Try: " + $0, "level": "good"]] } ?? [])
        }
        return d.obj("recap")?.arr("highlights") ?? []
    }

    var body: some View {
        LogCardShell(icon: icon, color: color, title: title, subtitle: subtitle,
                     accent: isErrorEvent(e) ? .pink : expanded ? color : nil) {
            if let v = valueText {
                Text(v).font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(color.opacity(0.14), in: Capsule()).foregroundStyle(color)
            }
            TimeLabel(ts: e.num("ts")).frame(width: 40, alignment: .trailing)
            if !highlights.isEmpty {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        } detail: {
            if expanded { ZenHighlights(items: highlights).padding(.top, 10).padding(.leading, 46) }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !highlights.isEmpty { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } }
    }

    var event: String { e.obj("details")?.str("event") ?? "" }
    var value: Double? { e.num("value") }

    var title: String {
        switch e.str("kind") {
        case "trigger": humanize(e.str("trigger_id") ?? "trigger")
        case "break": "Real break"
        case "rub": "Eye rub"
        case "touch": "Hands at your eyes"
        case "lash_pull": "Hands at your lashes"
        case "yawn": "Yawn"
        case "blink_anomaly": event == "eyes_closed" ? "Eyes closed" : "Long blink"
        case "zen": event == "zen_start" ? "Zen started" : "Zen ended"
        default:
            switch event {
            case "situation": "Now: " + humanize(e.obj("details")?.str("situation") ?? "")
            case "deferred": "Held a nudge"
            case "reflection": "Reflection"
            case "habit_swap": e.obj("details")?.bool("accepted") == true ? "Swapped for palming" : "Offered palming"
            case "zoom_offer": e.obj("details")?.bool("accepted") == true ? "Made text bigger" : "Offered bigger text"
            case _ where isCalibration: "Calibration · " + humanize(calibrationStep)
            default: humanize(event.isEmpty ? "system" : event)
            }
        }
    }

    var subtitle: String {
        let d = e.obj("details") ?? [:]
        switch e.str("kind") {
        case "trigger": return "Signal crossed its threshold" + (d.bool("zen") ? " · held back during Zen" : "")
                + (d.bool("demo") ? " · demo" : "")
        case "break": return value.map { "Looked away for \(duration($0))" } ?? "Looked away from the screen"
        case "rub": return "Fingertips stayed near your eyes"
        case "touch": return "Fingers at a closing eye; a soft cue to notice it"
        case "lash_pull": return "Thumb and finger pinched at your lash line"
        case "yawn": return "A sign you may be getting tired"
        case "blink_anomaly": return value.map { "Lasted \(fmt($0, 1)) s" } ?? ""
        case "zen":
            if event == "zen_start" { return d.str("source") == "manual" ? "You started Zen" : "Deep focus detected" }
            var parts = [value.map { "\(duration($0)) of quiet focus" } ?? "Quiet focus"]
            if let r = d.obj("recap") {
                if let n = r.int("alerts_held_total"), n > 0 { parts.append("\(n) alert\(n == 1 ? "" : "s") held") }
                if let c = r.int("blink_change_pct"), c <= -10 { parts.append("blinks \(c)%") }
                if let n = r.int("rubs"), n > 0 { parts.append("\(n) rub\(n == 1 ? "" : "s")") }
            }
            return parts.joined(separator: " · ")
        default:
            if isCalibration {
                switch event {
                case "calibration": return "Done · baseline updated"
                case "calibration_weak": return "Saved, but may be off · " + ((d["warnings"] as? [String]) ?? []).joined(separator: " ")
                case "calibration_interrupted": return "Interrupted · " + (d.str("reason") ?? "")
                case "calibration_error": return "Error · " + (d.str("reason") ?? "")
                default: return "Failed · " + (d.str("reason") ?? "")
                }
            }
            if isErrorEvent(e) { return "Something went wrong" }
            switch event {
            case "situation": return [d.str("activity"), d.str("reason")].compactMap { $0 }.joined(separator: " · ")
            case "deferred": return d.str("reason") ?? ""
            case "reflection": return d.str("summary") ?? ""
            case "habit_swap": return d.bool("accepted") ? "Same relief, no pressure on the eyes" : "Not this time"
            case "zoom_offer":
                return (d.str("app") ?? "") + (d.bool("auto") ? " · automatic after your earlier yeses" : "")
            default: return "System"
            }
        }
    }

    var valueText: String? {
        switch e.str("kind") {
        case "trigger": triggerValue(e.str("trigger_id"), value)
        case "system" where event == "calibration" || event == "calibration_weak":
            switch e.obj("details")?.int("step") {
            case 1: e.obj("details")?.num("distance_cm").map { fmt($0, 0, suffix: " cm") }
            case 3: e.obj("details")?.num("blink_rate").map { fmt($0, 1, suffix: " /min") }
            default: nil
            }
        default: nil
        }
    }

    /// calibration, calibration_weak / _failed / _error / _interrupted, one per step
    var isCalibration: Bool { e.str("kind") == "system" && event.hasPrefix("calibration") }
    var calibrationStep: String {
        switch e.obj("details")?.int("step") { case 1: "distance"; case 2: "gaze"; case 4: "blink check"; default: "blink baseline" }
    }

    var icon: String {
        switch e.str("kind") {
        case "trigger": "bolt.fill"; case "break": "figure.walk"; case "rub": "hand.raised.fill"; case "yawn": "mouth"
        case "touch": "hand.point.up.left.fill"; case "lash_pull": "hand.pinch.fill"
        case "blink_anomaly": "eye.slash"; case "zen": "moon.stars.fill"
        default:
            isErrorEvent(e) ? "exclamationmark.triangle.fill" :
            ["situation": "lock.display", "deferred": "hourglass", "reflection": "sparkles", "calibration": "scope",
             "calibration_weak": "exclamationmark.circle", "calibration_failed": "exclamationmark.triangle",
             "calibration_interrupted": "pause.circle", "habit_swap": "hands.and.sparkles.fill",
             "zoom_offer": "textformat.size"][event] ?? "gearshape"
        }
    }

    var color: Color {
        switch e.str("kind") {
        case "trigger": .yellow; case "break": .green; case "zen": .indigo
        case "rub", "touch", "lash_pull", "blink_anomaly", "yawn": .orange
        default: isErrorEvent(e) ? .pink : ["situation": Color.mint, "deferred": .indigo, "reflection": .purple, "calibration": .teal,
                                            "calibration_weak": .yellow, "calibration_failed": .orange][event] ?? .gray
        }
    }
}

/// Who woke the agent, in words: "Low blink rate & long stare", "Routine check-in", "You ran the agent".
func runTitle(_ run: RunRow) -> String {
    let ids = run.triggers.compactMap { $0.str("id") }
    if ids == ["manual"] { return "You ran the agent" }
    if ids.allSatisfy({ $0 == "heartbeat" }) { return "Routine check-in" }
    return ids.filter { $0 != "heartbeat" }.map { humanize($0) }.joined(separator: " & ")
}

struct RunLogCard: View {
    @EnvironmentObject var store: Store
    let run: RunRow
    @Binding var expanded: Bool

    var body: some View {
        let calls = run.sortedCalls
        let err = run.status == "error"
        LogCardShell(icon: err ? "exclamationmark.triangle.fill" : "brain", color: err ? .pink : .purple,
                     spinning: run.status == "started", title: "Agent · \(runTitle(run))", subtitle: subtitle,
                     accent: err ? .pink : expanded ? .purple : nil) {
            HStack(spacing: 4) {
                ForEach(Array(calls.prefix(4).enumerated()), id: \.offset) { _, c in
                    Image(systemName: toolIcons[c.str("name") ?? ""] ?? "wrench").font(.caption)
                        .foregroundStyle(statusColor(c.str("status")))
                        .frame(width: 22, height: 22).background(statusColor(c.str("status")).opacity(0.14), in: Circle())
                }
            }
            TimeLabel(ts: run.ts).frame(width: 40, alignment: .trailing)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        } detail: {
            if expanded {
                DecisionContent(run: run, showReasoning: false)
                    .padding(.top, 12).padding(.leading, 46)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
    }

    var subtitle: String {
        if run.status == "started" { return "Thinking…" }
        if let e = run.error { return e }
        let calls = run.sortedCalls
        if let c = calls.first(where: { $0.str("status") == "done" }) ?? calls.first {
            var s = toolPhrase(c.str("name") ?? "")
            if c.str("status") != "done" { s += " · \(statusLabel(c.str("status")))" }
            if let v = c.int("id").flatMap({ store.outcomes[$0]?.str("verdict") }) {
                s += isGoodVerdict(v) ? " · helped ✓" : isBadVerdict(v) ? " · didn't help" : " · no change"
            }
            if calls.count > 1 { s += " · +\(calls.count - 1) more" }
            return s
        }
        let h = headlineSplit(decisionText(run)).headline
        return h.isEmpty ? "Decided to wait" : h
    }
}

// MARK: - decision content (shared by the Log and Agent pages)

/// The run's prose with repeats removed (some providers restate the earlier text in their final message).
func decisionText(_ run: RunRow) -> String {
    var parts: [String] = []
    for raw in run.texts {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in parts where t.hasPrefix(p) { t = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        if !t.isEmpty && !parts.contains(t) { parts.append(t) }
    }
    return parts.joined(separator: "\n\n")
}

struct DecisionContent: View {
    let run: RunRow
    var showReasoning = false
    var headline = false
    @StateVar private var reasoningOpen: Bool?

    var body: some View {
        let split = headlineSplit(decisionText(run))
        VStack(alignment: .leading, spacing: 10) {
            if headline && !split.headline.isEmpty {
                Text(split.headline).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            let body = headline ? split.rest : decisionText(run)
            if !body.isEmpty { MarkdownText(text: body, font: .callout, color: .primary.opacity(0.85)) }
            if !run.calls.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ACTIONS").font(.caption2.weight(.bold)).foregroundStyle(.tertiary).tracking(0.8)
                    ForEach(Array(run.sortedCalls.enumerated()), id: \.offset) { _, c in ActionRow(c: c) }
                }
            }
            if !run.thinking.isEmpty {
                DisclosureGroup(isExpanded: Binding(get: { reasoningOpen ?? showReasoning }, set: { reasoningOpen = $0 })) {
                    MarkdownText(text: run.thinking.joined(separator: "\n\n"), font: .caption, color: .secondary)
                        .padding(.top, 6)
                } label: {
                    Label("Reasoning summary", systemImage: "brain").font(.caption.weight(.semibold)).foregroundStyle(.purple)
                }
                .padding(10)
                .background(Color.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }
            if let err = run.error {
                Label(err, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.pink)
                    .textSelection(.enabled)
            }
            if body.isEmpty && run.calls.isEmpty && run.status != "started" && run.error == nil {
                Text("No rationale recorded.").font(.caption).foregroundStyle(.secondary)
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

func statusLabel(_ s: String?) -> String {
    switch s {
    case "done": "Done"
    case "failed": "Failed"
    case "declined": "Declined"
    case "blocked_tier": "Blocked"
    case "blocked_suppressed": "Held back"
    case "awaiting_approval": "Waiting for you"
    case nil: "Pending"
    default: humanize(s!)
    }
}

/// One tool call as an action chip: what it did, its status, and whether it helped.
struct ActionRow: View {
    @EnvironmentObject var store: Store
    let c: J
    @StateVar private var open = false

    var body: some View {
        let name = c.str("name") ?? ""
        let outcome = c.int("id").flatMap { store.outcomes[$0] }
        let color = statusColor(c.str("status"))
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: toolIcons[name] ?? "wrench").font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                    .frame(width: 26, height: 26).background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 1) {
                    Text(toolPhrase(name)).font(.callout.weight(.medium))
                    if let a = argSummary { Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(open ? nil : 1) }
                }
                Spacer(minLength: 8)
                if let o = outcome, let m = o.str("metric") {
                    Text("\(humanize(m)) \(fmt(o.num("before"), 1)) → \(fmt(o.num("after"), 1))")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
                if let v = outcome?.str("verdict") { VerdictBadge(verdict: v) }
                Text(statusLabel(c.str("status"))).font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(color.opacity(0.18), in: Capsule()).foregroundStyle(color)
            }
            if open {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if !argString.isEmpty { Text(argString).font(.caption.monospaced()).foregroundStyle(.tertiary) }
                    if let a = c.str("approval"), a != "never_asked" {
                        Text("Approval: \(humanize(a))").font(.caption).foregroundStyle(.tertiary)
                    }
                    if let r = c["result"], !(r is NSNull) {
                        Text("→ \(String(describing: r))").font(.caption).foregroundStyle(.secondary).lineLimit(4)
                    }
                }
                .padding(.leading, 36).textSelection(.enabled)
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { open.toggle() } }
        .help("Click for details")
    }

    /// The human part of the arguments: a message if there is one, otherwise "count 2 · intensity 0.3".
    var argSummary: String? {
        guard let a = c.obj("args"), !a.isEmpty else { return nil }
        for k in ["message", "question", "text", "reason"] { if let m = a.str(k) { return "“\(m)”" } }
        return a.keys.sorted().map { k in "\(k.replacingOccurrences(of: "_", with: " ")) \(a[k].map { String(describing: $0) } ?? "")" }
            .joined(separator: " · ")
    }

    var argString: String {
        guard let a = c["args"], let d = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys]) else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }
}

struct VerdictBadge: View {
    let verdict: String
    var body: some View {
        let good = isGoodVerdict(verdict), bad = isBadVerdict(verdict)
        Label(good ? "Helped" : bad ? "Didn't help" : humanize(verdict),
              systemImage: good ? "checkmark.circle.fill" : bad ? "xmark.circle.fill" : "minus.circle.fill")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background((good ? Color.green : bad ? .red : .gray).opacity(0.2), in: Capsule())
            .foregroundStyle(good ? Color.green : bad ? .red : .secondary)
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
        .onChange(of: range) { if range == nil { selection = nil } }
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
        .chartOverlay { proxy in
            GeometryReader { geo in
                ZStack(alignment: .topTrailing) {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                            // draw the selection while dragging; only commit (and move the feed) on release
                            guard let plot = proxy.plotFrame else { return }
                            let x0 = v.startLocation.x - geo[plot].minX, x1 = v.location.x - geo[plot].minX
                            if let a: Date = proxy.value(atX: min(x0, x1)), let b: Date = proxy.value(atX: max(x0, x1)) {
                                selection = a...b
                            }
                        }.onEnded { v in
                            guard let s = selection else { return }
                            // a click (no real drag) selects a few minutes around that moment
                            range = abs(v.translation.width) < 4
                                ? s.lowerBound.addingTimeInterval(-120)...s.lowerBound.addingTimeInterval(120) : s
                        })
                    Text(title).font(.caption2).foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }
        }
    }

    var dayDomain: ClosedRange<Date> {
        let start = store.logDay
        let times = store.chartMetrics.compactMap { $0.num("ts") } + store.runs.values.map(\.ts)
        guard let lo = times.min(), let hi = times.max(), hi > lo else { return start...start.addingTimeInterval(86400) }
        return Date(timeIntervalSince1970: lo - 60)...Date(timeIntervalSince1970: hi + 60)
    }
}
