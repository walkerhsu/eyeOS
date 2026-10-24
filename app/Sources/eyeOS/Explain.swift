import AppKit
import SwiftUI

/// What a number on screen means and, where there's math behind it, how it's computed.
struct Explainer {
    let title: String
    let meaning: String
    var math: String? = nil
    var good: String? = nil
    var source: String? = nil
}

extension View {
    /// Shows the explainer in a popover after hovering ~3 s, or right away on right-click / control-click.
    func explain(_ e: Explainer) -> some View { modifier(ExplainModifier(e: e)) }
}

private struct ExplainModifier: ViewModifier {
    let e: Explainer
    @StateVar private var shown = false
    @StateVar private var hover: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hover?.cancel()
                guard inside else { return }
                hover = Task {
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled { shown = true }
                }
            }
            .overlay(RightClickCatcher { hover?.cancel(); shown = true })
            .popover(isPresented: $shown, arrowEdge: .bottom) { ExplainCard(e: e) }
    }
}

private struct ExplainCard: View {
    let e: Explainer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(e.title, systemImage: "info.circle").font(.headline)
            Text(e.meaning).fixedSize(horizontal: false, vertical: true)
            if let m = e.math {
                section("How it's calculated", "function") {
                    Text(m).font(.callout.monospaced()).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            if let g = e.good {
                section("What's healthy", "checkmark.seal") {
                    Text(g).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let s = e.source {
                Text(s).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }

    func section(_ title: String, _ icon: String, @ViewBuilder _ body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            body().padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Transparent overlay that only claims right-clicks (and control-clicks); everything else falls through.
private struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void

    final class Catcher: NSView {
        var action: () -> Void = {}
        override func hitTest(_ p: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent else { return nil }
            let right = e.type == .rightMouseDown || (e.type == .leftMouseDown && e.modifierFlags.contains(.control))
            return right ? super.hitTest(p) : nil
        }
        override func rightMouseDown(with event: NSEvent) { action() }
        override func mouseDown(with event: NSEvent) { action() }
    }

    func makeNSView(context: Context) -> Catcher { Catcher() }
    func updateNSView(_ v: Catcher, context: Context) { v.action = action }
}

// MARK: - the catalogue

/// Explanations for every number on the Live, Log and Agent pages. Thresholds mirror metrics.py / zen.py.
enum Explain {
    static let eyeScore = Explainer(
        title: "Eye score",
        meaning: "One 0–100 number for how relaxed your eyes look right now. 100 means no strain signals. It drops as strain signals pile up.",
        math: """
        100 − penalties (each capped):
          blink rate below your normal  up to 30
          blinking far above your band  up to 15
          blink rate sliding (fatigue)  10
          incomplete blinks 20→60 %     up to 15
          drowsiness 8→20 %             up to 15
          current stare 10→30 s         up to 10
          distance 50→35 cm             up to 10
          no break 20→60 min            up to 10
          squinting now                 10
        """,
        good: "80+ relaxed · 60–79 mild strain · 40–59 working hard · <40 time to rest",
        source: "Needs your face in view and a finished calibration.")

    static let blinkRate = Explainer(
        title: "Blink rate",
        meaning: "Full blinks per minute, judged against your own normal. Too few dries the eyes (screens can cut blinking from about 17 to 4–7 a minute). Too many can mean they already feel dry or irritated. A steady slide over 10+ minutes is a fatigue sign.",
        math: """
        full blinks ÷ minutes your face was present and you weren't talking (last 60 s)
        band: low < max(8, 0.6 × normal), high > max(25, 1.6 × normal)
        normal = calibrated rate, clamped to 10–25
        slide: per-minute rates over 12 min fall ≥ 20 % (≥ 3/min), steadily
        """,
        good: "Inside your band. Talking raises blinking about 50 %, so it's paused while you speak or are on a call.",
        source: "Bentivoglio 1997 (17/min rest, 26 talking, 4.5 reading); dry-eye studies report up to twice the normal rate.")

    static let incomplete = Explainer(
        title: "Incomplete blinks",
        meaning: "The share of blinks where your lids started to close but didn't meet. Half blinks don't spread the tear film well.",
        math: "incomplete ÷ (full + incomplete) over the last 60 s\n\nIncomplete = openness dipped below 75 % but never below 20 %, bottoming out under 60 %. Needs at least 5 blinks.",
        good: "Under 25 % is green, 25–40 % amber, above 40 % red.")

    static let stare = Explainer(
        title: "Stare",
        meaning: "How long it has been since your last blink, counting only time your face is in view.",
        math: "seconds since the last full or incomplete blink (resets on every blink).\n\"Longest\" is the longest gap in the last 5 minutes.",
        good: "Under 10 s is green, 10–20 s amber, longer is red.")

    static let drowsiness = Explainer(
        title: "Drowsiness (PERCLOS)",
        meaning: "PERCLOS is the percentage of time your eyes are mostly closed. It's a standard measure of tiredness.",
        math: "frames with openness ≤ 20 % ÷ frames with your face present, over the last 60 s",
        good: "Under 8 % is green, 8–15 % amber, above 15 % suggests tiredness.")

    static let distance = Explainer(
        title: "Screen distance",
        meaning: "Roughly how far your eyes are from the camera, estimated from the apparent size of your irises.",
        math: "calibrated distance × (iris width at calibration ÷ iris width now)\nSmoothed with a rolling median. * means stale (irises not visible).",
        good: "About 50–70 cm. Green ≥ 50, amber ≥ 40, red when closer.")

    static let squint = Explainer(
        title: "Squint",
        meaning: "Whether you're narrowing your eyes compared with your relaxed calibration. Squinting often means the screen is too bright, too dim or the text is too small.",
        math: "lid tension = mean squint score (10 s, open frames) − your calibrated score\nSquinting when tension > 0.15 or average openness < 80 %",
        good: "Relaxed is green. Squinting for under 30 s is amber, longer is red.")

    static let lastBreak = Explainer(
        title: "Last break",
        meaning: "Time since you last looked away from the screen for a real break. The bar fills toward the 20-20-20 reminder.",
        math: "now − end of last break\nA break = face away or gaze off-screen for ≥ 20 s in a row. Progress = elapsed ÷ 20 min.",
        good: "Look ~6 m (20 ft) away for 20 s every 20 min. Green < 20 min, amber up to 40, red beyond.",
        source: "The webcam can't verify far focus, only that you looked away.")

    static let posture = Explainer(
        title: "Posture",
        meaning: "How your sitting posture has drifted since the start of this session, from your shoulders (MediaPipe Pose) and head. Slumping, raised shoulders or leaning in usually creep in as you get tired.",
        math: """
        reference = the first 3 min of the session (calibration until then)
        now = median over the last 30 s
        neck = nose height above shoulders ÷ shoulder width
        slumping: neck < 85 % of reference (head sinks)
        shoulders raised: same, with the shoulders lifted
        shoulders uneven: shoulder line tilts ≥ 6°
        leaning sideways: head ≥ 15 % of shoulder width off-center
        leaning in: shoulders ≥ 15 % wider, or closer by distance
        head dropping / tilted: pitch ≥ 12° down / roll ≥ 10°
        """,
        good: "Upright, near your starting position. A reminder comes after 60 s of drift.")

    static let focus = Explainer(
        title: "Focus",
        meaning: "How long this sitting has lasted (or the current Zen session). The footer shows how much of the last minute your eyes were on the screen.",
        math: "session = now − when your face reappeared after ≥ 2 min away\neyes on screen = samples with gaze on screen ÷ samples, last 60 s")

    static let screenTime = Explainer(
        title: "Screen time",
        meaning: "Total time today your face was in front of the camera.",
        math: "sum of frame intervals with a face present since midnight")
    static let breaks = Explainer(
        title: "Real breaks",
        meaning: "Times today you looked away from the screen for at least 20 seconds in a row.",
        math: "count of break events today (away or gaze off-screen ≥ 20 s)")
    static let zenTime = Explainer(
        title: "In Zen",
        meaning: "Time today in Zen mode, when eyeOS keeps measuring but stays completely silent.",
        math: "sum of finished Zen sessions today + the current one")
    static let avgBlinks = Explainer(
        title: "Average blinks / min",
        meaning: "Your average blink rate across today.",
        math: "mean of the once-a-second blink-rate samples recorded today")
    static let nudges = Explainer(
        title: "Nudges",
        meaning: "Actions the agent actually carried out today, like blink reminders or break cards.",
        math: "count of action-type tool calls today with status = done (questions and lookups don't count)")
    static let rubs = Explainer(
        title: "Eye rubs",
        meaning: "Times today a fingertip stayed near your eyes long enough to count as rubbing. Rubbing is often a sign of tired or itchy eyes.",
        math: "fingertip within 0.35 × eye spacing of an eye for ≥ 0.7 s within 1.5 s (max one per 30 s)")

    static func stats(_ def: MetricDef, range: String) -> Explainer {
        Explainer(title: "\(def.title) summary",
                  meaning: "Now is the latest reading. Average, Low and High cover the selected range (\(range)). Your baseline comes from calibration.",
                  math: "average = mean of the samples in range\nlow / high = min / max of those samples\nsamples: 1 per second (Today: stored minute samples)")
    }

    // Agent page
    static let runs = Explainer(title: "Agent runs",
                                meaning: "How many times the agent woke up today: after triggers, on the heartbeat, or when you pressed Run.",
                                math: "count of agent runs for the selected day; errors = runs that failed")
    static let toolCalls = Explainer(title: "Tool calls",
                                     meaning: "Actions the agent asked for. Not every request runs: some are declined, blocked, or still waiting for approval.",
                                     math: "requested = all tool calls\nexecuted = calls with status done")
    static let approvals = Explainer(title: "Approvals",
                                     meaning: "How often you allowed an action when eyeOS asked you first.",
                                     math: "approved ÷ (approved + declined + timed out)")
    static let outcomes = Explainer(title: "Outcomes",
                                    meaning: "Whether actions actually helped. eyeOS compares the target metric before and after each action.",
                                    math: "helped = verdicts improved or confirmed_break\n÷ all evaluated actions",
                                    source: "Example: a blink reminder counts as improved when blink rate rises ≥ 2/min afterwards.")
    static let latency = Explainer(title: "Latency",
                                   meaning: "How long a run takes from waking up to finishing.",
                                   math: "mean of (run end − run start) over today's runs")
    static let tokens = Explainer(title: "Tokens",
                                  meaning: "How much text the model read and wrote. That's a rough proxy for cost.",
                                  math: "input = prompt + cached tokens, summed over runs (shown in thousands)\nout = generated tokens")
}
