import Foundation
import CoreGraphics
import ScreenCaptureKit
import Vision

/// One-shot OCR of the frontmost window. Used only as a fallback when the
/// accessibility tree yields too little text. Never runs continuously.
public enum ScreenOCR {
    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    public static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Captures one frame of the app's largest visible window and recognizes text.
    /// Runs on a background thread; blocks up to `timeout` seconds.
    public static func captureText(pid: pid_t, timeout: TimeInterval = 2.5) -> String? {
        guard hasPermission else { return nil }

        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()

        Task.detached(priority: .utility) {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let window = content.windows
                    .filter({ $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 160 && $0.frame.height > 80 })
                    .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
                else {
                    box.value = nil
                    semaphore.signal()
                    return
                }

                let filter = SCContentFilter(desktopIndependentWindow: window)
                let configuration = SCStreamConfiguration()
                let scale = min(2.0, 2400.0 / max(window.frame.width, 1))
                configuration.width = max(1, Int(window.frame.width * scale))
                configuration.height = max(1, Int(window.frame.height * scale))
                configuration.showsCursor = false
                configuration.capturesAudio = false

                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                box.value = recognize(image)
            } catch {
                box.value = nil
            }
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + timeout)
        return box.value
    }

    private static func recognize(_ image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            request.recognitionLanguages = ["zh-Hans"]
            guard (try? handler.perform([request])) != nil else { return nil }
        }

        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        var value: String? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
            set {
                lock.lock()
                stored = newValue
                lock.unlock()
            }
        }
    }
}
