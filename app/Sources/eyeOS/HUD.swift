import AppKit
import Combine
import SwiftUI

/// The ambient floating HUD (SPEC §11.4.1): a small pill over other apps that fades when all is fine and
/// brightens when something drifts. It hides whenever it could be in the way: Zen, meetings, video, calls,
/// away from the screen, or the dashboard is in front.
@MainActor
final class HUD {
    unowned let store: Store
    private var panel: OverlayPanel?
    private var sub: AnyCancellable?
    private var lastFace = Date()
    private var lastCall = Date.distantPast
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    init(store: Store) { self.store = store }

    func start() {
        sub = store.objectWillChange
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.update() }
    }

    private var shouldShow: Bool {
        let m = store.metrics, v = store.status.obj("local_vision") ?? [:]
        if m.bool("face_present") { lastFace = Date() }
        if m.str("app_category") == "call" { lastCall = Date() }  // not plain talking: it misfires and the room doesn't mind
        guard store.setting("ui.show_hud"), store.connected, store.fatal == nil, !store.inZen,
              !store.setting("tracking.paused") else { return false }
        if v.bool("ok"), ["meeting", "entertainment"].contains(v.str("situation") ?? "") { return false }
        if Date().timeIntervalSince(lastCall) < 10 || Date().timeIntervalSince(lastFace) > 60 { return false }
        if NSApp.isActive, NSApp.keyWindow?.title == "eyeOS" { return false }  // the dashboard already shows all of it
        return true
    }

    private func update() {
        guard shouldShow else { panel?.orderOut(nil); return }
        let p = panel ?? makePanel()
        if !p.isVisible {
            p.setFrameOrigin(clamped(p.frame.origin, size: p.frame.size))
            p.orderFrontRegardless()
        }
    }

    private func makePanel() -> OverlayPanel {
        let view = HUDView(onSize: { [weak self] in self?.resize(to: $0) },
                           onDrag: { [weak self] ended in self?.drag(ended: ended) },
                           onOpen: { MainWindow.show(nil) })
            .environmentObject(store)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let p = OverlayPanel(contentRect: CGRect(origin: savedOrigin(size), size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false  // NSPanel hides with its app by default; the HUD lives over other apps
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isReleasedWhenClosed = false
        p.contentView = host
        panel = p
        return p
    }

    // MARK: - position

    /// Bottom-right by default, away from the top-right banner stack.
    private func savedOrigin(_ size: CGSize) -> NSPoint {
        if let xy = UserDefaults.standard.array(forKey: "hud.origin") as? [Double], xy.count == 2 {
            return clamped(NSPoint(x: xy[0], y: xy[1]), size: size)
        }
        let vis = NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: vis.maxX - size.width - 16, y: vis.minY + 16)
    }

    /// Keeps the HUD fully on a connected screen (displays come and go).
    private func clamped(_ o: NSPoint, size: CGSize) -> NSPoint {
        let rect = CGRect(origin: o, size: size)
        let vis = (NSScreen.screens.first { $0.visibleFrame.intersects(rect) } ?? NSScreen.main)?.visibleFrame
            ?? .init(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: min(max(o.x, vis.minX), vis.maxX - size.width), y: min(max(o.y, vis.minY), vis.maxY - size.height))
    }

    /// Grows and shrinks from the corner nearest the screen edge, so hovering never pushes it off screen.
    private func resize(to size: CGSize) {
        guard let p = panel, size.width > 0, p.frame.size != size else { return }
        let f = p.frame, vis = (p.screen ?? NSScreen.main)?.visibleFrame ?? f
        let x = f.midX > vis.midX ? f.maxX - size.width : f.minX
        let y = f.midY > vis.midY ? f.maxY - size.height : f.minY
        p.setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func drag(ended: Bool) {
        guard let p = panel else { return }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, p.frame.origin) }
        guard let s = dragStart else { return }
        p.setFrameOrigin(NSPoint(x: s.origin.x + mouse.x - s.mouse.x, y: s.origin.y + mouse.y - s.mouse.y))
        if ended {
            let o = clamped(p.frame.origin, size: p.frame.size)
            p.setFrameOrigin(o)
            UserDefaults.standard.set([Double(o.x), Double(o.y)], forKey: "hud.origin")
            dragStart = nil
        }
    }
}

struct HUDView: View {
    @EnvironmentObject var store: Store
    let onSize: (CGSize) -> Void
    let onDrag: (_ ended: Bool) -> Void
    let onOpen: () -> Void
    @StateVar private var hover = false
    @StateVar private var pulse = false

    /// The dot's level, plus the break timer the pill shows when calm.
    var level: Level {
        let since = store.metrics.num("since_real_break_s") ?? 0
        let due = store.settings.num("triggers.no_break.threshold") ?? 1200
        let ls = [store.worstLevel, since >= 2 * due ? .bad : since >= due ? .warn : .good]
        return ls.contains(.bad) ? .bad : ls.contains(.warn) ? .warn : store.worstLevel
    }

    var body: some View {
        let m = store.metrics, lv = level, issue = topIssue(m)
        let calm = lv == .good || lv == .none || issue.short == "All good"
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(lv.color).frame(width: 8, height: 8)
                if calm {
                    Image(systemName: "cup.and.saucer.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(duration(m.num("since_real_break_s"))).monospacedDigit()
                } else {
                    Text(issue.short)
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            if hover {
                Text(issue.text).font(.caption).foregroundStyle(.secondary).frame(width: 200, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Break now") { store.sidecar.command("break_now") }
                    Button("Hide") { store.set("ui.show_hud", false) }
                }
                .buttonStyle(.borderless).font(.caption.weight(.medium))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(lv.color.opacity(calm ? 0 : 0.5), lineWidth: 1))
        .scaleEffect(pulse ? 1.06 : 1)
        .opacity(hover ? 1 : calm ? 0.35 : lv == .bad ? 1 : 0.8)
        .animation(.easeInOut(duration: 0.6), value: calm)
        .animation(.easeInOut(duration: 0.6), value: lv)
        .animation(.easeOut(duration: 0.2), value: hover)
        .padding(4)
        .fixedSize()
        .background(GeometryReader { g in
            Color.clear.onAppear { onSize(g.size) }.onChange(of: g.size) { _, s in onSize(s) }
        })
        .onHover { hover = $0 }
        .onTapGesture(perform: onOpen)
        .gesture(DragGesture(minimumDistance: 3).onChanged { _ in onDrag(false) }.onEnded { _ in onDrag(true) })
        .onChange(of: lv) { _, new in
            guard new == .bad else { return }  // one soft pulse on reaching "bad", never a repeating animation
            withAnimation(.spring(duration: 0.3)) { pulse = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { withAnimation(.spring(duration: 0.4)) { pulse = false } }
        }
        .help("Click to open eyeOS · drag to move")
        .preferredColorScheme(.dark)
    }
}
