// Minimal OCR helper for the Nomily UI tests.
//
// The app's SwiftUI content is **not exposed through accessibility** (the tree only carries
// the tab bar), so assertions have to read the screen. Vision gives us text + bounding boxes
// without any third-party dependency.
//
// Usage:  nomily-ocr <png-path>
// Output: JSON array of {text, x, y, w, h} — **points**, origin top-left, ready to feed
//         straight into WDA taps.

import AppKit
import Foundation
import Vision

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: nomily-ocr <png>\n".utf8))
    exit(2)
}

let path = CommandLine.arguments[1]
guard let image = NSImage(contentsOfFile: path),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
    exit(3)
}

let pointWidth = Double(cgImage.width) / 3.0
let pointHeight = Double(cgImage.height) / 3.0

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.recognitionLanguages = ["zh-Hans", "en-US"]
request.usesLanguageCorrection = true

let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
try handler.perform([request])

var rows: [[String: Any]] = []
for observation in request.results ?? [] {
    guard let candidate = observation.topCandidates(1).first else { continue }
    let box = observation.boundingBox // normalized, origin bottom-left
    let x = box.origin.x * pointWidth
    let y = (1 - box.origin.y - box.size.height) * pointHeight
    rows.append([
        "text": candidate.string,
        "x": x,
        "y": y,
        "w": box.size.width * pointWidth,
        "h": box.size.height * pointHeight,
    ])
}

let data = try JSONSerialization.data(withJSONObject: rows)
print(String(decoding: data, as: UTF8.self))
