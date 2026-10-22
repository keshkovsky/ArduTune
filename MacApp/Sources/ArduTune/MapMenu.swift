import SwiftUI
import MapKit
import AppKit
import Observation

// MARK: - POI

struct POI: Codable, Identifiable, Equatable { var id = UUID(); var name: String; var lat: Double; var lon: Double }

@Observable
final class POIStore {
    var items: [POI] = [] { didSet { save() } }
    init() {
        if let d = UserDefaults.standard.data(forKey: "map.pois"), let l = try? JSONDecoder().decode([POI].self, from: d) { items = l }
    }
    private func save() { if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: "map.pois") } }
}

// MARK: - Діалог введення

enum Prompt {
    /// Показує вікно з полями вводу. Повертає введені значення або nil, якщо скасовано.
    static func ask(_ title: String, message: String? = nil, fields: [(label: String, value: String)]) -> [String]? {
        let a = NSAlert()
        a.messageText = tr(title)
        if let m = message { a.informativeText = tr(m) }
        a.addButton(withTitle: "OK"); a.addButton(withTitle: String(localized: "Скасувати"))
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        var tfs: [NSTextField] = []
        for f in fields {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 8
            let l = NSTextField(labelWithString: tr(f.label)); l.frame.size.width = 110
            l.widthAnchor.constraint(equalToConstant: 110).isActive = true
            let t = NSTextField(string: f.value); t.widthAnchor.constraint(equalToConstant: 200).isActive = true
            tfs.append(t); row.addArrangedSubview(l); row.addArrangedSubview(t); stack.addArrangedSubview(row)
        }
        stack.frame = NSRect(x: 0, y: 0, width: 330, height: CGFloat(fields.count) * 28)
        a.accessoryView = stack
        a.window.initialFirstResponder = tfs.first
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return tfs.map { $0.stringValue }
    }
    static func number(_ s: String) -> Double? { Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) }
}

// MARK: - Правий клік на карті

final class ActionBox: NSObject {
    let f: () -> Void
    init(_ f: @escaping () -> Void) { self.f = f }
    @objc func run() { f() }
}

/// Прозорий шар, що перехоплює лише правий клік (і Ctrl+клік); решта подій проходять до карти.
struct RightClickCatcher: NSViewRepresentable {
    var onRightClick: (CGPoint, NSView, NSEvent) -> Void
    func makeNSView(context: Context) -> CatcherView { let v = CatcherView(); v.handler = onRightClick; return v }
    func updateNSView(_ v: CatcherView, context: Context) { v.handler = onRightClick }

    final class CatcherView: NSView {
        var handler: ((CGPoint, NSView, NSEvent) -> Void)?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent else { return nil }
            let right = e.type == .rightMouseDown || (e.type == .leftMouseDown && e.modifierFlags.contains(.control))
            return right ? super.hitTest(point) : nil
        }
        override func rightMouseDown(with e: NSEvent) { handler?(convert(e.locationInWindow, from: nil), self, e) }
        override func mouseDown(with e: NSEvent) {
            if e.modifierFlags.contains(.control) { handler?(convert(e.locationInWindow, from: nil), self, e) } else { super.mouseDown(with: e) }
        }
    }
}

/// Будівник NSMenu з замиканнями.
final class MenuBuilder {
    static var keep: [ActionBox] = []
    let menu = NSMenu()
    private var boxes: [ActionBox] = []

    func separator(_ menu: NSMenu? = nil) { (menu ?? self.menu).addItem(.separator()) }
    /// Пункт меню. «(скоро)» показується лише для заглушок без дії; пункти, недоступні через стан (немає відео, не підключено), просто неактивні.
    func item(_ title: String, enabled: Bool = true, soon: Bool = true, checked: Bool = false, symbol: String? = nil, to menu: NSMenu? = nil, _ f: (() -> Void)? = nil) {
        let b = ActionBox(f ?? {}); boxes.append(b)
        let placeholder = f == nil && soon
        let it = NSMenuItem(title: placeholder ? tr(title) + "  (" + String(localized: "скоро") + ")" : tr(title), action: #selector(ActionBox.run), keyEquivalent: "")
        it.target = b; it.isEnabled = enabled && !placeholder; it.state = checked ? .on : .off
        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) { it.image = img }
        (menu ?? self.menu).addItem(it)
    }
    /// Непридатний для вибору заголовок меню.
    func header(_ title: String) {
        let it = NSMenuItem(title: tr(title), action: nil, keyEquivalent: ""); it.isEnabled = false
        it.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 12).withTraits(bold: true), .foregroundColor: NSColor.secondaryLabelColor])
        menu.addItem(it)
    }
    func submenu(_ title: String, enabled: Bool = true, symbol: String? = nil, to parent: NSMenu? = nil, _ build: (NSMenu) -> Void) {
        let it = NSMenuItem(title: tr(title), action: nil, keyEquivalent: "")
        let sub = NSMenu(); build(sub); it.submenu = sub; it.isEnabled = enabled
        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) { it.image = img }
        (parent ?? menu).addItem(it)
    }
    nonisolated(unsafe) static var showing = false
    /// Меню відкривається поза обробником події (інакше воно блокує обробку мишки й сайдбар «залипає»), по одному за раз.
    func show(for view: NSView, event: NSEvent) {
        guard !MenuBuilder.showing else { return }
        MenuBuilder.keep = boxes
        let screenPt = view.window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
        let menu = self.menu
        MenuBuilder.showing = true
        DispatchQueue.main.async { [weak view] in
            defer { MenuBuilder.showing = false }
            guard let view, let w = view.window else { return }
            // Меню має поміститися на екрані повністю: зсуваємо його від країв видимої області
            let size = menu.size
            let vis = (w.screen ?? NSScreen.main)?.visibleFrame ?? .zero
            var x = screenPt.x, y = screenPt.y
            if vis != .zero {
                if y - size.height < vis.minY { y = min(vis.maxY, vis.minY + size.height) }
                if x + size.width > vis.maxX { x = max(vis.minX, vis.maxX - size.width) }
            }
            menu.popUp(positioning: nil, at: NSPoint(x: x, y: y), in: nil)
        }
    }
}

extension NSFont {
    func withTraits(bold: Bool) -> NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: bold ? .boldFontMask : .unboldFontMask)
    }
}
