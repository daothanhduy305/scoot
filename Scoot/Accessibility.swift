import AXSwift
import AppKit
import OSLog

struct Accessibility {

    struct Element: Positionable, Equatable {
        let role: Role

        /// The screen that the element is located on.
        let screen: NSScreen

        /// The element's frame, in Cocoa/AppKit screen (*not* window) coordinates.
        let frame: CGRect

        /// The element's frame, in Cocoa/AppKit screen coordinates.
        var screenRect: CGRect {
            frame
        }

        /// The element's frame, in Cocoa/AppKit window coordinates.
        var windowRect: CGRect {
            CGRect(x: frame.origin.x - screen.visibleFrame.origin.x,
                   y: frame.origin.y - screen.visibleFrame.origin.y,
                   width: frame.width,
                   height: frame.height)
        }

        /// The element's width.
        var width: CGFloat {
            frame.width
        }

        /// The element's height.
        var height: CGFloat {
            frame.height
        }

    }

    static func checkIfProcessIsTrusted(withPrompt showPrompt: Bool = false) -> Bool {
        UIElement.isProcessTrusted(withPrompt: showPrompt)
    }

    @discardableResult
    static func enableEnhancedUserInterfaceIfNecessary(for runningApp: NSRunningApplication) -> Bool {

        guard let app = Application(runningApp) else {
            return false
        }

        let enhancedUserInterfaceAlreadyEnabled = (try? app.attribute(.enhancedUserInterface) ?? false) ?? false

        if !enhancedUserInterfaceAlreadyEnabled {

            OSLog.main.log("Enabling AXEnhancedUserInterface for \(String(describing: runningApp.localizedName ?? "<unknown>"), privacy: .private(mask: .hash))")

            try? app.setAttribute(.enhancedUserInterface, value: true)
        }

        try? app.setAttribute("AXManualAccessibility", value: true)

        return enhancedUserInterfaceAlreadyEnabled
    }

    static func disableEnhancedUserInterface(for runningApp: NSRunningApplication) {
        guard let app = Application(runningApp) else {
            return
        }

        OSLog.main.log("Disabling AXEnhancedUserInterface for \(String(describing: runningApp.localizedName ?? "<unknown>"), privacy: .private(mask: .hash))")

        try? app.setAttribute(.enhancedUserInterface, value: false)
        // Leave AXManualAccessibility on: Chromium only re-applies it to newly loaded pages,
        // so clearing it breaks detection after a Scoot relaunch until the page is reloaded.
    }

    // Some apps are not accessible unless an assistive client (such as
    // VoiceOver) is enabled. (VoiceOver sets the `AXEnhancedUserInterface`
    // attribute on the main application window.)
    //
    // In order to ensure that Scoot can see what a screenreader sees,
    // Scoot adds this attribute to all running apps.
    //
    // Note that in earlier releases, Scoot added the `AXEnhancedUserInterface`
    // attribute (when necessary) immediately before traversing the element
    // tree; however, this solution was not ideal because apps may take some
    // time to enable their accessibility APIs, resulting in Scoot seeing an
    // incomplete picture of all available elements.
    //
    // For additional notes and discussion, see: https://github.com/mjrusso/scoot/issues/11
    static func enableEnhancedUserInterfaceForAllApps() {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }.forEach { app in
            Accessibility.enableEnhancedUserInterfaceIfNecessary(for: app)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }

            Accessibility.enableEnhancedUserInterfaceIfNecessary(for: app)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }

            Accessibility.enableEnhancedUserInterfaceIfNecessary(for: app)
        }
    }

    static func disableEnhancedUserInterfaceForAllApps() {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }.forEach { app in
            Accessibility.disableEnhancedUserInterface(for: app)
        }
    }

    static func getAccessibleElementsForFocusedWindow(of runningApp: NSRunningApplication) -> [Element] {
        // Chromium can auto-disable its AX tree, so re-assert before traversal.
        enableEnhancedUserInterfaceIfNecessary(for: runningApp)
        var elements = [(element: Element, layer: Int)]()
        var weakCandidates = [(element: Element, layer: Int)]()
        var branchFrames = [Int: [CGRect]]()

        guard let app = Application(runningApp) else {
            return []
        }

        guard let focusedWindow: UIElement = try? app.attribute(.focusedWindow) else {
            return []
        }

        guard let windowAttributes = try? focusedWindow.getMultipleAttributes(.role, .subrole, .frame, .children),
              let focusedWindowFrame = windowAttributes[.frame] as? CGRect else {
            return []
        }

        func traverse(node: UIElement, role: String?, subrole: String?, children: [AXUIElement], clip: CGRect,
                      layer: Int, inWebArea: Bool, findingBranches: Bool) {
            let isList = role == "AXList"
            let isInWebArea = inWebArea || role == "AXWebArea"
            let branchesPending = findingBranches || (!inWebArea && role == "AXWebArea")
            let assignsLayers = branchesPending && children.count > 1

            for (index, nativeChild) in children.enumerated() {
                let child = UIElement(nativeChild)

                // Bail, if the parent and child are (somehow?) the same node.
                //
                // See: https://github.com/mjrusso/scoot/issues/13
                guard child != node else {
                    continue
                }

                guard let attributes = try? child.getMultipleAttributes(.role, .subrole, .frame, .children),
                      let frame = attributes[.frame] as? CGRect else {
                    continue
                }

                let clippedFrame = frame.intersection(clip)
                guard !clippedFrame.isEmpty else {
                    continue
                }

                let convertedFrame = clippedFrame.convertToCocoa()
                let childLayer = assignsLayers ? index : layer
                if assignsLayers && childLayer > 0 {
                    branchFrames[childLayer, default: []].append(convertedFrame)
                }

                let screen = NSScreen.screens.first(where: {
                    $0.frame.contains(convertedFrame)
                })

                let roleName = attributes[.role] as? String
                let role = roleName.flatMap(Role.init(rawValue:)) ??
                    (roleName == "AXMenuBarItem" ? .menuItem : nil)

                if let role = role, let screen = screen {

                    func addElement() {
                        let element = Element(
                            role: role,
                            screen: screen,
                            frame: convertedFrame
                        )
                        elements.append((element, childLayer))
                    }

                    switch role {
                    case .cell, .button, .radioButton, .link, .checkBox, .slider, .popUpButton, .menuButton, .menuItem, .incrementor, .handle:
                        addElement()
                    default:
                        let ignoredActions: Set<String> = ["AXShowMenu", "AXScrollToVisible", "AXShowDefaultUI", "AXShowAlternateUI", "AXCancel"]
                        if !Set((try? child.actionsAsStrings()) ?? []).subtracting(ignoredActions).isEmpty {
                            addElement()
                        } else if !["AXWebArea", "AXScrollArea", "AXWindow", "AXList"].contains(role.rawValue),
                                  clippedFrame.area <= focusedWindowFrame.area * 0.5,
                                  (try? child.attributeIsSettable(.focused)) == true {
                            addElement()
                        } else if isList && role == .group {
                            weakCandidates.append((Element(role: role, screen: screen, frame: convertedFrame), childLayer))
                        }
                    }
                }

                traverse(node: child,
                         role: roleName,
                         subrole: attributes[.subrole] as? String,
                         children: attributes[.children] as? [AXUIElement] ?? [],
                         clip: roleName == "AXScrollArea" ? clippedFrame : clip,
                         layer: childLayer,
                         inWebArea: isInWebArea,
                         findingBranches: branchesPending && !assignsLayers)
            }

        }

        let traversalStart = DispatchTime.now()
        traverse(node: focusedWindow,
                 role: windowAttributes[.role] as? String,
                 subrole: windowAttributes[.subrole] as? String,
                 children: windowAttributes[.children] as? [AXUIElement] ?? [],
                 clip: focusedWindowFrame,
                 layer: 0,
                 inWebArea: false,
                 findingBranches: false)
        let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - traversalStart.uptimeNanoseconds) / 1_000_000

        // ponytail: DOM order stands in for z-order (no AX z-order; hit-testing is unusable in Chromium/Dia); layers that hold no candidates never occlude.
        var occluders = [Int: [CGRect]]()
        for candidate in elements + weakCandidates where candidate.layer > 0 {
            if occluders[candidate.layer] == nil {
                occluders[candidate.layer] = branchFrames[candidate.layer] ?? []
            }
            occluders[candidate.layer, default: []].append(candidate.element.frame)
        }
        func isOccluded(_ candidate: (element: Element, layer: Int)) -> Bool {
            let midpoint = CGPoint(x: candidate.element.frame.midX, y: candidate.element.frame.midY)
            return occluders.contains { layer, frames in
                layer > candidate.layer && frames.contains { $0.contains(midpoint) }
            }
        }
        elements.removeAll(where: isOccluded)
        weakCandidates.removeAll(where: isOccluded)

        // ponytail: O(weak × strong) is acceptable at current sizes.
        elements.append(contentsOf: weakCandidates.filter { candidate in
            !elements.contains { candidate.element.frame.contains(CGPoint(x: $0.element.frame.midX, y: $0.element.frame.midY)) }
        })

        OSLog.main.debug("Found \(elements.count) accessibility elements in \(elapsedMilliseconds) ms.")

        return elements.map(\.element)
    }

}
