//
//  TouchProbe.swift
//  PlayTools
//
//  Step 3: in-process fake touch (Toucher / PTFakeMetaTouch).
//  Enable: env PLAYTOOLS_TOUCH_PROBE=1
//  Optional:
//    PLAYTOOLS_TOUCH_PROBE_DELAY (default 10)
//    PLAYTOOLS_TOUCH_TEXT        — OCR text substring to tap (default "Level")
//    PLAYTOOLS_TOUCH_X / _Y      — absolute logic points (override OCR)
//    PLAYTOOLS_TOUCH_HOLD_MS     — hold duration (default 50)
//

import Foundation
import UIKit

enum TouchProbe {
    private static let logTag = "[PlayTools/TouchProbe]"

    static func maybeStart() {
        let env = ProcessInfo.processInfo.environment
        guard env["PLAYTOOLS_TOUCH_PROBE"] == "1" else { return }

        let delay = Double(env["PLAYTOOLS_TOUCH_PROBE_DELAY"] ?? "10") ?? 10
        NSLog("%@ enabled, will touch in %.1fs", logTag, delay)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            runOnce()
        }
    }

    @discardableResult
    static func runOnce() -> URL? {
        let reportDir = ScreenCaptureProbe.makeReportDir(folder: "PlayToolsTouchProbe")
        let env = ProcessInfo.processInfo.environment
        var report: [String: Any] = [
            "ok": false,
            "ts": ISO8601DateFormatter().string(from: Date()),
            "bundleId": Bundle.main.bundleIdentifier ?? ""
        ]

        var targetX: CGFloat?
        var targetY: CGFloat?
        var source = "unknown"

        if let xs = env["PLAYTOOLS_TOUCH_X"], let ys = env["PLAYTOOLS_TOUCH_Y"],
           let x = Double(xs), let y = Double(ys) {
            targetX = CGFloat(x)
            targetY = CGFloat(y)
            source = "env_xy"
            if let capture = ScreenCaptureProbe.captureBest() {
                _ = ScreenCaptureProbe.writePNG(capture.image, dir: reportDir, name: "before.png")
                report["captureMethod"] = capture.method
            }
        } else {
            guard let capture = ScreenCaptureProbe.captureBest() else {
                report["error"] = "capture_failed"
                finish(report: report, dir: reportDir)
                return reportDir
            }
            _ = ScreenCaptureProbe.writePNG(capture.image, dir: reportDir, name: "before.png")
            report["captureMethod"] = capture.method

            let logicSize = PlayScreen.shared.keyWindow?.bounds.size
                ?? PlayScreen.shared.window?.bounds.size
                ?? capture.image.size
            report["logicW"] = logicSize.width
            report["logicH"] = logicSize.height

            let needle = (env["PLAYTOOLS_TOUCH_TEXT"] ?? "Level").lowercased()
            do {
                let elements = try OCRProbe.recognizePublic(image: capture.image, logicSize: logicSize)
                report["ocrCount"] = elements.count
                report["ocrPreview"] = elements.prefix(8).map { $0.text }.joined(separator: " | ")

                if let hit = elements.first(where: { $0.text.lowercased().contains(needle) }) {
                    targetX = CGFloat(hit.x ?? hit.cx * Double(logicSize.width))
                    targetY = CGFloat(hit.y ?? hit.cy * Double(logicSize.height))
                    source = "ocr:\(hit.text)"
                    report["matched"] = [
                        "text": hit.text,
                        "conf": hit.conf,
                        "x": hit.x as Any,
                        "y": hit.y as Any
                    ]
                } else {
                    report["error"] = "no_ocr_match"
                    report["needle"] = needle
                    finish(report: report, dir: reportDir)
                    return reportDir
                }
            } catch {
                report["error"] = "ocr_failed: \(error.localizedDescription)"
                finish(report: report, dir: reportDir)
                return reportDir
            }
        }

        guard let x = targetX, let y = targetY else {
            report["error"] = "no_target"
            finish(report: report, dir: reportDir)
            return reportDir
        }

        let holdMs = Int(env["PLAYTOOLS_TOUCH_HOLD_MS"] ?? "50") ?? 50
        report["source"] = source
        report["x"] = Double(x)
        report["y"] = Double(y)
        report["holdMs"] = holdMs

        let point = CGPoint(x: x, y: y)
        NSLog("%@ tapping (%.1f, %.1f) source=%@ hold=%dms", logTag, x, y, source, holdMs)

        // Schedule on main; Toucher uses main runloop source
        DispatchQueue.main.async {
            var tid: Int?
            Toucher.touchcam(point: point, phase: .began, tid: &tid,
                             actionName: "TouchProbe", keyName: source)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(holdMs, 1))) {
                Toucher.touchcam(point: point, phase: .ended, tid: &tid,
                                 actionName: "TouchProbe", keyName: source)
                report["ok"] = true
                report["tidAfter"] = tid as Any

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if let after = ScreenCaptureProbe.captureBest() {
                        _ = ScreenCaptureProbe.writePNG(after.image, dir: reportDir, name: "after.png")
                    }
                    finish(report: report, dir: reportDir)
                }
            }
        }

        // Preliminary write (ok may still be false until main finishes)
        writeJSON(report, to: reportDir.appendingPathComponent("touch.json"))
        return reportDir
    }

    private static func finish(report: [String: Any], dir: URL) {
        writeJSON(report, to: dir.appendingPathComponent("touch.json"))
        ScreenCaptureProbe.mirrorToPlayCoverContainer(dir, subfolder: "TouchProbe")
        let ok = report["ok"] as? Bool ?? false
        let msg: String
        if ok {
            msg = String(format: "tap (%.0f,%.0f) %@",
                         report["x"] as? Double ?? 0,
                         report["y"] as? Double ?? 0,
                         report["source"] as? String ?? "")
        } else {
            msg = report["error"] as? String ?? "failed"
        }
        NSLog("%@ %@", logTag, msg)
        DispatchQueue.main.async {
            Toast.showHint(title: "Touch probe", text: [msg])
        }
    }

    private static func writeJSON(_ obj: [String: Any], to url: URL) {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: url)
    }
}
