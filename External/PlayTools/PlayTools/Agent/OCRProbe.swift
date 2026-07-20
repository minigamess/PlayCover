//
//  OCRProbe.swift
//  PlayTools
//
//  Step 2: in-process OCR on a screenshot (Vision).
//  Enable: env PLAYTOOLS_OCR_PROBE=1
//  Optional delay: PLAYTOOLS_OCR_PROBE_DELAY (default 8)
//

import Foundation
import UIKit
import Vision

enum OCRProbe {
    private static let logTag = "[PlayTools/OCRProbe]"

    struct Element: Encodable {
        let id: Int
        let text: String
        let conf: Float
        /// Normalized [xmin, ymin, xmax, ymax] in top-left UI coords (same as screenshot).
        let bbox: [Double]
        /// Center in normalized UI coords.
        let cx: Double
        let cy: Double
        /// Center in logic points (UIKit window coords), if window size known.
        let x: Double?
        let y: Double?
    }

    /// Public Vision OCR for other probes (e.g. touch).
    static func recognizePublic(image: UIImage, logicSize: CGSize) throws -> [Element] {
        try recognize(image: image, logicSize: logicSize)
    }

    static func maybeStart() {
        let env = ProcessInfo.processInfo.environment
        guard env["PLAYTOOLS_OCR_PROBE"] == "1" else { return }

        let delay = Double(env["PLAYTOOLS_OCR_PROBE_DELAY"] ?? "8") ?? 8
        NSLog("%@ enabled, will OCR in %.1fs", logTag, delay)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            runOnce()
        }
    }

    @discardableResult
    static func runOnce() -> URL? {
        let reportDir = ScreenCaptureProbe.makeReportDir(folder: "PlayToolsOCRProbe")

        guard let capture = ScreenCaptureProbe.captureBest() else {
            writeJSON(["ok": false, "error": "capture_failed"], to: reportDir.appendingPathComponent("ocr.json"))
            NSLog("%@ capture failed", logTag)
            return nil
        }

        _ = ScreenCaptureProbe.writePNG(capture.image, dir: reportDir, name: "shot.png")

        let logicSize = PlayScreen.shared.keyWindow?.bounds.size
            ?? PlayScreen.shared.window?.bounds.size
            ?? capture.image.size

        let elements: [Element]
        do {
            elements = try recognize(image: capture.image, logicSize: logicSize)
        } catch {
            let err: [String: Any] = [
                "ok": false,
                "error": error.localizedDescription,
                "method": capture.method,
                "capture": capture.meta
            ]
            writeJSON(err, to: reportDir.appendingPathComponent("ocr.json"))
            NSLog("%@ Vision failed: %@", logTag, error.localizedDescription)
            return nil
        }

        var report: [String: Any] = [
            "ok": true,
            "ts": ISO8601DateFormatter().string(from: Date()),
            "bundleId": Bundle.main.bundleIdentifier ?? "",
            "method": capture.method,
            "capture": capture.meta,
            "logicW": logicSize.width,
            "logicH": logicSize.height,
            "count": elements.count,
            "elements": elements.map { el -> [String: Any] in
                var d: [String: Any] = [
                    "id": el.id,
                    "text": el.text,
                    "conf": el.conf,
                    "bbox": el.bbox,
                    "cx": el.cx,
                    "cy": el.cy
                ]
                if let x = el.x { d["x"] = x }
                if let y = el.y { d["y"] = y }
                return d
            }
        ]

        // Quick summary of top texts for logs / toast
        let preview = elements.prefix(12).map { "\($0.id):\($0.text)" }.joined(separator: " | ")
        report["preview"] = preview

        writeJSON(report, to: reportDir.appendingPathComponent("ocr.json"))
        ScreenCaptureProbe.mirrorToPlayCoverContainer(reportDir, subfolder: "OCRProbe")

        NSLog("%@ count=%d method=%@ preview=%@", logTag, elements.count, capture.method, preview)
        DispatchQueue.main.async {
            Toast.showHint(title: "OCR probe", text: [
                "count: \(elements.count)",
                "method: \(capture.method)",
                preview.isEmpty ? "(no text)" : String(preview.prefix(80))
            ])
        }
        return reportDir
    }

    // MARK: - Vision

    private static func recognize(image: UIImage, logicSize: CGSize) throws -> [Element] {
        guard let cgImage = image.cgImage else {
            throw NSError(domain: "OCRProbe", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "no cgImage"
            ])
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        if #available(iOS 16.0, *) {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = ["en-US", "zh-Hans", "zh-Hant"]
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        let observations = request.results ?? []
        var elements: [Element] = []
        elements.reserveCapacity(observations.count)

        for (idx, obs) in observations.enumerated() {
            guard let top = obs.topCandidates(1).first else { continue }
            let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            // Vision bbox: origin bottom-left, normalized
            let vb = obs.boundingBox
            let xmin = Double(vb.origin.x)
            let yminUI = Double(1 - vb.origin.y - vb.height) // flip to top-left
            let xmax = Double(vb.origin.x + vb.width)
            let ymaxUI = Double(1 - vb.origin.y)
            let cx = (xmin + xmax) / 2
            let cy = (yminUI + ymaxUI) / 2

            let xLogic = cx * Double(logicSize.width)
            let yLogic = cy * Double(logicSize.height)

            elements.append(Element(
                id: idx,
                text: text,
                conf: top.confidence,
                bbox: [xmin, yminUI, xmax, ymaxUI],
                cx: cx,
                cy: cy,
                x: xLogic,
                y: yLogic
            ))
        }

        // Stable order: top-to-bottom, then left-to-right
        elements.sort { a, b in
            if abs(a.cy - b.cy) > 0.02 { return a.cy < b.cy }
            return a.cx < b.cx
        }
        // Re-id after sort
        return elements.enumerated().map { i, el in
            Element(id: i, text: el.text, conf: el.conf, bbox: el.bbox,
                    cx: el.cx, cy: el.cy, x: el.x, y: el.y)
        }
    }

    private static func writeJSON(_ obj: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: url)
    }
}
