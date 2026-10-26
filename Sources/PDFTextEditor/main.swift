import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        EngineClient.shared.warmUp()
        // With nothing opened from Finder, offer the Open panel straight away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if NSDocumentController.shared.documents.isEmpty {
                NSDocumentController.shared.openDocument(nil)
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSDocumentController.shared.openDocument(nil) }
        return false
    }
}

private func buildMainMenu() -> NSMenu {
    let appName = "PDF Text Editor"
    let main = NSMenu()

    func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        main.addItem(holder)
        return menu
    }
    func item(_ title: String, _ action: Selector?, _ key: String = "",
              _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    _ = submenu(appName, [
        item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
        .separator(),
        item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
        item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
        item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
        .separator(),
        item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"),
    ])

    let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
    let recentMenu = NSMenu(title: "Open Recent")
    recentMenu.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:))))
    recent.submenu = recentMenu
    _ = submenu("File", [
        item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"),
        recent,
        .separator(),
        item("Close", #selector(NSWindow.performClose(_:)), "w"),
        item("Save", #selector(NSDocument.save(_:)), "s"),
        item("Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]),
        item("Revert to Saved", #selector(NSDocument.revertToSaved(_:))),
    ])

    _ = submenu("Edit", [
        item("Undo", Selector(("undo:")), "z"),
        item("Redo", Selector(("redo:")), "z", [.command, .shift]),
        .separator(),
        item("Cut", #selector(NSText.cut(_:)), "x"),
        item("Copy", #selector(NSText.copy(_:)), "c"),
        item("Paste", #selector(NSText.paste(_:)), "v"),
        item("Select All", #selector(NSText.selectAll(_:)), "a"),
    ])

    _ = submenu("View", [
        item("Actual Size", #selector(EditorWindowController.zoomToActualSize(_:)), "0"),
        item("Zoom to Fit", #selector(EditorWindowController.zoomToFit(_:)), "9"),
        item("Zoom In", #selector(EditorWindowController.zoomIn(_:)), "+"),
        item("Zoom Out", #selector(EditorWindowController.zoomOut(_:)), "-"),
    ])

    let window = submenu("Window", [
        item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        item("Zoom", #selector(NSWindow.performZoom(_:))),
        .separator(),
        item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
    ])
    NSApp.windowsMenu = window
    return main
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.mainMenu = buildMainMenu()
app.run()
