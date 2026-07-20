//
//  TouchProbe.swift
//  PlayTools
//
//  In-process fake touch (Toucher / PTFakeMetaTouch).
//
//  Enable: PLAYTOOLS_TOUCH_PROBE=1
//
//  Grid scan (verify taps work — preferred for feasibility):
//    PLAYTOOLS_TOUCH_GRID=1
//    PLAYTOOLS_TOUCH_GRID_STEP   — spacing in logic points (default 80)
//    PLAYTOOLS_TOUCH_GRID_MARGIN — inset from edges (default 40)
//    PLAYTOOLS_TOUCH_HOLD_MS     — press duration (default 40)
//    PLAYTOOLS_TOUCH_GAP_MS      — pause between taps (default 100)
//
//  Single tap (optional):
//    PLAYTOOLS_TOUCH_TEXT / PLAYTOOLS_TOUCH_X+Y  (when GRID != 1)
//    PLAYTOOLS_TOUCH_PROBE_DELAY (default 10)
//

import Foundation
import UIKit

enum TouchProbe {
    private static let logTag = "[PlayTools/TouchProbe]"

    static func maybeStart() {
        let env = ProcessInfo.processInfo.environment
        guard env["PLAYTOOLS_TOUCH_PROBE"] == "1" else { return }

        let delay = Double(env["PLAYTOOLS_TOUCH_PROBE_DELAY"] ?? "10") ?? 10
        let grid = env["PLAYTOOLS_TOUCH_GRID"] == "1"
        NSLog("%@ enabled mode=%@ delay=%.1fs", logTag, grid ? "grid" : "single", delay)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if grid {
                runGrid()
            } else {
                runOnce()
            }
        }
    }

    // MARK: - Grid scan

    /// Tap the whole screen on a fixed grid so visual/game response can prove touch works.
    @discardableResult
    static func runGrid() -> URL? {
        let reportDir = ScreenCaptureProbe.makeReportDir(folder: "PlayToolsTouchProbe")
        let env = ProcessInfo.processInfo.environment

        let step = max(CGFloat(Double(env["PLAYTOOLS_TOUCH_GRID_STEP"] ?? "80") ?? 80), 20)
        let margin = max(CGFloat(Double(env["PLAYTOOLS_TOUCH_GRID_MARGIN"] ?? "40") ?? 40), 0)
        let holdMs = max(Int(env["PLAYTOOLS_TOUCH_HOLD_MS"] ?? "40") ?? 40, 1)
        let gapMs = max(Int(env["PLAYTOOLS_TOUCH_GAP_MS"] ?? "100") ?? 100, 0)

        let size = logicSize()
        var report: [String: Any] = [
            "ok": false,
            "mode": "grid",
            "ts": ISO8601DateFormatter().string(from: Date()),
            "bundleId": Bundle.main.bundleIdentifier ?? "",
            "logicW": Double(size.width),
            "logicH": Double(size.height),
            "step": Double(step),
            "margin": Double(margin),
            "holdMs": holdMs,
            "gapMs": gapMs
        ]

        if let capture = ScreenCaptureProbe.captureBest() {
            _ = ScreenCaptureProbe.writePNG(capture.image, dir: reportDir, name: "before.png")
            report["captureMethod"] = capture.method
        }

        // Build points: left→right, top→bottom
        var points: [CGPoint] = []
        var y = margin
        while y <= size.height - margin {
            var x = margin
            while x <= size.width - margin {
                points.append(CGPoint(x: x, y: y))
                x += step
            }
            y += step
        }

        // If margin is large relative to size, still hit center once
        if points.isEmpty {
            points.append(CGPoint(x: size.width / 2, y: size.height / 2))
        }

        report["count"] = points.count
        report["points"] = points.map { ["x": Double($0.x), "y": Double($0.y)] }
        writeJSON(report, to: reportDir.appendingPathComponent("touch.json"))

        NSLog("%@ grid start count=%d step=%.0f size=%.0fx%.0f",
              logTag, points.count, step, size.width, size.height)
        Toast.showHint(title: "Touch grid", text: [
            "\(points.count) taps",
            "step \(Int(step))",
            String(format: "%.0f×%.0f", size.width, size.height)
        ])

        DispatchQueue.main.async {
            tapSequence(points: points, index: 0, holdMs: holdMs, gapMs: gapMs) {
                report["ok"] = true
                report["finishedAt"] = ISO8601DateFormatter().string(from: Date())
                if let after = ScreenCaptureProbe.captureBest() {
                    _ = ScreenCaptureProbe.writePNG(after.image, dir: reportDir, name: "after.png")
                }
                writeJSON(report, to: reportDir.appendingPathComponent("touch.json"))
                ScreenCaptureProbe.mirrorToPlayCoverContainer(reportDir, subfolder: "TouchProbe")
                NSLog("%@ grid done count=%d", logTag, points.count)
                Toast.showHint(title: "Touch grid done", text: ["\(points.count) taps"])
            }
        }

        return reportDir
    }

    /// Sequential began→ended taps on main queue.
    private static func tapSequence(points: [CGPoint], index: Int, holdMs: Int, gapMs: Int,
                                    completion: @escaping () -> Void) {
        guard index < points.count else {
            completion()
            return
        }
        let point = points[index]
        if index % 10 == 0 || index == points.count - 1 {
            NSLog("%@ grid [%d/%d] (%.0f, %.0f)", logTag, index + 1, points.count, point.x, point.y)
        }

        var tid: Int?
        Toucher.touchcam(point: point, phase: .began, tid: &tid,
                         actionName: "TouchGrid", keyName: "\(index)")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(holdMs)) {
            Toucher.touchcam(point: point, phase: .ended, tid: &tid,
                             actionName: "TouchGrid", keyName: "\(index)")
            let nextDelay = max(gapMs, 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(nextDelay)) {
                tapSequence(points: points, index: index + 1, holdMs: holdMs, gapMs: gapMs,
                            completion: completion)
            }
        }
    }

    // MARK: - Single tap (OCR / fixed XY)

    @discardableResult
    static func runOnce() -> URL? {
        let reportDir = ScreenCaptureProbe.makeReportDir(folder: "PlayToolsTouchProbe")
        let env = ProcessInfo.processInfo.environment
        var report: [String: Any] = [
            "ok": false,
            "mode": "single",
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

            let size = logicSize()
            report["logicW"] = size.width
            report["logicH"] = size.height

            let needle = (env["PLAYTOOLS_TOUCH_TEXT"] ?? "Level").lowercased()
            do {
                let elements = try OCRProbe.recognizePublic(image: capture.image, logicSize: size)
                report["ocrCount"] = elements.count
                report["ocrPreview"] = elements.prefix(8).map { $0.text }.joined(separator: " | ")

                if let hit = elements.first(where: { $0.text.lowercased().contains(needle) }) {
                    targetX = CGFloat(hit.x ?? hit.cx * Double(size.width))
                    targetY = CGFloat(hit.y ?? hit.cy * Double(size.height))
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
        NSLog("%@ single tap (%.1f, %.1f) source=%@", logTag, x, y, source)

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

        writeJSON(report, to: reportDir.appendingPathComponent("touch.json"))
        return reportDir
    }

    // MARK: - Helpers

    private static func logicSize() -> CGSize {
        if let s = PlayScreen.shared.keyWindow?.bounds.size, s.width > 1 { return s }
        if let s = PlayScreen.shared.window?.bounds.size, s.width > 1 { return s }
        return CGSize(width: screen.width, height: screen.height)
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
