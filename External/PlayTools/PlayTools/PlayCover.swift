//
//  PlayCover.swift
//  PlayTools
//

import Foundation
import UIKit

public class PlayCover: NSObject {

    static let shared = PlayCover()
    var menuController: MenuController?

    @objc static public func launch() {
        quitWhenClose()
        AKInterface.initialize()
        PlayScreen.shared.initialize()
        PlayInput.shared.initialize()
        DiscordIPC.shared.initialize()
        // Step-1 feasibility: in-process screenshot when PLAYTOOLS_SCREENSHOT_PROBE=1
        ScreenCaptureProbe.maybeStart()

        if PlaySettings.shared.rootWorkDir {
            // Change the working directory to / just like iOS
            FileManager.default.changeCurrentDirectoryPath("/")
        }

        // Forced rotation presents a temporary VC. If a native consent UIAlert is
        // already up, that present/dismiss cycle makes the alert flash white / vanish.
        // Wait until no UIAlertController is presented, then apply orientation.
        if PlaySettings.shared.displayRotation != 0 {
            scheduleDisplayRotation(attemptsLeft: 40)
        }
    }

    /// Applies `displayRotation` once native alerts (e.g. terms consent) are gone.
    private static func scheduleDisplayRotation(attemptsLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if isUIAlertControllerPresented() {
                if attemptsLeft > 0 {
                    scheduleDisplayRotation(attemptsLeft: attemptsLeft - 1)
                }
                return
            }
            let rotateCommand = UIKeyCommand(
                title: "Keep Rotation Command",
                image: nil,
                action: #selector(UIApplication.rotateView(_:)),
                input: "",
                modifierFlags: [],
                propertyList: ["rotationIndex": PlaySettings.shared.displayRotation]
            )
            UIApplication.shared.sendAction(
                #selector(UIApplication.rotateView(_:)),
                to: UIApplication.shared,
                from: rotateCommand,
                for: nil
            )
        }
    }

    private static func isUIAlertControllerPresented() -> Bool {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where !window.isHidden {
                var vc: UIViewController? = window.rootViewController
                while let current = vc {
                    if current is UIAlertController {
                        return true
                    }
                    vc = current.presentedViewController
                }
            }
        }
        return false
    }

    @objc static public func initMenu(menu: NSObject) {
        guard let menuBuilder = menu as? UIMenuBuilder else { return }
        shared.menuController = MenuController(with: menuBuilder)
    }

    static public func quitWhenClose() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "NSWindowWillCloseNotification"),
            object: nil,
            queue: OperationQueue.main
        ) { notif in
            if PlayScreen.shared.nsWindow?.isEqual(notif.object) ?? false {
                // Step 1: Resign active
                for scene in UIApplication.shared.connectedScenes {
                    scene.delegate?.sceneWillResignActive?(scene)
                    NotificationCenter.default.post(name: UIScene.willDeactivateNotification,
                                                    object: scene)
                }
                UIApplication.shared.delegate?.applicationWillResignActive?(UIApplication.shared)
                NotificationCenter.default.post(name: UIApplication.willResignActiveNotification,
                                                object: UIApplication.shared)

                // Step 2: Enter background
                for scene in UIApplication.shared.connectedScenes {
                    scene.delegate?.sceneDidEnterBackground?(scene)
                    NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification,
                                                    object: scene)
                }
                UIApplication.shared.delegate?.applicationDidEnterBackground?(UIApplication.shared)
                NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification,
                                                object: UIApplication.shared)

                // Step 2.5: End UIBackgroundTask
                // There is an expiration handler, but idk how to invoke it. Skip for now.

                // Step 3: Terminate
                for scene in UIApplication.shared.connectedScenes {
                    scene.delegate?.sceneDidDisconnect?(scene)
                    NotificationCenter.default.post(name: UIScene.didDisconnectNotification,
                                                    object: scene)
                }
                UIApplication.shared.delegate?.applicationWillTerminate?(UIApplication.shared)
                // Some apps will freeze or crash when click close button if we send willTerminateNotification.
                // The developer documentation says this is a "may be called method", so it can be safely skipped.
                // https://developer.apple.com/documentation/uikit/uiapplicationdelegate/1623111-applicationwillterminate
                // swiftlint:disable:previous line_length
//                NotificationCenter.default.post(name: UIApplication.willTerminateNotification,
//                                                object: UIApplication.shared)
                DispatchQueue.main.async(execute: AKInterface.shared!.terminateApplication)

                // Step 3.5: End BGTask
                // BGTask typically runs in another process and is tricky to terminate.
                // It may run into infinite loops, end up silently heating the device up.
                // This actually happens for ToF. Hope future developers can solve this.
            }
        }
    }

    static func delay(_ delay: Double, closure: @escaping () -> Void) {
        let when = DispatchTime.now() + delay
        DispatchQueue.main.asyncAfter(deadline: when, execute: closure)
    }
}
