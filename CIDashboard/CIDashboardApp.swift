import AppKit
import SwiftUI

@main
struct CIDashboardApp: App {
    @State private var store = DashboardStore()

    var body: some Scene {
        MenuBarExtra {
            DashboardView(store: store, inWindow: false)
                .frame(width: 460, height: 600)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Window("CI Dashboard", id: "dashboard") {
            DashboardView(store: store, inWindow: true)
                .frame(minWidth: 520, minHeight: 480)
                // A Dock icon while the window is open, so Cmd-Tab reaches it; menu-bar only otherwise.
                .onAppear { NSApp.setActivationPolicy(.regular) }
                .onDisappear { NSApp.setActivationPolicy(.accessory) }
                .task { await Snapshotter.runIfRequested(store: store) }
        }
        .defaultSize(width: 640, height: 780)

        Settings {
            SettingsView(store: store)
        }
    }
}

struct MenuBarLabel: View {
    let store: DashboardStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: StatusIcon.image(store.overall.level, refreshing: store.lastRefresh == nil))
            .accessibilityLabel("CI status: \(StatusIcon.word(store.overall.level))")
            .task {
                // `--open-window` opens the dashboard window at launch (handy for screenshots and for a
                // login item that should show the window).
                if CommandLine.arguments.contains("--open-window") {
                    openWindow(id: "dashboard")
                    NSApp.activate()
                }
            }
    }
}

enum StatusIcon {
    static func color(_ level: OverallLevel) -> NSColor {
        switch level {
        case .green: .systemGreen
        case .blue: .systemBlue
        case .orange: .systemOrange
        case .red: .systemRed
        }
    }

    static func word(_ level: OverallLevel) -> String {
        switch level {
        case .green: "all clear"
        case .blue: "running"
        case .orange: "needs a look"
        case .red: "problem"
        }
    }

    /// A small gauge glyph: a ring, filled with the status colour. Not a template image, so the colour shows.
    static func image(_ level: OverallLevel, refreshing: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5))
            ring.lineWidth = 1.5
            NSColor.labelColor.withAlphaComponent(0.85).setStroke()
            ring.stroke()
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 5.5, dy: 5.5))
            (refreshing ? NSColor.tertiaryLabelColor : color(level)).setFill()
            dot.fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// `--snapshot-to <file.png>`: after the first live refresh, save a picture of the dashboard window (the app's own
/// window, so no screen-recording permission is needed). Used to verify the app with real data.
@MainActor
enum Snapshotter {
    static func runIfRequested(store: DashboardStore) async {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot-to"), i + 1 < args.count else { return }
        let path = args[i + 1]
        while store.lastRefresh == nil { try? await Task.sleep(for: .milliseconds(250)) }
        try? await Task.sleep(for: .seconds(1.5))
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("dashboard") == true || $0.title == "CI Dashboard" }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
