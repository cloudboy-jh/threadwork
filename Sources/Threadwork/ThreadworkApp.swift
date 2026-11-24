import AppKit
import Carbon
import SwiftUI

@main
struct ThreadworkApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = NetworkStore()
    private var statusItem: NSStatusItem!
    private var panel: QuickPanel!
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var localMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700),
                           styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Threadwork"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ThreadworkView().environmentObject(store))
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.grid.3x3.fill", accessibilityDescription: "Threadwork")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        statusItem.button?.toolTip = "Threadwork · ⌃⌥Space"
        registerShortcut()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.panel.isVisible == true {
                if self?.panel.attachedSheet != nil { return event }
                self?.panel.orderOut(nil); return nil
            }
            return event
        }
        store.start()
        if CommandLine.arguments.contains("--show") { showPanel() }
        if let index = CommandLine.arguments.firstIndex(of: "--capture"), CommandLine.arguments.indices.contains(index + 1) {
            showPanel()
            let path = CommandLine.arguments[index + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                guard let view = self.panel.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    print("Captured live Threadwork panel: \(path)")
                }
            }
        }
    }

    @objc private func toggle() { panel.isVisible ? panel.orderOut(nil) : showPanel() }

    private func showPanel() {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let height = min(700, frame.height - 40)
            panel.setContentSize(NSSize(width: 520, height: height))
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2,
                                         y: frame.maxY - panel.frame.height - min(100, frame.height * 0.12)))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        if panel.attachedSheet == nil { panel.orderOut(nil) }
    }

    private func registerShortcut() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { delegate.toggle() }
            return noErr
        }, 1, &spec, pointer, &handler)
        let registered = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey),
                                            EventHotKeyID(signature: 0x54485244, id: 1),
                                            GetApplicationEventTarget(), 0, &hotKey)
        if installed != noErr || registered != noErr {
            store.shortcutError = "⌃⌥Space is unavailable. Open Threadwork from the menu bar."
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}

final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
