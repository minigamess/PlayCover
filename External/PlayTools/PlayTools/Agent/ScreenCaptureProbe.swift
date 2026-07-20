//
//  ScreenCaptureProbe.swift
//  PlayTools
//
//  Step 1: in-process screenshot probe (no external agent).
//  Capture path: UIKit only (key window drawHierarchy).
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

    struct CaptureResult {
        let image: UIImage
        let method: String
        let meta: [String: Any]
    }

    /// UIKit key-window capture only (no fallback).
    static func captureBest() -> CaptureResult? {
        guard let (img, meta) = captureUIKit() else { return nil }
        return CaptureResult(image: img, method: "uikit", meta: meta)
    }

    /// Capture once and write PNG + JSON report to Documents.
    @discardableResult
    static func runOnce() -> URL? {
        let reportDir = makeReportDir(folder: "PlayToolsScreenshotProbe")
        var report: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "bundleId": Bundle.main.bundleIdentifier ?? "",
            "method": "uikit"
        ]

        var bestURL: URL?
        var bestBytes = 0

        if let (img, meta) = captureUIKit() {
            report["uikit"] = meta
            if let url = writePNG(img, dir: reportDir, name: "shot_uikit.png") {
                report["uikitPath"] = url.path
                bestURL = url
                bestBytes = (try? Data(contentsOf: url).count) ?? 0
            }
        } else {
            report["uikit"] = ["ok": false, "error": "no image"]
        }

        report["bestPath"] = bestURL?.path ?? ""
        report["bestBytes"] = bestBytes

        let reportURL = reportDir.appendingPathComponent("report.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: reportURL)
        }

        let summary = "Screenshot probe: method=uikit bestBytes=\(bestBytes) dir=\(reportDir.path)"
        NSLog("%@ %@", logTag, summary)
        DispatchQueue.main.async {
            Toast.showHint(title: "Screenshot probe", text: [
                "method: uikit",
                "bytes: \(bestBytes)",
                reportDir.lastPathComponent
            ])
        }

        mirrorToPlayCoverContainer(reportDir, subfolder: "ScreenshotProbe")
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

    static func makeReportDir(folder: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = docs
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func writePNG(_ image: UIImage, dir: URL, name: String) -> URL? {
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

    static func mirrorToPlayCoverContainer(_ dir: URL, subfolder: String) {
        let candidates: [URL] = {
            var list: [URL] = []
            list.append(URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Documents/\(subfolder)"))
            if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
                let userHome = String(cString: home)
                list.append(URL(fileURLWithPath: userHome)
                    .appendingPathComponent(
                        "Library/Containers/io.playcover.PlayCover/\(subfolder)"))
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
