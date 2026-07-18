//
//  TouchscreenMouseEventAdapter.swift
//  PlayTools
//
//  Created by 许沂聪 on 2023/9/16.
//

import Foundation
import UIKit

// Mouse events handler when cursor is free and keyboard mapping is on

public class TouchscreenMouseEventAdapter: MouseEventAdapter {

    static public func cursorPos() -> CGPoint? {
        // IMPROVE: this is expensive (maybe?)
        var point = AKInterface.shared!.mousePoint
        let rect = AKInterface.shared!.windowFrame
        if rect.width < 1 || rect.height < 1 {
            return nil
        }
        if screen.resizable && !screen.fullscreen {
            // Allow user to resize window by dragging edges
            let margin = CGFloat(10)
            if point.x < margin || point.x > rect.width - margin ||
                point.y < margin || point.y > rect.height - margin {
                return nil
            }
        }
        let viewRect: CGRect = screen.screenRect
        let widthRate = viewRect.width / rect.width
        var rate = viewRect.height / rect.height
        if widthRate > rate {
            // Keep aspect ratio
            rate = widthRate
        }
        if screen.fullscreen {
            // Vertically in center
            point.y -= (rect.height - viewRect.height / rate)/2
        }
        point.y *= rate
        point.y = viewRect.height - point.y
        // For traffic light buttons when not fullscreen
        if point.y < 0 {
            return nil
        }
        // Horizontally in center
        point.x -= (rect.width - viewRect.width / rate)/2
        point.x *= rate
        return point
    }

    /// Native system dialogs often ignore fake touches; pass real clicks through.
    static func shouldPassThroughNativeDialog(at point: CGPoint) -> Bool {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { !$0.isHidden }
            .sorted { $0.windowLevel.rawValue > $1.windowLevel.rawValue }

        for window in windows {
            if let hit = window.hitTest(point, with: nil), isNativeDialogView(hit) {
                return true
            }
            if window.windowLevel.rawValue > UIWindow.Level.normal.rawValue,
               containsAlertController(window) {
                return true
            }
        }

        if let key = screen.keyWindow,
           let hit = key.hitTest(point, with: nil),
           isNativeDialogView(hit) {
            return true
        }
        return false
    }

    private static func isNativeDialogView(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let node = current {
            if containsAlertController(node) {
                return true
            }
            let className = NSStringFromClass(type(of: node))
            if className.contains("UIAlert")
                || className.contains("UIInterfaceAction")
                || className.contains("_UIAlert")
                || className.contains("UIActivityView")
                || className.contains("UISheetPresentation") {
                return true
            }
            current = node.superview
        }
        return false
    }

    private static func containsAlertController(_ responder: UIResponder) -> Bool {
        var current: UIResponder? = responder
        while let node = current {
            if node is UIAlertController {
                return true
            }
            current = node.next
        }
        return false
    }

    public func handleScrollWheel(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        _ = ActionDispatcher.dispatch(key: KeyCodeNames.scrollWheelDrag, valueX: deltaX, valueY: deltaY)
        return false
    }

    public func handleMove(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        if ActionDispatcher.getDispatchPriority(key: KeyCodeNames.mouseMove) == .DRAGGABLE {
            return ActionDispatcher.dispatch(key: KeyCodeNames.mouseMove, valueX: deltaX, valueY: -deltaY)
        } else if ActionDispatcher.getDispatchPriority(key: KeyCodeNames.fakeMouse) == .DRAGGABLE {
            guard let pos = TouchscreenMouseEventAdapter.cursorPos() else { return false }
            if TouchscreenMouseEventAdapter.shouldPassThroughNativeDialog(at: pos) {
                return false
            }
            return ActionDispatcher.dispatch(key: KeyCodeNames.fakeMouse, valueX: pos.x, valueY: pos.y)
        }
        return false
    }

    public func handleLeftButton(pressed: Bool) -> Bool {
        guard let pos = TouchscreenMouseEventAdapter.cursorPos() else { return false }
        if TouchscreenMouseEventAdapter.shouldPassThroughNativeDialog(at: pos) {
            return false
        }
        if pressed {
            return ActionDispatcher.dispatch(key: KeyCodeNames.fakeMouse, valueX: pos.x, valueY: pos.y)
        } else {
            return ActionDispatcher.dispatch(key: KeyCodeNames.fakeMouse, pressed: pressed)
        }
    }

    public func handleOtherButton(id: Int, pressed: Bool) -> Bool {
        ActionDispatcher.dispatch(key: EditorMouseEventAdapter.getMouseButtonName(id),
                                  pressed: pressed)
    }

    public func cursorHidden() -> Bool {
        false
    }

}
