//
//  BucketDropApp.swift
//  BucketDrop
//
//  Created by Fayaz Ahmed Aralikatti on 12/01/26.
//

import SwiftUI
import SwiftData
import AppKit

// MARK: - Popover Background View
class PopoverBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.set()
        dirtyRect.fill()
    }
}

// MARK: - Drop Target View (overlay for status bar button)
class StatusBarDropTargetView: NSView {
    var onFilesDropped: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        layer?.cornerRadius = 4
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        layer?.cornerRadius = 4
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        layer?.backgroundColor = nil
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        layer?.backgroundColor = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        layer?.backgroundColor = nil
        let pasteboard = sender.draggingPasteboard
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty else {
            return false
        }
        onFilesDropped?(urls)
        return true
    }

    // Pass through mouse events to the button underneath
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

@main
struct BucketDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([UploadedFile.self])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
    
    var body: some Scene {
        Settings {
            SettingsView()
        }
        .modelContainer(sharedModelContainer)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var modelContainer: ModelContainer?
    var settingsWindow: NSWindow?
    var popoverBackgroundView: PopoverBackgroundView?
    var dropTargetView: StatusBarDropTargetView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        // Setup model container
        let schema = Schema([UploadedFile.self])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        modelContainer = try? ModelContainer(for: schema, configurations: [modelConfiguration])

        // Setup status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "BucketDrop")
            button.action = #selector(togglePopover)
            button.target = self

            // Add drop target overlay
            let dropView = StatusBarDropTargetView(frame: button.bounds)
            dropView.autoresizingMask = [.width, .height]
            dropView.onFilesDropped = { [weak self] urls in
                self?.handleDroppedFiles(urls)
            }
            button.addSubview(dropView)
            dropTargetView = dropView
        }

        // Setup popover
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 320, height: 460)
        popover?.behavior = .semitransient
        popover?.animates = true
        popover?.delegate = self

        let contentView = ContentView()
            .modelContainer(modelContainer!)
            .environment(\.openSettingsAction, OpenSettingsAction { [weak self] in
                self?.openSettings()
            })
        popover?.contentViewController = NSHostingController(rootView: contentView)
    }

    private func handleDroppedFiles(_ urls: [URL]) {
        // Open popover and trigger upload
        if let button = statusItem?.button, let popover = popover {
            if !popover.isShown {
                popoverBackgroundView?.removeFromSuperview()
                popoverBackgroundView = nil

                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                popover.contentViewController?.view.window?.makeKey()

                if let contentView = popover.contentViewController?.view,
                   let frameView = contentView.window?.contentView?.superview {
                    let bgView = PopoverBackgroundView(frame: frameView.bounds)
                    bgView.autoresizingMask = [.width, .height]
                    frameView.addSubview(bgView, positioned: .below, relativeTo: frameView)
                    popoverBackgroundView = bgView
                }
            }
        }

        // Post notification for ContentView to handle the upload
        NotificationCenter.default.post(name: .filesDroppedOnStatusBar, object: nil, userInfo: ["urls": urls])
    }

    @objc func togglePopover() {
        guard let popover = popover, let button = statusItem?.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Clean up any existing background view before showing
            popoverBackgroundView?.removeFromSuperview()
            popoverBackgroundView = nil

            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()

            // Add solid white background to popover (including the arrow/notch)
            if let contentView = popover.contentViewController?.view,
               let frameView = contentView.window?.contentView?.superview {
                let bgView = PopoverBackgroundView(frame: frameView.bounds)
                bgView.autoresizingMask = [.width, .height]
                frameView.addSubview(bgView, positioned: .below, relativeTo: frameView)
                popoverBackgroundView = bgView
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        // Clean up background view when popover closes
        popoverBackgroundView?.removeFromSuperview()
        popoverBackgroundView = nil
    }
    
    func openSettings() {
        // Close popover first
        popover?.performClose(nil)
        
        // Check if settings window already exists
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        // Create settings window
        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)
        
        let window = NSWindow(contentViewController: hostingController)
        window.title = "BucketDrop Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        
        // Center the window on screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowSize = window.frame.size
            let x = screenFrame.origin.x + (screenFrame.width - windowSize.width) / 2
            let y = screenFrame.origin.y + (screenFrame.height - windowSize.height) / 2
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        
        settingsWindow = window
        
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// Custom environment key for opening settings
struct OpenSettingsAction {
    let action: () -> Void
    
    func callAsFunction() {
        action()
    }
}

struct OpenSettingsActionKey: EnvironmentKey {
    static let defaultValue = OpenSettingsAction { }
}

extension EnvironmentValues {
    var openSettingsAction: OpenSettingsAction {
        get { self[OpenSettingsActionKey.self] }
        set { self[OpenSettingsActionKey.self] = newValue }
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let filesDroppedOnStatusBar = Notification.Name("filesDroppedOnStatusBar")
}
