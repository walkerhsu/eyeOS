import Charts
import SwiftUI

private let rightEye = [33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246]
private let leftEye = [362, 382, 381, 380, 374, 373, 390, 249, 263, 466, 388, 387, 386, 385, 384, 398]
private let faceOval = [10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288, 397, 365, 379, 378, 400, 377, 152, 148, 176,
                        149, 150, 136, 172, 58, 132, 93, 234, 127, 162, 21, 54, 103, 67, 109]
private let lips = [61, 146, 91, 181, 84, 17, 314, 405, 321, 375, 291, 409, 270, 269, 267, 0, 37, 39, 40, 185]
private let fingertips = [4, 8, 12, 16, 20]

struct LiveView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 16) {
                VStack(spacing: 12) {
                    CameraView().frame(maxHeight: .infinity)
                    DipTrace().frame(height: 120)
                }
                .frame(width: g.size.width * 0.58)
                MetricGrid()
            }
            .padding(16)
        }
        .navigationTitle("Live")
    }
}

struct CameraView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let m = store.metrics
        ZStack(alignment: .topLeading) {
            ZStack {
                Color(white: 0.06)
                if store.setting("ui.show_camera_image"), let img = store.frame {
                    Image(nsImage: img).resizable()
                }
                Canvas { ctx, size in draw(ctx, size) }
            }
            .scaleEffect(x: -1, y: 1)  // mirrored for display only; all math is unmirrored (SPEC §3)
            .clipped()

            HStack(spacing: 6) {
                badge("\(fmt(store.status.num("fps"), 0)) fps", .secondary)
                if !(store.status["camera_ok"] as? Bool ?? false) { badge("camera off", .red) }
                if !m.bool("face_present") { badge("face lost", .orange) }
                if !m.bool("calibrated") { badge("uncalibrated", .yellow) }
                if store.setting("tracking.paused") { badge("paused", .gray) }
                Spacer()
                Toggle("Show camera image", isOn: Binding(get: { store.setting("ui.show_camera_image") },
                                                          set: { store.set("ui.show_camera_image", $0); if !$0 { store.frame = nil } }))
                    .toggleStyle(.switch).controlSize(.small)
            }
            .padding(10)
        }
        // the container takes the camera's own aspect so the image and the normalized landmarks line up
        .aspectRatio((store.status.num("frame_w") ?? 16) / (store.status.num("frame_h") ?? 9), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    func badge(_ t: String, _ c: Color) -> some View {
        Text(t).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 3)
            .background(c.opacity(0.25), in: Capsule()).foregroundStyle(c == .secondary ? .white : c)
    }

    func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        guard let lm = store.landmarks else { return }
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
            let o = store.landmarks?.num("o") ?? 1
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
        for hand in (lm["hands"] as? [[[Double]]]) ?? [] {
            for i in fingertips where i < hand.count {
                let c = pt(hand[i])
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)),
                         with: .color(store.metrics.bool("rubbing") ? .red : .yellow))
            }
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    var baseline: String? = nil
    let level: Level
    var spinner = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(level.color).frame(width: 8, height: 8)
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if spinner { ProgressView().controlSize(.small) }
            }
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.5)
            Text(baseline.map { "baseline \($0)" } ?? " ").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.5, opacity: 0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(level.color.opacity(0.35)))
    }
}

struct MetricGrid: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let m = store.metrics, b = store.baseline
        let sessionMin = (m.num("since_real_break_s") ?? 0) / 60
        let squintS = m.num("squint_s") ?? 0
        let acted = store.lastActed.flatMap { Date().timeIntervalSince($0.ts) < 10 ? $0.name : nil }
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                MetricCard(title: "Blink rate /min", value: fmt(m.num("blink_rate"), 1), baseline: b.num("blink_rate").map { fmt($0, 1) },
                           level: levelHigh(m.num("blink_rate"), good: 12, warn: 8))
                MetricCard(title: "Stare now · longest", value: "\(fmt(m.num("current_stare_s"), 0))s · \(fmt(m.num("longest_stare_s"), 0))s",
                           level: levelLow(max(m.num("current_stare_s") ?? 0, m.num("longest_stare_s") ?? 0), good: 10, warn: 20))
                MetricCard(title: "Incomplete blinks", value: fmt(m.num("incomplete_pct").map { $0 * 100 }, 0, suffix: "%"),
                           level: levelLow(m.num("incomplete_pct").map { $0 * 100 }, good: 25, warn: 40))
                MetricCard(title: "PERCLOS", value: fmt(m.num("perclos").map { $0 * 100 }, 1, suffix: "%"),
                           level: levelLow(m.num("perclos").map { $0 * 100 }, good: 8, warn: 15))
                MetricCard(title: "Distance", value: fmt(m.num("distance_cm"), 0, suffix: " cm") + (m.bool("distance_stale") ? "*" : ""),
                           baseline: b.num("distance_cm").map { fmt($0, 0, suffix: " cm") },
                           level: levelHigh(m.num("distance_cm"), good: 50, warn: 40))
                MetricCard(title: "Squint", value: m.bool("squinting") ? "squinting \(Int(squintS))s" : "relaxed",
                           baseline: "Δ \(fmt(m.num("squint_delta"), 2))",
                           level: !m.bool("squinting") ? .good : squintS < 30 ? .warn : .bad)
                MetricCard(title: "Session · since break",
                           value: "\(Int((m.num("session_s") ?? 0) / 60))m · \(Int(sessionMin))m",
                           level: sessionMin < 20 ? .good : sessionMin <= 40 ? .warn : .bad)
                MetricCard(title: "Agent", value: (store.status["agent_busy"] as? Bool ?? false) ? "thinking…" : acted ?? "idle",
                           level: .none, spinner: store.status["agent_busy"] as? Bool ?? false)
            }
        }
    }
}

/// The live openness trace with blink / incomplete markers (key demo visual for incomplete blinks).
struct DipTrace: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let now = store.trace.last?.ts ?? Date().timeIntervalSince1970
        Chart {
            ForEach(Array(store.trace.enumerated()), id: \.offset) { _, s in
                LineMark(x: .value("t", s.ts - now), y: .value("o", s.o)).interpolationMethod(.monotone)
                    .foregroundStyle(.teal)
            }
            RuleMark(y: .value("complete", 0.2)).foregroundStyle(.red.opacity(0.3)).lineStyle(.init(dash: [3]))
            RuleMark(y: .value("incomplete", 0.6)).foregroundStyle(.orange.opacity(0.3)).lineStyle(.init(dash: [3]))
            ForEach(Array(store.dipMarks.enumerated()), id: \.offset) { _, d in
                PointMark(x: .value("t", d.ts - now), y: .value("o", d.o))
                    .foregroundStyle(d.kind == "incomplete" ? .orange : d.kind == "long_blink" ? .purple : .red)
                    .symbolSize(60)
                    .annotation(position: .bottom) { Text(d.kind == "incomplete" ? "half" : d.kind == "long_blink" ? "long" : "")
                        .font(.caption2).foregroundStyle(.orange) }
            }
        }
        .chartXScale(domain: -10...0)
        .chartYScale(domain: 0...1.2)
        .chartXAxisLabel("seconds")
        .padding(10)
        .background(Color(white: 0.5, opacity: 0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}
