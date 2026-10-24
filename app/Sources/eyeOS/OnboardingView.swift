import AVFoundation
import SwiftUI

/// Demo mode keeps calibration warnings vague (except the blink check's); otherwise they say what went wrong.
let calibrationUnexpected = "We noticed some unexpected things during calibration that may affect the quality of the calibration."

/// First-run setup: welcome, then three short calibrations (distance, gaze, blink check). The 60 s blink
/// baseline (calibration step 3) runs in the background after the sheet closes; the Live header shows its progress.
/// Keys, Shortcuts and extra permissions live in Settings and are only needed for optional features.
struct OnboardingView: View {
    @EnvironmentObject var store: Store
    var recalibrating = false           // calibration steps only, opened from Settings / Live
    var done: () -> Void
    @StateVar private var page = 0
    @StateVar private var cameraDenied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if page > 0 { dots }
                Spacer()
                if page < 4 {
                    Button(recalibrating ? "Cancel" : "Skip", action: cancel).buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20).padding(.top, 16)
            Group {
                switch page {
                case 0: welcome
                case 1: distanceStep
                case 2: gazeStep
                case 3: blinkStep
                default: finished
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 36).padding(.bottom, 28)
        }
        .frame(width: 560, height: 500)
        .onAppear { if recalibrating { page = 1 } }
    }

    var dots: some View {
        HStack(spacing: 6) {
            ForEach(1...4, id: \.self) { i in
                Capsule().fill(i <= page ? Color.teal : Color.white.opacity(0.15)).frame(width: i == page ? 22 : 8, height: 8)
            }
        }
        .animation(.easeInOut, value: page)
    }

    func cancel() {
        store.sidecar.command("calibration_end")
        store.overlays.hideCalibrationDots()
        store.calibration = nil
        if !recalibrating { UserDefaults.standard.set(true, forKey: "onboarded") }
        done()
    }

    // MARK: pages

    var welcome: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "eye.circle.fill").font(.system(size: 72))
                .foregroundStyle(LinearGradient(colors: [.teal, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(spacing: 6) {
                Text("Welcome to eyeOS").font(.system(size: 28, weight: .bold))
                Text("Looks after your eyes while you work.").font(.title3).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                feature("lock.shield.fill", .green, "Video stays on your Mac")
                feature("timer", .teal, "20-second calibration")
                feature("moon.stars.fill", .indigo, "Silent while you're in deep focus")
            }
            .padding(.vertical, 6)
            Spacer()
            if cameraDenied {
                VStack(spacing: 8) {
                    Label("eyeOS needs the camera", systemImage: "video.slash.fill").foregroundStyle(.orange)
                    Button("Open Camera Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                    }
                }
            }
            Button(action: start) {
                Text("Get started").font(.headline).frame(width: 220, height: 30)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
        }
    }

    func feature(_ icon: String, _ color: Color, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(color)
                .frame(width: 32, height: 32).background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
            Text(text).font(.body.weight(.medium))
        }
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: page = 1
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async {
                    if ok { store.sidecar.restart(); page = 1 } else { cameraDenied = true }
                }
            }
        default: cameraDenied = true
        }
    }

    var distanceStep: some View {
        CalibrationStep(step: 1, title: "Sit back at arm's length", subtitle: "About 60 cm from the screen. Look at the screen and hold still.",
                        next: { page = 2 }) {
            HStack(spacing: 18) {
                Image(systemName: "person.fill").font(.system(size: 54))
                VStack(spacing: 4) {
                    Text("≈ 60 cm").font(.headline).foregroundStyle(.teal)
                    HStack(spacing: 0) {
                        Image(systemName: "arrowtriangle.left.fill").font(.caption2)
                        Rectangle().frame(width: 110, height: 2)
                        Image(systemName: "arrowtriangle.right.fill").font(.caption2)
                    }
                    .foregroundStyle(.teal)
                }
                Image(systemName: "laptopcomputer").font(.system(size: 58))
            }
            .foregroundStyle(.primary.opacity(0.85))
        }
    }

    var gazeStep: some View {
        CalibrationStep(step: 2, title: "Follow the dot", subtitle: "A dot moves to the center, then the four corners. Follow it with your eyes.",
                        next: { page = 3 }) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.3), lineWidth: 2).frame(width: 170, height: 110)
                ForEach(Array([CGPoint(x: 0, y: 0), CGPoint(x: -70, y: -40), CGPoint(x: 70, y: -40), CGPoint(x: 70, y: 40),
                               CGPoint(x: -70, y: 40)].enumerated()), id: \.offset) { i, p in
                    Circle().fill(i == 0 ? Color.teal : Color.teal.opacity(0.4)).frame(width: i == 0 ? 14 : 9).offset(x: p.x, y: p.y)
                }
                Image(systemName: "eye").font(.title2).offset(y: 80)
            }
            .frame(height: 170)
        }
    }

    /// Calibration step 4: three prompted blinks set this user's complete / incomplete blink thresholds.
    var blinkStep: some View {
        CalibrationStep(step: 4, title: "Blink 3 times", subtitle: "Blink 3 times normally, about a second apart. Click Start when you're ready.",
                        next: { page = 4 }) {
            let c = store.calibration?.int("step") == 4 ? store.calibration : nil
            let seen = c?.str("phase") == "failed" ? 0 : c?.int("blinks") ?? 0
            HStack(spacing: 22) {
                ForEach(0..<3, id: \.self) { i in
                    Image(systemName: i < seen ? "checkmark" : "eye")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(i < seen ? Color.mint : Color.primary.opacity(0.85))
                        .frame(width: 64, height: 64)
                        .background((i < seen ? Color.mint : Color.white).opacity(0.12), in: Circle())
                }
            }
            .animation(.easeInOut(duration: 0.2), value: seen)
        }
    }

    var finished: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.seal.fill").font(.system(size: 64)).foregroundStyle(.mint)
            Text("You're set").font(.system(size: 26, weight: .bold))
            VStack(spacing: 10) {
                Label("For the next minute eyeOS learns your normal blink rate. Just keep working.", systemImage: "eye")
                Label("When you're in deep focus, eyeOS goes silent.", systemImage: "moon.stars")
            }
            .font(.callout).foregroundStyle(.secondary).frame(maxWidth: 400, alignment: .leading)
            Spacer()
            Button {
                store.sidecar.command("calibration_end")
                store.sidecar.command("calibrate", ["step": 3])  // 60 s baseline, in the background
                UserDefaults.standard.set(true, forKey: "onboarded")
                done()
            } label: {
                Text("Start using eyeOS").font(.headline).frame(width: 220, height: 30)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
        }
    }
}

/// One calibration step: illustration, face check, Start button that becomes a progress ring,
/// then auto-advances when the sidecar reports success.
struct CalibrationStep<Art: View>: View {
    @EnvironmentObject var store: Store
    let step: Int
    let title: String
    let subtitle: String
    let next: () -> Void
    @ViewBuilder var art: Art

    var body: some View {
        let c = store.calibration?.int("step") == step ? store.calibration : nil
        let phase = c?.str("phase")
        let running = phase == "started" || phase == "progress"
        let warnings = phase == "done" ? (c?["warnings"] as? [String]) ?? [] : []
        VStack(spacing: 18) {
            Spacer(minLength: 4)
            art.frame(height: 150)
            VStack(spacing: 6) {
                Text(title).font(.system(size: 24, weight: .bold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 400)
            }
            if warnings.isEmpty { faceCheck }  // make room for the warning
            Spacer(minLength: 4)
            if phase == "failed" {
                Label(c?.obj("result")?.str("reason") ?? "That didn't work. Try again.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
            }
            if running {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.1), lineWidth: 5)
                    Circle().trim(from: 0, to: c?.num("progress") ?? 0).stroke(Color.teal, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90)).animation(.linear(duration: 0.2), value: c?.num("progress"))
                    Text("\(Int((c?.num("progress") ?? 0) * 100))%").font(.caption.monospacedDigit())
                }
                .frame(width: 48, height: 48)
            } else if phase == "done" && warnings.isEmpty {
                Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.mint).font(.headline).frame(height: 48)
            } else if phase == "done" {
                VStack(spacing: 6) {
                    Label("Saved, though it may be a little off", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow).font(.callout.weight(.semibold))
                    // the blink check's warnings say what to do differently, so they stay specific even in demo mode
                    Text(store.setting("demo.enabled") && step != 4 ? calibrationUnexpected + " We suggest you try again."
                         : warnings.joined(separator: " ") + " For the best tracking, try this step again.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 400)
                }
                HStack(spacing: 14) {
                    Button("Continue anyway") { store.calibration = nil; next() }.buttonStyle(.borderless).foregroundStyle(.secondary)
                    startButton("Try again")
                }
            } else {
                startButton(phase == "failed" ? "Try again" : "Start")
            }
        }
        .onChange(of: phase) {
            if step == 2, phase == "done" || phase == "failed" { store.overlays.hideCalibrationDots() }
            if phase == "done" && warnings.isEmpty {  // a weak result waits for the user to choose
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { store.calibration = nil; next() }
            }
        }
    }

    func startButton(_ label: String) -> some View {
        Button {
            store.sidecar.command("calibrate", ["step": step])
            if step == 2 { store.overlays.showCalibrationDots() }
        } label: {
            Text(label).font(.headline).frame(width: 220, height: 30)
        }
        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
        .disabled(!store.connected || !store.metrics.bool("face_present"))
    }

    @ViewBuilder var faceCheck: some View {
        if !store.connected {
            Pill(text: "Starting eyeOS…", color: .secondary, spinning: true)
        } else if store.metrics.bool("face_present") {
            Pill(text: "Face found", icon: "checkmark.circle.fill", color: .mint)
        } else {
            Pill(text: "Looking for your face…", icon: "person.crop.circle.badge.questionmark", color: .orange)
        }
    }
}

/// Full-screen dot for gaze calibration; position follows the sidecar's `target`.
struct CalibrationDots: View {
    @EnvironmentObject var store: Store
    var body: some View {
        GeometryReader { g in
            let t = store.calibration?.str("target") ?? "center"
            let inset: CGFloat = 40
            let pos: CGPoint = switch t {
            case "top_left": .init(x: inset, y: inset)
            case "top_right": .init(x: g.size.width - inset, y: inset)
            case "bottom_right": .init(x: g.size.width - inset, y: g.size.height - inset)
            case "bottom_left": .init(x: inset, y: g.size.height - inset)
            default: .init(x: g.size.width / 2, y: g.size.height / 2)
            }
            ZStack {
                Color.black.opacity(0.9)
                Circle().fill(.teal).frame(width: 26, height: 26).position(pos).animation(.easeInOut(duration: 0.4), value: t)
            }
        }
        .ignoresSafeArea()
    }
}
