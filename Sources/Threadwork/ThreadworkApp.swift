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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = NetworkStore()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var localMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = NSHostingController(rootView: ThreadworkView().environmentObject(store))
        popover.contentSize = NSSize(width: 520, height: 700)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.grid.3x3.fill", accessibilityDescription: "Threadwork")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        statusItem.button?.toolTip = "Threadwork · ⌃⌥Space"
        registerShortcut()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.popover.isShown == true {
                if self?.popover.contentViewController?.view.window?.attachedSheet != nil { return event }
                self?.popover.performClose(nil); return nil
            }
            return event
        }
        store.start()
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.async { self.showPopover() }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--capture"), CommandLine.arguments.indices.contains(index + 1) {
            let path = CommandLine.arguments[index + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                self.showPopover()
                try? await Task.sleep(for: .milliseconds(300))
                guard self.popover.isShown,
                      let window = self.popover.contentViewController?.view.window,
                      let view = window.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    print("Threadwork capture failed: dropdown is not visible.")
                    return
                }
                print("Dropdown frame: \(window.frame); menu-bar anchor: \(self.statusItem.button?.window?.frame ?? .zero)")
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    print("Captured live Threadwork dropdown: \(path)")
                }
            }
        }
    }

    @objc private func toggle() { popover.isShown ? popover.performClose(nil) : showPopover() }

    private func showPopover() {
        guard !popover.isShown, let button = statusItem.button else { return }
        if let frame = button.window?.screen?.visibleFrame {
            popover.contentSize = NSSize(width: 520, height: min(700, frame.height - 40))
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
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
