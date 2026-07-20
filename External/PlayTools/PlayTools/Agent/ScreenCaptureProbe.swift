//
//  ScreenCaptureProbe.swift
//  PlayTools
//
//  Step 1: in-process screenshot probe (no external agent).
//  Enable: env PLAYTOOLS_SCREENSHOT_PROBE=1
//  Optional delay seconds: PLAYTOOLS_SCREENSHOT_PROBE_DELAY (default 8)
//

import Foundation
import UIKit
import CoreGraphics

enum ScreenCaptureProbe {
    private static let logTag = "[PlayTools/ScreenshotProbe]"

    static func maybeStart() {
        let env = ProcessInfo.processInfo.environment
        guard env["PLAYTOOLS_SCREENSHOT_PROBE"] == "1" else { return }

        let delay = Double(env["PLAYTOOLS_SCREENSHOT_PROBE_DELAY"] ?? "8") ?? 8
        NSLog("%@ enabled, will capture in %.1fs", logTag, delay)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            runOnce()
        }
    }

    /// Capture once and write PNG + JSON report to Documents.
    @discardableResult
    static func runOnce() -> URL? {
        let reportDir = makeReportDir()
        var report: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "bundleId": Bundle.main.bundleIdentifier ?? "",
            "methods": [String]()
        ]

        var methods = [String]()
        var bestURL: URL?
        var bestBytes = 0

        // Method A: UIKit key window hierarchy
        if let (img, meta) = captureUIKit() {
            methods.append("uikit")
            report["uikit"] = meta
            if let url = writePNG(img, dir: reportDir, name: "shot_uikit.png") {
                report["uikitPath"] = url.path
                let n = (try? Data(contentsOf: url).count) ?? 0
                if n > bestBytes {
                    bestBytes = n
                    bestURL = url
                }
            }
        } else {
            report["uikit"] = ["ok": false, "error": "no image"]
        }

        // Method B: CGWindowList via dlsym (macOS host API; not in iOS SDK headers)
        if let (img, meta) = captureCGWindowRuntime() {
            methods.append("cgwindow")
            report["cgwindow"] = meta
            if let url = writePNG(img, dir: reportDir, name: "shot_cgwindow.png") {
                report["cgwindowPath"] = url.path
                let n = (try? Data(contentsOf: url).count) ?? 0
                if n > bestBytes {
                    bestBytes = n
                    bestURL = url
                }
            }
        } else {
            report["cgwindow"] = ["ok": false, "error": "unavailable or failed"]
        }

        report["methods"] = methods
        report["bestPath"] = bestURL?.path ?? ""
        report["bestBytes"] = bestBytes

        let reportURL = reportDir.appendingPathComponent("report.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: reportURL)
        }

        let summary = "Screenshot probe: methods=\(methods) bestBytes=\(bestBytes) dir=\(reportDir.path)"
        NSLog("%@ %@", logTag, summary)
        DispatchQueue.main.async {
            Toast.showHint(title: "Screenshot probe", text: [
                "methods: \(methods.joined(separator: ","))",
                "bytes: \(bestBytes)",
                reportDir.lastPathComponent
            ])
        }

        mirrorToPlayCoverContainer(reportDir)
        return bestURL
    }

    // MARK: - Capture

    private static func captureUIKit() -> (UIImage, [String: Any])? {
        guard let window = resolveKeyWindow() else { return nil }
        let bounds = window.bounds
        guard bounds.width > 1, bounds.height > 1 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }

        var meta: [String: Any] = [
            "ok": true,
            "width": bounds.width,
            "height": bounds.height,
            "scale": format.scale,
            "pixelW": image.size.width * image.scale,
            "pixelH": image.size.height * image.scale
        ]
        if let avg = averageLuma(image) {
            meta["avgLuma"] = avg
            if avg < 0.02 {
                meta["warning"] = "very_dark_possible_black_frame"
            }
        }
        return (image, meta)
    }

    /// Resolve CGWindowListCreateImage at runtime (present on Mac host for iOS apps).
    private static func captureCGWindowRuntime() -> (UIImage, [String: Any])? {
        guard let nsWindow = PlayScreen.shared.nsWindow else { return nil }
        guard let windowNumber = nsWindow.value(forKey: "windowNumber") as? Int, windowNumber > 0 else {
            return nil
        }

        // CGImageRef CGWindowListCreateImage(CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption)
        typealias CGWindowListCreateImageFn = @convention(c) (
            CGRect, UInt32, UInt32, UInt32
        ) -> Unmanaged<CGImage>?

        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            return nil
        }
        let createImage = unsafeBitCast(sym, to: CGWindowListCreateImageFn.self)

        // kCGWindowListOptionIncludingWindow = 1 << 0 = 1
        // kCGWindowImageBoundsIgnoreFraming = 1 << 0 = 1
        // kCGWindowImageBestResolution = 1 << 1 = 2
        let listOption: UInt32 = 1
        let imageOption: UInt32 = 1 | 2
        guard let unmanaged = createImage(.null, listOption, UInt32(windowNumber), imageOption) else {
            return nil
        }
        let cgImage = unmanaged.takeUnretainedValue()
        let image = UIImage(cgImage: cgImage)
        var meta: [String: Any] = [
            "ok": true,
            "windowNumber": windowNumber,
            "pixelW": cgImage.width,
            "pixelH": cgImage.height
        ]
        if let avg = averageLuma(image) {
            meta["avgLuma"] = avg
            if avg < 0.02 {
                meta["warning"] = "very_dark_possible_black_frame"
            }
        }
        return (image, meta)
    }

    // MARK: - Helpers

    private static func resolveKeyWindow() -> UIWindow? {
        if let w = PlayScreen.shared.keyWindow { return w }
        if let w = PlayScreen.shared.window { return w }
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            if let key = ws.windows.first(where: { $0.isKeyWindow }) { return key }
            if let any = ws.windows.first(where: { !$0.isHidden }) { return any }
        }
        return nil
    }

    private static func makeReportDir() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = docs
            .appendingPathComponent("PlayToolsScreenshotProbe", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func writePNG(_ image: UIImage, dir: URL, name: String) -> URL? {
        guard let data = image.pngData() else { return nil }
        let url = dir.appendingPathComponent(name)
        do {
            try data.write(to: url)
            return url
        } catch {
            NSLog("%@ write failed %@: %@", logTag, name, error.localizedDescription)
            return nil
        }
    }

    private static func averageLuma(_ image: UIImage) -> Double? {
        guard let cg = image.cgImage else { return nil }
        let w = min(cg.width, 64)
        let h = min(cg.height, 64)
        guard w > 0, h > 0 else { return nil }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &data,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0
        let n = w * h
        for i in 0..<n {
            let o = i * 4
            let r = Double(data[o])
            let g = Double(data[o + 1])
            let b = Double(data[o + 2])
            sum += (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
        }
        return sum / Double(n)
    }

    private static func mirrorToPlayCoverContainer(_ dir: URL) {
        // iOS SDK: use NSHomeDirectory() which on Mac maps to the app container home.
        // Also try the real user home via getpwuid for PlayCover shared folder.
        let candidates: [URL] = {
            var list: [URL] = []
            list.append(URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Documents/PlayToolsScreenshotProbe"))
            if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
                let userHome = String(cString: home)
                list.append(URL(fileURLWithPath: userHome)
                    .appendingPathComponent(
                        "Library/Containers/io.playcover.PlayCover/ScreenshotProbe"))
            }
            return list
        }()

        let bid = Bundle.main.bundleIdentifier ?? "unknown"
        for root in candidates {
            let destRoot = root.appendingPathComponent(bid)
            do {
                try FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)
                let dest = destRoot.appendingPathComponent(dir.lastPathComponent, isDirectory: true)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: dir, to: dest)
                let latest = destRoot.appendingPathComponent("LATEST_PATH.txt")
                try dest.path.write(to: latest, atomically: true, encoding: .utf8)
                NSLog("%@ mirrored to %@", logTag, dest.path)
            } catch {
                NSLog("%@ mirror to %@ failed: %@", logTag, destRoot.path, error.localizedDescription)
            }
        }
    }
}
