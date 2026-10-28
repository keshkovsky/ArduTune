import SwiftUI
import AppKit

/// Власна підказка біля курсора: з'являється через ~0,45 с після наведення й не залежить від системних `.help`, які на кнопках над картою
/// іноді не спрацьовують з першого разу.
@MainActor
final class TipWindow {
    static let shared = TipWindow()
    private var panel: NSPanel?
    private var work: DispatchWorkItem?
    private var menuOpen = false
    private var monitor: Any?

    init() {
        // клік, клавіша чи відкрите меню ховають підказку (вона не повинна перекривати меню)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) { [weak self] e in
            MainActor.assumeIsolated { self?.cancel() }
            return e
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpen = true; self?.cancel() }
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpen = false }
        }
    }

    func schedule(_ text: String, delay: Double = 0.45) {
        cancel()
        let w = DispatchWorkItem { [weak self] in self?.show(text) }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    func cancel() { work?.cancel(); work = nil; panel?.orderOut(nil) }

    private func show(_ text: String) {
        guard !menuOpen else { return }
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        label.preferredMaxLayoutWidth = 280
        label.isSelectable = false
        let size = label.fittingSize
        let box = NSSize(width: size.width + 16, height: size.height + 10)
        label.frame = NSRect(x: 8, y: 5, width: size.width, height: size.height)
        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: box))
        bg.material = .toolTip; bg.state = .active; bg.wantsLayer = true
        bg.layer?.cornerRadius = 5; bg.layer?.masksToBounds = true
        bg.addSubview(label)
        let p = panel ?? NSPanel(contentRect: NSRect(origin: .zero, size: box), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.ignoresMouseEvents = true
        p.level = .floating; p.collectionBehavior = [.canJoinAllSpaces, .transient]
        p.contentView = bg
        let m = NSEvent.mouseLocation
        var o = NSPoint(x: m.x + 6, y: m.y - box.height - 20)
        if let vf = (NSScreen.screens.first { $0.frame.contains(m) } ?? NSScreen.main)?.visibleFrame {
            o.x = min(max(o.x, vf.minX + 4), vf.maxX - box.width - 4)
            if o.y < vf.minY + 4 { o.y = m.y + 22 }
        }
        p.setFrame(NSRect(origin: o, size: box), display: true)
        p.orderFrontRegardless()
        panel = p
        let w = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: w)
    }
}

extension View {
    /// Підказка при наведенні (текст — ключ локалізації або вже готовий рядок).
    func tip(_ text: String) -> some View {
        onHover { inside in
            if inside { TipWindow.shared.schedule(smart(text)) } else { TipWindow.shared.cancel() }
        }
        .onDisappear { TipWindow.shared.cancel() }
    }
}
