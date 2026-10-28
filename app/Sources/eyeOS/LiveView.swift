import Charts
import SwiftUI

private let rightEye = [33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246]
private let leftEye = [362, 382, 381, 380, 374, 373, 390, 249, 263, 466, 388, 387, 386, 385, 384, 398]
private let faceOval = [10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288, 397, 365, 379, 378, 400, 377, 152, 148, 176,
                        149, 150, 136, 172, 58, 132, 93, 234, 127, 162, 21, 54, 103, 67, 109]
private let lips = [61, 146, 91, 181, 84, 17, 314, 405, 321, 375, 291, 409, 270, 269, 267, 0, 37, 39, 40, 185]
private let fingertips = [4, 8, 12, 16, 20]

// MARK: - shared styling

extension View {
    /// The dashboard's card look: soft fill, hairline border, optional accent border when selected.
    func card(padding: CGFloat = 16, accent: Color? = nil) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(accent?.opacity(0.7) ?? Color.white.opacity(0.08), lineWidth: accent == nil ? 1 : 1.5))
    }
}

struct SectionTitle: View {
    let text: String
    let icon: String
    var body: some View {
        Label(text, systemImage: icon).font(.headline).foregroundStyle(.secondary)
    }
}

struct Pill: View {
    let text: String
    var icon: String? = nil
    var color: Color = .secondary
    var spinning = false
    var body: some View {
        HStack(spacing: 5) {
            if spinning { ProgressView().controlSize(.mini) } else if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(color.opacity(0.16), in: Capsule())
        .foregroundStyle(color == .secondary ? Color.primary.opacity(0.8) : color)
    }
}

// MARK: - page

struct LiveView: View {
    @EnvironmentObject var store: Store
    @AppStorage("live.metric") private var metric = "blink_rate"
    @AppStorage("live.range") private var range = "10m"

    var body: some View {
        let camera = store.setting("ui.show_camera_image")
        GeometryReader { geo in
            // Fit everything in the window and let the timeline take the leftover height; scroll only when it's too short.
            if geo.size.height >= (camera ? 720 : 700) {
                content(camera: camera, fill: true, height: geo.size.height).frame(height: geo.size.height)
            } else {
                ScrollView { content(camera: camera, fill: false, height: geo.size.height) }
            }
        }
    }

    func content(camera: Bool, fill: Bool, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            AppBar(title: "Live") { cameraToggle }
            if camera {
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 14) {
                        CameraView(feed: store.feed).frame(maxHeight: fill ? max(200, height - 440) : 360)
                        TimelineCard(metric: $metric, range: $range, fill: fill)
                    }
                    .frame(maxWidth: .infinity)
                    VStack(spacing: 10) {
                        ScoreSummary(ringSize: 64)
                        TileGrid(columns: 2, selected: $metric)
                        TodayStrip(columns: 3, compact: true)
                    }
                    .frame(width: 400)
                }
            } else {
                HeroCard()
                TileGrid(columns: 4, selected: $metric)
                TimelineCard(metric: $metric, range: $range, fill: fill)
            }
        }
        .padding(20)
    }

    var cameraToggle: some View {
        Toggle(isOn: Binding(get: { store.setting("ui.show_camera_image") },
                             set: { store.set("ui.show_camera_image", $0); if !$0 { store.feed.frame = nil } })) {
            Label("Camera", systemImage: store.setting("ui.show_camera_image") ? "video.fill" : "video.slash")
        }
        .toggleStyle(.button)
        .controlSize(.large)
        .help("Show or hide what the camera sees")
    }
}

struct ZenButton: View {
    @EnvironmentObject var store: Store

    var body: some View {
        if store.inZen {
            Button { store.setZen(false) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "moon.stars.fill")
                    Text("Zen · \(duration(store.zen.num("duration_s")))")
                    if let n = store.zen.int("held_back"), n > 0 { Text("· \(n) held").foregroundStyle(.white.opacity(0.7)) }
                }
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(LinearGradient(colors: [.indigo, .purple], startPoint: .leading, endPoint: .trailing), in: Capsule())
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help(store.zen.str("source") == "manual" ? "You started Zen. Click to end it." : "Deep focus detected. Click to end Zen.")
        } else {
            Button { store.setZen(true) } label: { Label("Zen", systemImage: "moon.stars") }
                .controlSize(.large)
                .help("Start Zen now: eyeOS keeps measuring but stays completely silent")
        }
    }
}

// MARK: - score

func scoreLabel(_ s: Double?) -> String {
    guard let s else { return "Waiting for your face" }
    return s >= 80 ? "Eyes relaxed" : s >= 60 ? "Mild strain" : s >= 40 ? "Eyes working hard" : "Time to rest"
}

/// The biggest single reason the score is down: a sentence for cards, a 1–3 word label for the HUD.
struct Issue {
    let text: String
    let short: String
    var exercise: Exercise? = nil   // the guided exercise that fits this issue, offered by the HUD and menu bar
}

/// A guided exercise the user can start themselves; the sidecar runs the same scripts the agent uses.
struct Exercise: Identifiable {
    let id: String
    let title: String
    let icon: String
    let seconds: Int

    static let blink = Exercise(id: "deliberate_blink", title: "Blink exercise", icon: "eye", seconds: 30)
    static let focus = Exercise(id: "focus_shift", title: "Focus shift", icon: "arrow.left.and.right", seconds: 30)
    static let palming = Exercise(id: "palming", title: "Palming", icon: "hand.raised", seconds: 45)
    static let gaze = Exercise(id: "gaze_trace", title: "Follow the dot", icon: "scribble.variable", seconds: 30)
    static let all = [blink, focus, palming, gaze]
}

func topIssue(_ m: J) -> Issue {
    if !m.bool("face_present") { return Issue(text: "Sit in front of the camera to start measuring.", short: "Away") }
    if !m.bool("calibrated") { return Issue(text: "Calibrate once so eyeOS knows your normal.", short: "Calibrate") }
    if (m.num("perclos") ?? 0) > 0.15 { return Issue(text: "Your eyes are closing a lot. Signs of tiredness.", short: "Eyes tired", exercise: .palming) }
    if (m.num("blink_rate") ?? 99) < 8 { return Issue(text: "You're blinking much less than usual.", short: "Blink more", exercise: .blink) }
    if m.obj("blink_trend")?.bool("declining") == true {
        return Issue(text: "Your blinking has been sliding. You may be getting tired.", short: "Blinks sliding", exercise: .blink)
    }
    if (m.num("blink_rate") ?? 0) > 30 {
        return Issue(text: "You're blinking a lot. Your eyes may already feel dry or irritated.", short: "Eyes irritated", exercise: .palming)
    }
    if !m.arr0("posture_issues").isEmpty && (m.num("posture_off_s") ?? 0) > 60 {
        return Issue(text: "Your posture is drifting, a common sign of tiredness.", short: "Sit back")
    }
    if (m.num("since_real_break_s") ?? 0) > 1800 {
        return Issue(text: "No real break for \(duration(m.num("since_real_break_s"))).", short: "Break due", exercise: .focus)
    }
    if (m.num("incomplete_pct") ?? 0) > 0.4 { return Issue(text: "Many blinks aren't closing fully.", short: "Full blinks", exercise: .blink) }
    if (m.num("current_stare_s") ?? 0) > 15 { return Issue(text: "Long stare. Your eyes haven't blinked in a while.", short: "Blink", exercise: .blink) }
    if m.bool("squinting") { return Issue(text: "You're squinting at the screen.", short: "Squinting", exercise: .palming) }
    if let d = m.num("distance_cm"), d < 40 { return Issue(text: "You're sitting close to the screen.", short: "Too close") }
    return Issue(text: "Everything looks comfortable.", short: "All good")
}

struct ScoreRing: View {
    let score: Double?
    var size: CGFloat = 120

    var body: some View {
        let s = score ?? 0
        let color: Color = score == nil ? .secondary : s >= 80 ? .mint : s >= 60 ? .yellow : s >= 40 ? .orange : .pink
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: size * 0.09)
            Circle().trim(from: 0, to: s / 100)
                .stroke(LinearGradient(colors: [color.opacity(0.7), color], startPoint: .bottom, endPoint: .top),
                        style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(score.map { "\(Int($0))" } ?? "–").font(.system(size: size * 0.32, weight: .bold, design: .rounded)).monospacedDigit()
                if size >= 100 { Text("eye score").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.6), value: score)
    }
}

struct ScoreSummary: View {
    @EnvironmentObject var store: Store
    var ringSize: CGFloat = 76

    var body: some View {
        let score = store.metrics.num("eye_score")
        HStack(spacing: 14) {
            ScoreRing(score: score, size: ringSize)
            VStack(alignment: .leading, spacing: 4) {
                Text("Eye score").font(.caption).foregroundStyle(.secondary)
                Text(scoreLabel(score)).font(.title3.bold())
                Text(topIssue(store.metrics).text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 14)
        .explain(Explain.eyeScore)
    }
}

struct HeroCard: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let score = store.metrics.num("eye_score")
        HStack(alignment: .center, spacing: 24) {
            ScoreRing(score: score, size: 120).explain(Explain.eyeScore)
            VStack(alignment: .leading, spacing: 8) {
                Text(scoreLabel(score)).font(.system(size: 24, weight: .bold))
                Text(topIssue(store.metrics).text).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if store.inZen {
                    Label("In Zen for \(duration(store.zen.num("duration_s"))). eyeOS is staying silent.", systemImage: "moon.stars.fill")
                        .foregroundStyle(.indigo)
                }
            }
            .frame(maxWidth: 320, alignment: .leading)
            Spacer(minLength: 12)
            Divider().frame(height: 100)
            TodayStrip(columns: 3, bare: true).frame(maxWidth: 420)
        }
        .card(padding: 18)
    }
}

// MARK: - today

struct TodayStrip: View {
    @EnvironmentObject var store: Store
    var columns = 3
    var bare = false
    var compact = false

    /// "3 · avg 8": today's rubs against the last week's daily average, once there is one.
    func rubsValue(_ t: J) -> String {
        let n = t.int("rubs") ?? 0
        return t.num("rubs_avg_7d").map { "\(n) · avg \(fmt($0, 0))" } ?? "\(n)"
    }

    var body: some View {
        let t = store.today
        let items: [(String, String, String, Color, Explainer)] = [
            ("display", duration(t.num("screen_time_s") ?? store.metrics.num("screen_time_today_s")), "Screen time", .blue, Explain.screenTime),
            ("cup.and.saucer.fill", "\(t.int("breaks") ?? 0)", "Real breaks", .green, Explain.breaks),
            ("moon.stars.fill", duration(t.num("zen_s")), "In Zen", .indigo, Explain.zenTime),
            ("eye.fill", fmt(t.num("avg_blink_rate"), 1), "Avg blinks/min", .teal, Explain.avgBlinks),
            ("sparkles", "\(t.int("nudges") ?? 0)", "Nudges", .purple, Explain.nudges),
            ("hand.raised.fill", rubsValue(t), (t.int("habit_swaps") ?? 0) > 0 ? "Eye rubs · \(t.int("habit_swaps")!) swapped" : "Eye rubs",
             (t.num("rubs_avg_7d")).map { Double(t.int("rubs") ?? 0) < $0 ? Color.mint : .orange } ?? .orange, Explain.rubs),
        ]
        let content = VStack(alignment: .leading, spacing: compact ? 10 : 12) {
            if compact {
                Label("Today", systemImage: "calendar").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            } else {
                SectionTitle(text: "Today", icon: "calendar")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .leading), count: columns),
                      alignment: .leading, spacing: compact ? 10 : 14) {
                ForEach(items, id: \.2) { icon, value, label, color, explainer in
                    HStack(spacing: compact ? 8 : 10) {
                        Image(systemName: icon).font(.system(size: compact ? 11 : 13, weight: .semibold)).foregroundStyle(color)
                            .frame(width: compact ? 24 : 28, height: compact ? 24 : 28)
                            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(value).font(.system(compact ? .callout : .body, design: .rounded).weight(.semibold)).monospacedDigit()
                            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .explain(explainer)
                }
            }
        }
        if bare { content } else { content.card(padding: compact ? 12 : 16) }
    }
}

// MARK: - tiles

struct StatTile: View {
    let def: MetricDef
    var title: String? = nil
    let value: String
    var unit: String = ""
    let detail: String
    let level: Level
    var progress: Double? = nil
    let selected: Bool
    var explainer: Explainer? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: def.icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(def.color)
                        .frame(width: 24, height: 24).background(def.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
                    Text(title ?? def.title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Circle().fill(level.color).frame(width: 7, height: 7)
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value).font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                    if !unit.isEmpty { Text(unit).font(.callout).foregroundStyle(.secondary) }
                }
                if let progress {
                    ProgressView(value: min(1, max(0, progress))).tint(level.color).controlSize(.small)
                }
                Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .contentShape(Rectangle())
            .card(padding: 12, accent: selected ? def.color : nil)
        }
        .buttonStyle(.plain)
        .explain(explainer.map { Explainer(title: $0.title, meaning: $0.meaning, math: $0.math, good: $0.good,
                                           source: [$0.source, "Click the card to plot it on the timeline."].compactMap { $0 }.joined(separator: " ")) }
                 ?? Explainer(title: def.title, meaning: "Click to plot \(def.title.lowercased()) on the timeline."))
    }
}

struct TileGrid: View {
    @EnvironmentObject var store: Store
    let columns: Int
    @Binding var selected: String

    /// Your band: below 60% of normal is low, above 1.6x (min 25/min) is frequent. Mirrors zen.py.
    var band: (low: Double, high: Double) {
        let base = min(25, max(10, store.baseline.num("blink_rate") ?? 15))
        return (max(8, 0.6 * base), max(25, 1.6 * base))
    }

    func blinkLevel(_ br: Double?) -> Level {
        guard let br else { return .none }
        let (lo, hi) = band
        if br < lo * 0.75 || br > hi * 1.25 { return .bad }
        return br < lo || br > hi ? .warn : .good
    }

    func blinkDetail(_ m: J) -> String {
        if m.str("app_category") == "call" { return "Paused during calls" }
        if m.bool("talking") { return "Paused while you talk" }
        if let tr = m.obj("blink_trend"), tr.bool("declining") {
            return "Sliding: \(fmt(tr.num("start"), 0)) → \(fmt(tr.num("end"), 0))/min"
        }
        let (lo, hi) = band
        return "Your band: \(fmt(lo, 0))–\(fmt(hi, 0))/min"
    }

    func postureValue(_ m: J) -> String {
        guard m.bool("posture_ready") else { return "Learning" }
        let issues = m.arr0("posture_issues")
        return issues.isEmpty ? "Upright" : humanize(issues[0])
    }

    func postureDetail(_ m: J, onScreen: Double?) -> String {
        guard m.bool("posture_ready") else { return "Learning how you sit (3 min)" }
        let issues = m.arr0("posture_issues")
        if issues.isEmpty { return "Session \(duration(m.num("session_s"))) · eyes on screen \(fmt(onScreen, 0))%" }
        return (issues.count > 1 ? "+\(issues.count - 1) more · " : "") + "for \(duration(m.num("posture_off_s")))"
    }

    static let explainers: [String: Explainer] = [
        "blink_rate": Explain.blinkRate, "incomplete_pct": Explain.incomplete, "current_stare_s": Explain.stare,
        "perclos": Explain.drowsiness, "distance_cm": Explain.distance, "squint_delta": Explain.squint,
        "since_real_break_s": Explain.lastBreak, "posture": Explain.posture,
    ]

    func tile(_ id: String, title: String? = nil, value: String, unit: String = "", detail: String, level: Level,
              progress: Double? = nil) -> StatTile {
        StatTile(def: .get(id), title: title, value: value, unit: unit, detail: detail, level: level, progress: progress,
                 selected: selected == id, explainer: Self.explainers[id]) { selected = id }
    }

    var body: some View {
        let m = store.metrics, b = store.baseline
        let br = m.num("blink_rate"), since = m.num("since_real_break_s") ?? 0
        let squintS = m.num("squint_s") ?? 0
        let recent = store.series.suffix(60)
        let onScreen = recent.isEmpty ? nil : Double(recent.filter { ($0.values["gaze_on_screen"] ?? 0) > 0.5 }.count) / Double(recent.count) * 100
        let nextBreak = 1200 - since
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
            tile("blink_rate", value: br == nil && m.bool("talking") ? "Talking" : fmt(br, 1), unit: br == nil ? "" : "/min",
                 detail: blinkDetail(m), level: blinkLevel(br))
            tile("incomplete_pct", value: fmt(m.num("incomplete_pct").map { $0 * 100 }, 0), unit: "%",
                 detail: "Blinks that don't fully close", level: levelLow(m.num("incomplete_pct").map { $0 * 100 }, good: 25, warn: 40))
            tile("current_stare_s", value: fmt(m.num("current_stare_s"), 0), unit: "s",
                 detail: "Longest: \(fmt(m.num("longest_stare_s"), 0)) s", level: levelLow(m.num("current_stare_s"), good: 10, warn: 20))
            tile("perclos", value: fmt(m.num("perclos").map { $0 * 100 }, 1), unit: "%",
                 detail: "Time eyes are mostly closed", level: levelLow(m.num("perclos").map { $0 * 100 }, good: 8, warn: 15))
            tile("distance_cm", value: fmt(m.num("distance_cm"), 0) + (m.bool("distance_stale") ? "*" : ""), unit: "cm",
                 detail: b.num("distance_cm").map { "Calibrated at \(fmt($0, 0)) cm" } ?? "Aim for 50–70 cm",
                 level: levelHigh(m.num("distance_cm"), good: 50, warn: 40))
            tile("squint_delta", value: m.bool("squinting") ? "\(Int(squintS))" : "Relaxed", unit: m.bool("squinting") ? "s" : "",
                 detail: m.bool("squinting") ? "Squinting now" : "Lid tension \(fmt(m.num("squint_delta"), 2))",
                 level: !m.bool("squinting") ? .good : squintS < 30 ? .warn : .bad)
            tile("since_real_break_s", title: "Last break", value: duration(since), unit: "ago",
                 detail: nextBreak > 0 ? "20-20-20 break in \(duration(nextBreak))" : "Break overdue by \(duration(-nextBreak))",
                 level: since < 1200 ? .good : since <= 2400 ? .warn : .bad, progress: since / 1200)
            tile("posture", value: postureValue(m), detail: postureDetail(m, onScreen: onScreen),
                 level: !m.bool("posture_ready") ? .none : (m.arr0("posture_issues").isEmpty ? .good : (m.num("posture_off_s") ?? 0) < 60 ? .warn : .bad))
        }
    }
}

// MARK: - timeline

struct TimelineCard: View {
    @EnvironmentObject var store: Store
    @Binding var metric: String
    @Binding var range: String
    var fill = false
    private let ranges: [(String, Double)] = [("1m", 60), ("10m", 600), ("1h", 3600), ("Today", 0)]

    struct Point: Identifiable {
        let id: Int
        let t: Date
        let v: Double
        let seg: Int
    }

    var body: some View {
        let def = MetricDef.get(metric)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SectionTitle(text: "Timeline", icon: "chart.xyaxis.line")
                Picker("Metric", selection: $metric) {
                    ForEach(MetricDef.all) { d in Label(d.title, systemImage: d.icon).tag(d.id) }
                }
                .labelsHidden().frame(width: 190)
                Spacer(minLength: 8)
                Picker("Range", selection: $range) {
                    ForEach(ranges, id: \.0) { Text($0.0).tag($0.0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 210)
                .disabled(metric == "openness")
            }
            if metric == "openness" {
                OpennessChart(feed: store.feed).frame(minHeight: fill ? 110 : 210, maxHeight: fill ? .infinity : 210)
                Text("Live eye openness for the last 60 s. Red dots are full blinks, orange are half blinks, purple are long blinks.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else {
                chart(def).frame(minHeight: fill ? 110 : 210, maxHeight: fill ? .infinity : 210)
                statsRow(def)
            }
        }
        .card(padding: 14)
        .task(id: range) {
            guard range == "Today" else { return }
            while !Task.isCancelled {
                store.loadTimelineDay()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func legend(color: Color, text: String, dashed: Bool = false) -> some View {
        HStack(spacing: 5) {
            if dashed {
                Rectangle().fill(color).frame(width: 12, height: 2)
            } else {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            }
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Raw (ts, value, zen) rows for the selected range, oldest first.
    func rows(_ def: MetricDef) -> (rows: [(Double, Double, Bool)], from: Double, to: Double) {
        let now = Date().timeIntervalSince1970
        if range == "Today" {
            let r: [(Double, Double, Bool)] = store.dayTimeline.compactMap { row in
                guard let ts = row.num("ts") else { return nil }
                let v = row.num(def.id) ?? ((row[def.id] as? Bool).map { $0 ? 1 : 0 })
                guard let v else { return nil }
                return (ts, v, row.bool("zen"))
            }
            return (r, Calendar.current.startOfDay(for: Date()).timeIntervalSince1970, now)
        }
        let span = ranges.first { $0.0 == range }?.1 ?? 600
        let r = store.series.filter { $0.ts >= now - span }.compactMap { s in s.values[def.id].map { (s.ts, $0, s.zen) } }
        return (r, now - span, now)
    }

    /// Averages rows into at most ~240 buckets; a gap of no data starts a new line segment.
    func points(_ def: MetricDef) -> (pts: [Point], zen: [(Date, Date)], from: Date, to: Date) {
        let (raw, from, to) = rows(def)
        let width = max(1, (to - from) / 240)
        var pts: [Point] = [], zen: [(Date, Date)] = []
        var seg = 0, lastT: Double?
        var bucket: [(Double, Double, Bool)] = [], bucketIdx: Int?
        func flush() {
            guard let first = bucket.first else { return }
            let mean = bucket.map(\.1).reduce(0, +) / Double(bucket.count)
            let t = first.0
            if let lastT, t - lastT > width * 3 + 5 { seg += 1 }
            pts.append(Point(id: pts.count, t: Date(timeIntervalSince1970: t), v: mean * def.scale, seg: seg))
            if bucket.contains(where: \.2) {
                let s = Date(timeIntervalSince1970: t), e = Date(timeIntervalSince1970: t + width)
                if let last = zen.last, s.timeIntervalSince(last.1) < width * 2 { zen[zen.count - 1].1 = e } else { zen.append((s, e)) }
            }
            lastT = t
            bucket = []
        }
        for r in raw {
            let i = Int((r.0 - from) / width)
            if i != bucketIdx { flush(); bucketIdx = i }
            bucket.append(r)
        }
        flush()
        return (pts, zen, Date(timeIntervalSince1970: from), Date(timeIntervalSince1970: to))
    }

    func baseline(_ def: MetricDef) -> Double? {
        def.baselineKey.flatMap { store.baseline.num($0) }.map { $0 * def.scale }
    }

    @ViewBuilder func chart(_ def: MetricDef) -> some View {
        let p = points(def)
        let base = baseline(def)
        let top = max(p.pts.map(\.v).max() ?? 1, (def.limit ?? 0) * 1.15, (base ?? 0) * 1.15, 1) * 1.1
        let yDomain = def.domain ?? 0...top
        let gradient = LinearGradient(colors: [def.color.opacity(0.35), def.color.opacity(0.02)], startPoint: .top, endPoint: .bottom)
        Chart {
            ForEach(Array(p.zen.enumerated()), id: \.offset) { _, z in
                RectangleMark(xStart: .value("start", z.0), xEnd: .value("end", z.1))
                    .foregroundStyle(Color.indigo.opacity(0.18))
            }
            ForEach(p.pts) { pt in
                AreaMark(x: .value("time", pt.t), y: .value(def.title, pt.v), series: .value("segment", pt.seg))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(gradient)
                LineMark(x: .value("time", pt.t), y: .value(def.title, pt.v), series: .value("segment", pt.seg))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(def.color)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            if let base {
                RuleMark(y: .value("baseline", base))
                    .foregroundStyle(Color.white.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            if let l = def.limit {
                RuleMark(y: .value("limit", l))
                    .foregroundStyle(Color.pink.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .chartXScale(domain: p.from...p.to)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                AxisValueLabel(format: range == "1m" ? .dateTime.hour().minute().second() : .dateTime.hour().minute())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                AxisValueLabel()
            }
        }
        .overlay {
            if p.pts.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "chart.line.uptrend.xyaxis").font(.title2)
                    Text(range == "Today" ? "No data recorded today yet." : "Collecting data. The timeline fills in as eyeOS watches.")
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    func statsRow(_ def: MetricDef) -> some View {
        let vals = rows(def).rows.map { $0.1 * def.scale }
        let now = store.metrics.num(def.id).map { $0 * def.scale } ?? ((store.metrics[def.id] as? Bool).map { $0 ? 100 : 0 })
        let avg = vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
        let items: [(String, Double?)] = [("Now", now), ("Average", avg), ("Low", vals.min()), ("High", vals.max())]
        return HStack(spacing: 22) {
            ForEach(items, id: \.0) { label, v in
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    Text(fmt(v, def.digits, suffix: def.unit.isEmpty ? "" : " \(def.unit)"))
                        .font(.system(.body, design: .rounded).weight(.semibold)).monospacedDigit()
                }
            }
            if let base = baseline(def) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Baseline").font(.caption).foregroundStyle(.secondary)
                    Text(fmt(base, def.digits, suffix: def.unit.isEmpty ? "" : " \(def.unit)"))
                        .font(.system(.body, design: .rounded).weight(.semibold)).monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                legend(color: .indigo.opacity(0.5), text: "Zen")
                if def.limit != nil { legend(color: .pink, text: "Watch line", dashed: true) }
                if def.baselineKey != nil { legend(color: .white.opacity(0.6), text: "Baseline", dashed: true) }
            }
        }
        .contentShape(Rectangle())
        .explain(Explain.stats(def, range: range))
    }
}

/// The live openness trace with blink / incomplete markers (shows incomplete blinks at a glance).
struct OpennessChart: View {
    @ObservedObject var feed: LiveFeed

    var body: some View {
        let now = feed.trace.last?.ts ?? Date().timeIntervalSince1970
        Chart {
            RuleMark(y: .value("complete", 0.2)).foregroundStyle(Color.pink.opacity(0.35)).lineStyle(StrokeStyle(dash: [3]))
            RuleMark(y: .value("incomplete", 0.6)).foregroundStyle(Color.orange.opacity(0.35)).lineStyle(StrokeStyle(dash: [3]))
            ForEach(Array(feed.trace.enumerated()), id: \.offset) { _, s in
                LineMark(x: .value("t", s.ts - now), y: .value("openness", s.o))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.cyan)
            }
            ForEach(Array(feed.dipMarks.enumerated()), id: \.offset) { _, d in
                PointMark(x: .value("t", d.ts - now), y: .value("openness", d.o))
                    .foregroundStyle(d.kind == "incomplete" ? Color.orange : d.kind == "long_blink" ? Color.purple : Color.pink)
                    .symbolSize(50)
            }
        }
        .chartXScale(domain: -60...0)
        .chartYScale(domain: 0...1.2)
        .chartXAxisLabel("seconds ago")
    }
}

// MARK: - camera

struct CameraView: View {
    @EnvironmentObject var store: Store
    @ObservedObject var feed: LiveFeed

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack {
                Color(white: 0.06)
                if let img = feed.frame {
                    Image(nsImage: img).resizable()
                }
                Canvas { ctx, size in draw(ctx, size) }
            }
            .scaleEffect(x: -1, y: 1)  // mirrored for display only; all math is unmirrored (SPEC §3)
            .clipped()

            HStack(spacing: 6) {
                if store.metrics.bool("rubbing") { Pill(text: "Eye rub", icon: "hand.raised.fill", color: .pink) }
                if store.metrics.bool("squinting") { Pill(text: "Squinting", icon: "sun.max.fill", color: .orange) }
            }
            .padding(10)
        }
        // the container takes the camera's own aspect so the image and the normalized landmarks line up
        .aspectRatio((store.status.num("frame_w") ?? 16) / (store.status.num("frame_h") ?? 9), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.08)))
    }

    func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        guard let lm = feed.landmarks else { return }
        func pt(_ p: [Double]) -> CGPoint { CGPoint(x: p[0] * size.width, y: p[1] * size.height) }
        if let face = lm["face"] as? [[Double]], face.count >= 478 {
            for (i, p) in face.enumerated() where i % 3 == 0 {
                ctx.fill(Path(ellipseIn: CGRect(origin: pt(p), size: .init(width: 1.5, height: 1.5))), with: .color(.white.opacity(0.35)))
            }
            func contour(_ idx: [Int], _ color: Color, width: CGFloat = 1) {
                var path = Path()
                path.addLines(idx.map { pt(face[$0]) })
                path.closeSubpath()
                ctx.stroke(path, with: .color(color), lineWidth: width)
            }
            let o = lm.num("o") ?? 1
            let eyeColor = Color(hue: 0.33 * min(1, max(0, (o - 0.2) / 0.7)), saturation: 0.9, brightness: 0.95)
            contour(faceOval, .white.opacity(0.25))
            contour(lips, .white.opacity(0.3))
            contour(rightEye, eyeColor, width: 2)
            contour(leftEye, eyeColor, width: 2)
            if let iris = lm["iris"] as? J {
                for (k, eye) in [("r", rightEye), ("l", leftEye)] {
                    guard let v = iris[k] as? [Double], v.count == 3 else { continue }
                    let c = CGPoint(x: v[0] * size.width, y: v[1] * size.height), r = v[2] * size.width
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(.cyan), lineWidth: 1.5)
                    // gaze vector: iris offset from the eye's center, exaggerated
                    let ec = eye.map { pt(face[$0]) }.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x / 16, y: $0.y + $1.y / 16) }
                    var p = Path()
                    p.move(to: c)
                    p.addLine(to: CGPoint(x: c.x + (c.x - ec.x) * 6, y: c.y + (c.y - ec.y) * 6))
                    ctx.stroke(p, with: .color(.cyan.opacity(0.8)), lineWidth: 1.5)
                }
            }
            // head-pose gizmo at the nose tip
            let n = pt(face[1]), m = store.metrics
            let yaw = (m.num("yaw_deg") ?? 0) * .pi / 180, pitch = (m.num("pitch_deg") ?? 0) * .pi / 180, roll = (m.num("roll_deg") ?? 0) * .pi / 180
            let L = size.width * 0.07
            for (dx, dy, c) in [(cos(roll), sin(roll), Color.red), (-sin(roll), cos(roll), Color.green), (-sin(yaw), -sin(pitch), Color.blue)] {
                var p = Path()
                p.move(to: n)
                p.addLine(to: CGPoint(x: n.x + dx * L, y: n.y + dy * L))
                ctx.stroke(p, with: .color(c), lineWidth: 2)
            }
        }
        // shoulders + neck from MediaPipe Pose: green when upright, orange when posture has drifted
        if let pose = lm["pose"] as? [[Double]], pose.count >= 13, pose[11].count >= 4, min(pose[11][3], pose[12][3]) > 0.6 {
            let off = !store.metrics.arr0("posture_issues").isEmpty
            let color: Color = off ? .orange : .green
            let l = pt(pose[11]), r = pt(pose[12]), nose = pt(pose[0])
            let mid = CGPoint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2)
            var p = Path()
            p.move(to: l); p.addLine(to: r)
            p.move(to: mid); p.addLine(to: nose)
            ctx.stroke(p, with: .color(color.opacity(0.85)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            for c in [l, r] { ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(color)) }
        }
        for hand in (lm["hands"] as? [[[Double]]]) ?? [] {
            for i in fingertips where i < hand.count {
                let c = pt(hand[i])
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)),
                         with: .color(store.metrics.bool("rubbing") ? .red : .yellow))
            }
        }
    }
}
