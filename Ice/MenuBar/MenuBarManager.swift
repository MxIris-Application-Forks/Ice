//
//  MenuBarManager.swift
//  Ice
//

import Bridging
import Combine
import OSLog
import SwiftUI

/// Manager for the state of the menu bar.
@MainActor
final class MenuBarManager: ObservableObject {
    /// The average color of portion of the desktop background below the menu bar.
    @Published private(set) var averageColor: CGColor?

    /// A Boolean value that indicates whether the menu bar is either always hidden
    /// by the system, or automatically hidden and shown by the system based on the
    /// location of the mouse.
    @Published private(set) var isMenuBarHiddenBySystem = false

    private(set) weak var appState: AppState?

    private(set) var sections = [MenuBarSection]()

    let appearanceManager: MenuBarAppearanceManager

    let iceBarPanel: IceBarPanel

    private let encoder = JSONEncoder()

    private let decoder = JSONDecoder()

    private var applicationMenuFrames = [CGDirectDisplayID: CGRect]()

    private var isHidingApplicationMenus = false

    private var canUpdateAverageColor = false

    private var cancellables = Set<AnyCancellable>()

    /// Initializes a new menu bar manager instance.
    init(appState: AppState) {
        self.appearanceManager = MenuBarAppearanceManager(appState: appState)
        self.iceBarPanel = IceBarPanel(appState: appState)
        self.appState = appState
    }

    /// Performs the initial setup of the menu bar.
    func performSetup() {
        initializeSections()
        configureCancellables()
        appearanceManager.performSetup()
        iceBarPanel.performSetup()
    }

    /// Performs the initial setup of the menu bar's section list.
    private func initializeSections() {
        // make sure initialization can only happen once
        guard sections.isEmpty else {
            Logger.menuBarManager.warning("Sections already initialized")
            return
        }

        sections = [
            MenuBarSection(name: .visible),
            MenuBarSection(name: .hidden),
            MenuBarSection(name: .alwaysHidden),
        ]

        // assign the global app state to each section
        if let appState {
            for section in sections {
                section.assignAppState(appState)
            }
        }
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        NSApp.publisher(for: \.currentSystemPresentationOptions)
            .sink { [weak self] options in
                guard let self else {
                    return
                }
                let hidden = options.contains(.hideMenuBar) || options.contains(.autoHideMenuBar)
                isMenuBarHiddenBySystem = hidden
            }
            .store(in: &c)

        // handle focusedApp rehide strategy
        NSWorkspace.shared.publisher(for: \.frontmostApplication)
            .sink { [weak self] _ in
                if
                    let self,
                    let appState,
                    case .focusedApp = appState.settingsManager.generalSettingsManager.rehideStrategy,
                    let hiddenSection = section(withName: .hidden)
                {
                    Task {
                        try await Task.sleep(for: .seconds(0.1))
                        hiddenSection.hide()
                    }
                }
            }
            .store(in: &c)

        // store the application menu frames
        Timer.publish(every: 1, on: .main, in: .default)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                applicationMenuFrames = getApplicationMenuFramesForAllDisplays()
            }
            .store(in: &c)

        if
            let appState,
            let settingsWindow = appState.settingsWindow
        {
            Publishers.CombineLatest(
                settingsWindow.publisher(for: \.isVisible),
                iceBarPanel.publisher(for: \.isVisible)
            )
            .sink { [weak self] settingsIsVisible, iceBarIsVisible in
                guard let self else {
                    return
                }
                if settingsIsVisible || iceBarIsVisible {
                    canUpdateAverageColor = true
                    updateAverageColor()
                } else {
                    canUpdateAverageColor = false
                }
            }
            .store(in: &c)
        }

        Timer.publish(every: 5, on: .main, in: .default)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                updateAverageColor()
            }
            .store(in: &c)

        // hide application menus when a section is shown (if applicable)
        Publishers.MergeMany(sections.map { $0.controlItem.$state })
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard
                    let self,
                    let appState,
                    !isMenuBarHiddenBySystem,
                    !appState.isActiveSpaceFullscreen,
                    appState.settingsManager.advancedSettingsManager.hideApplicationMenus
                else {
                    return
                }
                if sections.contains(where: { $0.controlItem.state != .hideItems }) {
                    guard let screen = NSScreen.main else {
                        return
                    }

                    let displayID = screen.displayID

                    // get the application menu frame for the display
                    guard let applicationMenuFrame = applicationMenuFrames[displayID] else {
                        return
                    }

                    let items = MenuBarItem.getMenuBarItemsCoreGraphics(for: displayID, onScreenOnly: true)

                    // get the leftmost item on the screen; the application menu should
                    // be hidden if the item's minX is close to the maxX of the menu
                    guard let leftmostItem = items.min(by: { $0.frame.minX < $1.frame.minX }) else {
                        return
                    }

                    // offset the leftmost item's minX by its width to give ourselves
                    // a little wiggle room
                    let offsetMinX = leftmostItem.frame.minX - leftmostItem.frame.width

                    // if the offset value is less than or equal to the maxX of the
                    // application menu frame, activate the app to hide the menu
                    if offsetMinX <= applicationMenuFrame.maxX {
                        hideApplicationMenus()
                    }
                } else if
                    isHidingApplicationMenus,
                    appState.settingsWindow?.isVisible == false
                {
                    Task {
                        try await Task.sleep(for: .milliseconds(25))
                        self.showApplicationMenus()
                    }
                }
            }
            .store(in: &c)

        // propagate changes from all sections
        for section in sections {
            section.objectWillChange
                .sink { [weak self] in
                    self?.objectWillChange.send()
                }
                .store(in: &c)
        }

        cancellables = c
    }

    func updateAverageColor() {
        guard canUpdateAverageColor else {
            return
        }

        guard
            let screen = NSScreen.main,
            let window = WindowInfo.getMenuBarWindow(for: screen.displayID)
        else {
            return
        }

        var bounds = window.frame
        bounds.size.height = 1
        bounds.origin.x = bounds.midX
        bounds.size.width /= 2

        guard
            let image = Bridging.captureWindow(window.windowID, screenBounds: bounds, option: []),
            let averageColor = image.averageColor(resolution: .low, options: .ignoreAlpha)
        else {
            return
        }

        if self.averageColor != averageColor {
            self.averageColor = averageColor
        }
    }

    /// Returns the frames of each item in the application menu for the given display.
    func getApplicationMenuItemFrames(for display: CGDirectDisplayID) throws -> [CGRect] {
        let menuBar = try AccessibilityMenuBar(display: display)
        return try menuBar.menuBarItems().map { try $0.frame() }
    }

    /// Returns the frames of the application menus for all displays.
    func getApplicationMenuFramesForAllDisplays() -> [CGDirectDisplayID: CGRect] {
        var frames = [CGDirectDisplayID: CGRect]()
        for screen in NSScreen.screens {
            let displayID = screen.displayID
            do {
                let itemFrames = try getApplicationMenuItemFrames(for: displayID)
                frames[displayID] = itemFrames.reduce(.zero, CGRectUnion)
            } catch {
                Logger.menuBarManager.error(
                    """
                    Couldn't get application menu frame for display \(displayID), \
                    error: \(error)
                    """
                )
            }
        }
        return frames
    }

    /// Shows the right-click menu.
    func showRightClickMenu(at point: CGPoint) {
        let menu = NSMenu(title: "Ice")

        let editItem = NSMenuItem(
            title: "Edit Menu Bar Appearance…",
            action: #selector(showAppearanceEditorPopover),
            keyEquivalent: ""
        )
        editItem.target = self
        menu.addItem(editItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Ice Settings…",
            action: #selector(AppDelegate.openSettingsWindow),
            keyEquivalent: ","
        )
        menu.addItem(settingsItem)

        menu.popUp(positioning: nil, at: point, in: nil)
    }

    func hideApplicationMenus() {
        guard let appState else {
            Logger.menuBarManager.error("Error hiding application menus: Missing app state")
            return
        }
        appState.activate(withPolicy: .regular)
        isHidingApplicationMenus = true
    }

    func showApplicationMenus() {
        guard let appState else {
            Logger.menuBarManager.error("Error showing application menus: Missing app state")
            return
        }
        appState.deactivate(withPolicy: .accessory)
        isHidingApplicationMenus = false
    }

    func toggleApplicationMenus() {
        if isHidingApplicationMenus {
            showApplicationMenus()
        } else {
            hideApplicationMenus()
        }
    }

    /// Shows the appearance editor popover, centered under the menu bar.
    @objc private func showAppearanceEditorPopover() {
        guard let appState else {
            Logger.menuBarManager.error("Error showing appearance editor popover: Missing app state")
            return
        }
        let panel = MenuBarAppearanceEditorPanel(appState: appState)
        panel.orderFrontRegardless()
        panel.showAppearanceEditorPopover()
    }

    /// Returns the menu bar section with the given name.
    func section(withName name: MenuBarSection.Name) -> MenuBarSection? {
        sections.first { $0.name == name }
    }

    /// Returns the stored frame of the application menu for the given display.
    func getStoredApplicationMenuFrame(for display: CGDirectDisplayID) -> CGRect? {
        applicationMenuFrames[display]
    }
}

// MARK: MenuBarManager: BindingExposable
extension MenuBarManager: BindingExposable { }

// MARK: - Logger
private extension Logger {
    static let menuBarManager = Logger(category: "MenuBarManager")
}
