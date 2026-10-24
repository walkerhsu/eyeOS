import AppKit
import SwiftUI

/// High-rate camera state (15 Hz), kept apart from Store so the charts and tiles don't redraw on every frame.
@MainActor
final class LiveFeed: ObservableObject {
    @Published var landmarks: J?
    @Published var frame: NSImage?
    @Published var trace: [(ts: Double, o: Double)] = []          // last 60 s of openness
    @Published var dipMarks: [(ts: Double, kind: String, o: Double)] = []
}

/// One 1 Hz sample of the live metrics, for the Live timeline (last hour kept in memory).
struct Sample {
    let ts: Double
    let values: [String: Double]
    let zen: Bool
}

/// App state mirrored from the sidecar. Swift never decides anything; it renders and relays input (SPEC §2).
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    let sidecar = Sidecar()
    lazy var overlays = Overlays(store: self)
    let feed = LiveFeed()

    @Published var connected = false
    @Published var page: Page = .live
    @Published var fatal: String?
    @Published var metrics: J = [:]
    @Published var status: J = [:]
    @Published var series: [Sample] = []                         // 1 Hz, last hour
    @Published var dayTimeline: [J] = []                           // today's metrics from the DB, for the "Today" range
    @Published var setupRequest: SetupRequest?
    @Published var settings: J = [:]
    @Published var triggerDefaults: J = [:]
    @Published var tools: [String: J] = [:]
    @Published var preferences: [J] = []
    @Published var baseline: J = [:]
    @Published var calibration: J?
    @Published var shortcuts: J?
    @Published var doctor: J?
    @Published var summary: J?
    @Published var events: [J] = []                                // log feed events (live + history)
    @Published var runs: [Int: RunRow] = [:]
    @Published var outcomes: [Int: J] = [:]                        // call_id -> outcome
    @Published var chartMetrics: [J] = []
    @Published var lastActed: (name: String, ts: Date)?
    @Published var logDay = Calendar.current.startOfDay(for: Date())
    @Published var lastError: String?

    private init() {
        sidecar.onMessage = { [weak self] m in self?.handle(m) }
        sidecar.onFrame = { [weak self] d in
            guard let self, self.setting("ui.show_camera_image") else { return }
            self.feed.frame = NSImage(data: d)
        }
        sidecar.onConnected = { [weak self] ok in
            guard let self else { return }
            self.connected = ok
            if ok { self.fatal = nil; self.loadDay() }
            // a step can't outlive its sidecar (the sidecar logs it as interrupted when it starts again)
            if let c = self.calibration, ["started", "progress"].contains(c.str("phase") ?? "") {
                self.calibration = ["type": "calibration", "step": c.int("step") ?? 0, "phase": "failed", "progress": 1,
                                    "result": ["reason": "eyeOS restarted before this step finished. Try again."]]
            }
        }
        sidecar.onFatal = { [weak self] s in self?.fatal = s }
    }

    func setting(_ k: String) -> Bool { (settings[k] as? Bool) ?? false }
    func set(_ key: String, _ value: Any) {
        settings[key] = value
        sidecar.send(["type": "set_setting", "key": key, "value": value])
    }

    var isToday: Bool { Calendar.current.isDateInToday(logDay) }

    // MARK: - inbound

    func handle(_ m: J) {
        switch m.str("type") ?? "" {
        case "hello":
            settings = m.obj("settings") ?? [:]
            triggerDefaults = m.obj("triggers") ?? [:]
        case "settings": settings = m.obj("settings") ?? settings
        case "status": status = m
        case "metrics":
            metrics = m
            record(m)
        case "landmarks":
            feed.landmarks = m
            if let ts = m.num("ts") {
                if let o = m.num("o") { feed.trace.append((ts, o)) }
                feed.trace.removeAll { $0.ts < ts - 60 }
                feed.dipMarks.removeAll { $0.ts < ts - 60 }
            }
        case "event":
            if m.str("kind") == "dip" {
                feed.dipMarks.append((m.num("ts") ?? 0, m.obj("details")?.str("dip") ?? "blink", m.num("value") ?? 0))
            } else if isToday {
                events.insert(m, at: 0)
            }
        case "agent_run":
            guard let id = m.int("run_id") else { return }
            var r = runs[id] ?? RunRow(id: id, ts: m.num("ts") ?? Date().timeIntervalSince1970)
            r.triggers = m.arr("triggers")
            r.status = m.str("phase") ?? r.status
            r.inputTokens = m.int("input_tokens") ?? r.inputTokens
            r.outputTokens = m.int("output_tokens") ?? r.outputTokens
            r.latency = m.num("latency_s") ?? r.latency
            r.error = m.str("error") ?? r.error
            runs[id] = r
        case "agent_thinking":
            if let id = m.int("run_id"), let t = m.str("text") { runs[id]?.thinking.append(t) }
        case "agent_text":
            if let id = m.int("run_id"), let t = m.str("text") { runs[id]?.texts.append(t) }
        case "tool_call":
            guard let id = m.int("run_id"), let cid = m.int("call_id") else { return }
            var c = m
            c["id"] = cid
            runs[id]?.calls[cid] = c
            if m.str("status") == "done", let n = m.str("name") { lastActed = (n, Date()) }
        case "outcome":
            if let cid = m.int("call_id") { outcomes[cid] = m }
        case "ui_request": overlays.show(m)
        case "ui_dismiss": overlays.dismiss(m.str("request_id") ?? "")
        case "tool_exec": overlays.exec(m)
        case "calibration":
            calibration = m
            // the blink baseline runs after setup closes, so a weak result is reported in a banner
            if m.int("step") == 3, m.str("phase") == "done", let w = (m["warnings"] as? [String])?.first {
                overlays.showWeakBaseline(w)
            }
        case "history": applyHistory(m)
        case "summary":
            if let d = m.str("date"), d == dayString { summary = m }
        case "approvals":
            tools = (m.obj("tools") as? [String: J]) ?? [:]
        case "preferences":
            preferences = m.arr("rows")
            baseline = m.obj("baseline") ?? [:]
        case "shortcuts": shortcuts = m
        case "doctor_eligibility": doctor = m
        case "error": lastError = m.str("message")
        default: break
        }
    }

    // MARK: - Log history

    var dayString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: logDay)
    }

    func loadDay() {
        let from = logDay.timeIntervalSince1970, to = from + 86400
        events = []
        runs = [:]
        outcomes = [:]
        summary = nil
        for kind in ["metrics", "events", "runs"] {
            sidecar.send(["type": "history_request", "request_id": kind, "kind": kind, "from": from, "to": to, "limit": 500])
        }
        sidecar.command("get_summary", ["date": dayString])
    }

    func loadTimelineDay() {
        let from = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        sidecar.send(["type": "history_request", "request_id": "timeline", "kind": "metrics", "from": from,
                      "to": Date().timeIntervalSince1970 + 1, "limit": 480])
    }

    /// Keeps a 1 Hz copy of the numeric metrics for the Live timeline's 1 m / 10 m / 1 h ranges.
    private func record(_ m: J) {
        guard let ts = m.num("ts"), m.bool("face_present") else { return }
        if let last = series.last, ts - last.ts < 1 { return }
        var v: [String: Double] = [:]
        for k in MetricDef.all.map(\.id) where k != "openness" {
            if let x = m.num(k) { v[k] = x } else if let b = m[k] as? Bool { v[k] = b ? 1 : 0 }
        }
        if m.bool("posture_ready") { v["posture"] = Double(m.arr0("posture_issues").count) }  // number of posture issues
        series.append(Sample(ts: ts, values: v, zen: m.bool("zen")))
        if series.count > 3700 { series.removeFirst(series.count - 3600) }
    }

    private func applyHistory(_ m: J) {
        let rows = m.arr("rows")
        if m.str("request_id") == "timeline" { dayTimeline = rows; return }
        switch m.str("kind") {
        case "metrics": chartMetrics = rows
        case "events": events = rows
        case "runs":
            for r in rows {
                guard let id = r.int("id") else { continue }
                var row = RunRow(id: id, ts: r.num("ts_start") ?? 0)
                row.triggers = r.arr("triggers")
                row.status = r.str("status") ?? ""
                row.thinking = [r.str("thinking")].compactMap { $0 }.filter { !$0.isEmpty }
                row.texts = [r.str("text")].compactMap { $0 }.filter { !$0.isEmpty }
                row.inputTokens = r.int("input_tokens")
                row.outputTokens = r.int("output_tokens")
                if let a = r.num("ts_start"), let b = r.num("ts_end") { row.latency = b - a }
                row.error = r.str("error")
                for c in r.arr("tool_calls") {
                    guard let cid = c.int("id") else { continue }
                    row.calls[cid] = c
                    if let v = c.str("verdict") {
                        outcomes[cid] = ["call_id": cid, "verdict": v, "metric": c["metric"] ?? NSNull(),
                                         "before": c["before"] ?? NSNull(), "after": c["after"] ?? NSNull()]
                    }
                }
                runs[id] = row
            }
        default: break
        }
    }

    // MARK: - derived

    var provider: String { settings.str("agent.provider") ?? "claude" }
    var providerName: String { provider == "codex" ? "Codex" : "Claude" }
    var agentAvailable: Bool { status.bool("agent_available") }

    var zen: J { status.obj("zen") ?? [:] }
    var inZen: Bool { zen.bool("active") }
    var today: J { status.obj("today") ?? [:] }
    func setZen(_ on: Bool) { sidecar.command("zen", ["on": on]) }

    /// Worst status across the Live cards, for the menu bar dot.
    var worstLevel: Level {
        let ls = [levelHigh(metrics.num("blink_rate"), good: 12, warn: 8),
                  levelLow(metrics.num("current_stare_s"), good: 10, warn: 20),
                  levelLow(metrics.num("perclos").map { $0 * 100 }, good: 8, warn: 15),
                  levelHigh(metrics.num("distance_cm"), good: 50, warn: 40)]
        if ls.contains(.bad) { return .bad }
        if ls.contains(.warn) { return .warn }
        return ls.contains(.good) ? .good : .none
    }
}

/// Asks RootView to open setup: the full first-run flow or just the calibration steps.
struct SetupRequest: Identifiable {
    let id = UUID()
    let recalibrate: Bool
}
