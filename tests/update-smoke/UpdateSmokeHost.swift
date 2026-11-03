import AppKit
import CryptoKit
import Foundation
import Sparkle

/// Dedicated Sparkle harness. No MeetingScribe runtime or capture code is linked.
@main struct UpdateSmokeHost {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = SmokeDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor final class SmokeDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    var controller: SPUStandardUpdaterController?
    var output: URL { URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "SmokeOutput") as! String) }
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String }
    let transcript = "{\"t\":\"2026-11-02T12:00:00Z\",\"ch\":\"remote\",\"text\":\"Delivery has not been tested.\",\"spk\":\"R1\"}\n"
    let plain = "[12:00:00] REMOTE: Delivery has not been tested.\n"

    func report(_ name: String, extra: [String: Any] = [:]) {
        var object: [String: Any] = ["event": name, "version": version, "bundleID": Bundle.main.bundleIdentifier!, "pid": ProcessInfo.processInfo.processIdentifier]
        extra.forEach { object[$0] = $1 }
        do { try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("\(version)-\(name).json"), options: .atomic) }
        catch { fputs("Report error: \(error)\n", stderr) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let data = output.appendingPathComponent("data")
            if version == "9.0.0" {
                try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
                try Data(transcript.utf8).write(to: data.appendingPathComponent("transcript.jsonl"), options: .atomic)
                try Data(plain.utf8).write(to: data.appendingPathComponent("transcript.txt"), options: .atomic)
                report("seeded")
                controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
                try controller!.updater.start()
                controller!.updater.checkForUpdatesInBackground()
            } else {
                let jsonl = try Data(contentsOf: data.appendingPathComponent("transcript.jsonl"))
                let txt = try Data(contentsOf: data.appendingPathComponent("transcript.txt"))
                let matches = jsonl == Data(transcript.utf8) && txt == Data(plain.utf8)
                report("verified", extra: ["unchanged": matches, "jsonlSHA256": SHA256.hash(data: jsonl).map { String(format: "%02x", $0) }.joined(), "textSHA256": SHA256.hash(data: txt).map { String(format: "%02x", $0) }.joined()])
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        } catch { report("error", extra: ["description": error.localizedDescription]); NSApp.terminate(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
            self?.report("timeout"); NSApp.terminate(nil)
        }
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) { report("downloaded") }
    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) { report("extracted") }
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        report("install-on-quit")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
        return true
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        report("error", extra: ["description": error.localizedDescription, "domain": (error as NSError).domain, "code": (error as NSError).code])
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}
