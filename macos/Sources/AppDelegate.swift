import AppKit
import OSLog
import GhosttyKit

class AppDelegate: NSObject, ObservableObject, NSApplicationDelegate, GhosttyAppStateDelegate {
    // The application logger. We should probably move this at some point to a dedicated
    // class/struct but for now it lives here! 🤷‍♂️
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: AppDelegate.self)
    )
    
    /// Various menu items so that we can programmatically sync the keyboard shortcut with the Ghostty config.
    @IBOutlet private var menuReloadConfig: NSMenuItem?
    @IBOutlet private var menuQuit: NSMenuItem?
    
    @IBOutlet private var menuNewWindow: NSMenuItem?
    @IBOutlet private var menuNewTab: NSMenuItem?
    @IBOutlet private var menuSplitHorizontal: NSMenuItem?
    @IBOutlet private var menuSplitVertical: NSMenuItem?
    @IBOutlet private var menuClose: NSMenuItem?
    @IBOutlet private var menuCloseWindow: NSMenuItem?
    
    @IBOutlet private var menuCopy: NSMenuItem?
    @IBOutlet private var menuPaste: NSMenuItem?

    @IBOutlet private var menuToggleFullScreen: NSMenuItem?
    @IBOutlet private var menuZoomSplit: NSMenuItem?
    @IBOutlet private var menuPreviousSplit: NSMenuItem?
    @IBOutlet private var menuNextSplit: NSMenuItem?
    @IBOutlet private var menuSelectSplitAbove: NSMenuItem?
    @IBOutlet private var menuSelectSplitBelow: NSMenuItem?
    @IBOutlet private var menuSelectSplitLeft: NSMenuItem?
    @IBOutlet private var menuSelectSplitRight: NSMenuItem?
    
    /// The dock menu
    private var dockMenu: NSMenu = NSMenu()
    
    /// The ghostty global state. Only one per process.
    private var ghostty: Ghostty.AppState = Ghostty.AppState()
    
    /// Manages windows and tabs, ensuring they're allocated/deallocated correctly
    private var windowManager: PrimaryWindowManager!
    
    override init() {
        super.init()
        
        ghostty.delegate = self
        windowManager = PrimaryWindowManager(ghostty: self.ghostty)
    }
    
    //MARK: - NSApplicationDelegate
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            // Disable the automatic full screen menu item because we handle
            // it manually.
            "NSFullScreenMenuItemEverywhere": false,
        ])
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // System settings overrides
        UserDefaults.standard.register(defaults: [
            // Disable this so that repeated key events make it through to our terminal views.
            "ApplePressAndHoldEnabled": false,
        ])
        
        // Let's launch our first window.
        // TODO: we should detect if we restored windows and if so not launch a new window.
        windowManager.addInitialWindow()
        
        // Initial config loading
        configDidReload(ghostty)
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let windows = NSApplication.shared.windows
        if (windows.isEmpty) { return .terminateNow }
        
        // This probably isn't fully safe. The isEmpty check above is aspirational, it doesn't
        // quite work with SwiftUI because windows are retained on close. So instead we check
        // if there are any that are visible. I'm guessing this breaks under certain scenarios.
        if (windows.allSatisfy { !$0.isVisible }) { return .terminateNow }
        
        // If the user is shutting down, restarting, or logging out, we don't confirm quit.
        why: if let event = NSAppleEventManager.shared().currentAppleEvent {
            // If all Ghostty windows are in the background (i.e. you Cmd-Q from the Cmd-Tab
            // view), then this is null. I don't know why (pun intended) but we have to
            // guard against it.
            guard let keyword = AEKeyword("why?") else { break why }
            
            if let why = event.attributeDescriptor(forKeyword: keyword) {
                switch (why.typeCodeValue) {
                case kAEShutDown:
                    fallthrough
                    
                case kAERestart:
                    fallthrough
                    
                case kAEReallyLogOut:
                    return .terminateNow
                    
                default:
                    break
                }
            }
        }
        
        // If our app says we don't need to confirm, we can exit now.
        if (!ghostty.needsConfirmQuit) { return .terminateNow }
        
        // We have some visible window. Show an app-wide modal to confirm quitting.
        let alert = NSAlert()
        alert.messageText = "Quit Ghostty?"
        alert.informativeText = "All terminal sessions will be terminated."
        alert.addButton(withTitle: "Close Ghostty")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        switch (alert.runModal()) {
        case .alertFirstButtonReturn:
            return .terminateNow
            
        default:
            return .terminateCancel
        }
    }
    
    /// This is called when the application is already open and someone double-clicks the icon
    /// or clicks the dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // If we have visible windows then we allow macOS to do its default behavior
        // of focusing one of them.
        guard !flag else { return true }
        
        // No visible windows, open a new one.
        windowManager.newWindow()
        return false
    }
    
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        // Ghostty will validate as well but we can avoid creating an entirely new
        // surface by doing our own validation here. We can also show a useful error
        // this way.
        var isDirectory = ObjCBool(true)
        guard FileManager.default.fileExists(atPath: filename, isDirectory: &isDirectory) else { return false }
        guard isDirectory.boolValue else {
            let alert = NSAlert()
            alert.messageText = "Dropped File is Not a Directory"
            alert.informativeText = "Ghostty can currently only open directory paths."
            alert.addButton(withTitle: "OK")
            alert.alertStyle = .warning
            _ = alert.runModal()
            return false
        }
        
        // Build our config
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = filename
            
        // If we don't have a window open through the window manager, we launch
        // a new window.
        guard let mainWindow = windowManager.mainWindow else {
            windowManager.addNewWindow(withBaseConfig: config)
            return true
        }
        
        // Add a new tab
        windowManager.addNewTab(to: mainWindow, withBaseConfig: config)
        return true
    }
    
    /// This is called for the dock right-click menu.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        return dockMenu
    }
    
    /// Sync all of our menu item keyboard shortcuts with the Ghostty configuration.
    private func syncMenuShortcuts() {
        guard ghostty.config != nil else { return }
        
        syncMenuShortcut(action: "reload_config", menuItem: self.menuReloadConfig)
        syncMenuShortcut(action: "quit", menuItem: self.menuQuit)
        
        syncMenuShortcut(action: "new_window", menuItem: self.menuNewWindow)
        syncMenuShortcut(action: "new_tab", menuItem: self.menuNewTab)
        syncMenuShortcut(action: "close_surface", menuItem: self.menuClose)
        syncMenuShortcut(action: "close_window", menuItem: self.menuCloseWindow)
        syncMenuShortcut(action: "new_split:right", menuItem: self.menuSplitHorizontal)
        syncMenuShortcut(action: "new_split:down", menuItem: self.menuSplitVertical)
        
        syncMenuShortcut(action: "copy_to_clipboard", menuItem: self.menuCopy)
        syncMenuShortcut(action: "paste_from_clipboard", menuItem: self.menuPaste)
        
        syncMenuShortcut(action: "toggle_fullscreen", menuItem: self.menuToggleFullScreen)
        syncMenuShortcut(action: "toggle_split_zoom", menuItem: self.menuZoomSplit)
        syncMenuShortcut(action: "goto_split:previous", menuItem: self.menuPreviousSplit)
        syncMenuShortcut(action: "goto_split:next", menuItem: self.menuNextSplit)
        syncMenuShortcut(action: "goto_split:top", menuItem: self.menuSelectSplitAbove)
        syncMenuShortcut(action: "goto_split:bottom", menuItem: self.menuSelectSplitBelow)
        syncMenuShortcut(action: "goto_split:left", menuItem: self.menuSelectSplitLeft)
        syncMenuShortcut(action: "goto_split:right", menuItem: self.menuSelectSplitRight)
        
        // Dock menu
        reloadDockMenu()
    }
    
    /// Syncs a single menu shortcut for the given action. The action string is the same
    /// action string used for the Ghostty configuration.
    private func syncMenuShortcut(action: String, menuItem: NSMenuItem?) {
        guard let cfg = ghostty.config else { return }
        guard let menu = menuItem else { return }
        
        let trigger = ghostty_config_trigger(cfg, action, UInt(action.count))
        guard let equiv = Ghostty.keyEquivalent(key: trigger.key) else {
            Self.logger.debug("no keyboard shorcut set for action=\(action)")
            return
        }
        
        menu.keyEquivalent = equiv
        menu.keyEquivalentModifierMask = Ghostty.eventModifierFlags(mods: trigger.mods)
    }
    
    private func focusedSurface() -> ghostty_surface_t? {
        guard let window = NSApp.keyWindow as? PrimaryWindow else { return nil }
        return window.focusedSurfaceWrapper.surface
    }
    
    private func splitMoveFocus(direction: Ghostty.SplitFocusDirection) {
        guard let surface = focusedSurface() else { return }
        ghostty.splitMoveFocus(surface: surface, direction: direction)
    }
    
    //MARK: - GhosttyAppStateDelegate
    
    func configDidReload(_ state: Ghostty.AppState) {
        // Config could change keybindings, so update everything that depends on that
        syncMenuShortcuts()
        windowManager.relabelTabs()
        
        // Config could change window appearance
        syncAppearance()
        
        // If we have configuration errors, we need to show them.
        let c = ConfigurationErrorsController.sharedInstance
        c.model.errors = state.configErrors()
        if (c.model.errors.count > 0) {
            if (c.window == nil || !c.window!.isVisible) {
                c.showWindow(self)
            }
        }
    }
    
    /// Sync the appearance of our app with the theme specified in the config.
    private func syncAppearance() {
        guard let theme = ghostty.windowTheme else { return }
        switch (theme) {
        case "dark":
            let appearance = NSAppearance(named: .darkAqua)
            NSApplication.shared.appearance = appearance
            
        case "light":
            let appearance = NSAppearance(named: .aqua)
            NSApplication.shared.appearance = appearance
            
        default:
            NSApplication.shared.appearance = nil
        }
    }
    
    //MARK: - Dock Menu
    
    private func reloadDockMenu() {
        let newWindow = NSMenuItem(title: "New Window", action: #selector(newWindow), keyEquivalent: "")
        let newTab = NSMenuItem(title: "New Tab", action: #selector(newTab), keyEquivalent: "")
        
        dockMenu.removeAllItems()
        dockMenu.addItem(newWindow)
        dockMenu.addItem(newTab)
    }
    
    //MARK: - IB Actions
    
    @IBAction func reloadConfig(_ sender: Any?) {
        ghostty.reloadConfig()
    }
    
    @IBAction func newWindow(_ sender: Any?) {
        windowManager.newWindow()
        
        // We also activate our app so that it becomes front. This may be
        // necessary for the dock menu.
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @IBAction func newTab(_ sender: Any?) {
        windowManager.newTab()
        
        // We also activate our app so that it becomes front. This may be
        // necessary for the dock menu.
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @IBAction func closeWindow(_ sender: Any) {
        guard let currentWindow = NSApp.keyWindow else { return }
        currentWindow.close()
    }

    @IBAction func close(_ sender: Any) {
        guard let surface = focusedSurface() else {
            self.closeWindow(self)
            return
        }

        ghostty.requestClose(surface: surface)
    }
    
    @IBAction func splitHorizontally(_ sender: Any) {
        guard let surface = focusedSurface() else { return }
        ghostty.split(surface: surface, direction: GHOSTTY_SPLIT_RIGHT)
    }
    
    @IBAction func splitVertically(_ sender: Any) {
        guard let surface = focusedSurface() else { return }
        ghostty.split(surface: surface, direction: GHOSTTY_SPLIT_DOWN)
    }
    
    @IBAction func splitZoom(_ sender: Any) {
        guard let surface = focusedSurface() else { return }
        ghostty.splitToggleZoom(surface: surface)
    }
    
    @IBAction func splitMoveFocusPrevious(_ sender: Any) {
        splitMoveFocus(direction: .previous)
    }
    
    @IBAction func splitMoveFocusNext(_ sender: Any) {
        splitMoveFocus(direction: .next)
    }
    
    @IBAction func splitMoveFocusAbove(_ sender: Any) {
        splitMoveFocus(direction: .top)
    }
    
    @IBAction func splitMoveFocusBelow(_ sender: Any) {
        splitMoveFocus(direction: .bottom)
    }
    
    @IBAction func splitMoveFocusLeft(_ sender: Any) {
        splitMoveFocus(direction: .left)
    }
    
    @IBAction func splitMoveFocusRight(_ sender: Any) {
        splitMoveFocus(direction: .right)
    }
    
    @IBAction func showHelp(_ sender: Any) {
        guard let url = URL(string: "https://github.com/mitchellh/ghostty") else { return }
        NSWorkspace.shared.open(url)
    }
    
    @IBAction func toggleFullScreen(_ sender: Any) {
        guard let surface = focusedSurface() else { return }
        ghostty.toggleFullscreen(surface: surface)
    }
}
