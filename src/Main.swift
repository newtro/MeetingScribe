import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--advisortest"), i + 1 < args.count {
            let b = args.firstIndex(of: "--brief").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            DevModes.advisor(jsonl: args[i + 1], brief: b)
        } else if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            DevModes.render(out: args[i + 1], dark: args.contains("--dark"), idle: args.contains("--idle"))
        } else if let i = args.firstIndex(of: "--filetest"), i + 2 < args.count {
            FileTest.run(remotePath: args[i + 1], localPath: args[i + 2])
        } else if let i = args.firstIndex(of: "--selftest") {
            let secs = (i + 1 < args.count ? Double(args[i + 1]) : nil) ?? 30
            SelfTest.run(seconds: secs)
        } else {
            MeetingScribeApp.main()
        }
    }
}

/// Headless stage-1 check: capture both channels for N seconds, transcribe, write session files.
/// Launch via `open -W MeetingScribe.app --args --selftest 30` so TCC attributes it to the bundle.
enum SelfTest {
    static func log(_ s: String) {
        let line = "[\(Fmt.clock.string(from: Date()))] \(s)\n"
        FileHandle.standardError.write(Data(line.utf8))
        let url = Paths.root.appendingPathComponent("selftest.log")
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    static func run(seconds: Double) {
        guard #available(macOS 26.0, *) else { log("needs macOS 26"); exit(1) }
        NSApplication.shared.setActivationPolicy(.accessory)
        Task {
            log("selftest start, \(seconds)s")
            log("screen recording preflight: \(AudioCapture.hasScreenRecordingPermission)")
            if !AudioCapture.hasScreenRecordingPermission { log("requesting: \(CGRequestScreenCaptureAccess())") }
            let mic = await AVCaptureDevice.requestAccess(for: .audio)
            log("microphone access: \(mic)")
            let locale = await SpeechModel.locale()
            do {
                try await SpeechModel.ensureInstalled(locale: locale) { p, msg in log("model: \(msg) \(p)") }
            } catch {
                log("model install failed: \(error)"); exit(2)
            }
            let rec = Recorder()
            rec.onFinal = { u in log("FINAL \(u.ch.label): \(u.text)") }
            rec.onError = { msg in log("ERROR \(msg)") }
            do {
                let store = try await rec.start(locale: locale)
                log("recording to \(store.dir.path)")
            } catch {
                log("start failed: \(error)")
                exit(3)
            }
            try? await Task.sleep(for: .seconds(seconds))
            let c = rec.bufferCounts
            log("buffers remote=\(c.remote) local=\(c.local); stopping")
            await rec.stop()
            log("selftest done")
            exit(0)
        }
        NSApplication.shared.run()
    }
}

/// Feeds two audio files through the same CMSampleBuffer → transcriber → SessionStore path as live capture,
/// at real-time pace. Validates everything except ScreenCaptureKit itself (which needs TCC).
enum FileTest {
    static func run(remotePath: String, localPath: String) {
        guard #available(macOS 26.0, *) else { exit(1) }
        Task {
            let locale = await SpeechModel.locale()
            do {
                let store = try SessionStore(start: Date())
                SelfTest.log("filetest → \(store.dir.path)")
                var ts: [ChannelTranscriber] = []
                for (ch, path) in [(Channel.remote, remotePath), (.local, localPath)] {
                    let t = try await ChannelTranscriber.make(channel: ch, locale: locale)
                    t.onFinal = { u in store.append(u); SelfTest.log("FINAL \(u.ch.label): \(u.text)") }
                    t.onError = { c, m in SelfTest.log("ERROR \(c.label): \(m)") }
                    try await t.start(wallStart: Date())
                    ts.append(t)
                    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
                    let q = DispatchQueue(label: "feed.\(ch.rawValue)")
                    q.async {
                        let fmt = file.processingFormat
                        let chunk = AVAudioFrameCount(fmt.sampleRate / 50) // 20ms like SCStream
                        var frame: Int64 = 0
                        let base = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                        while let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk),
                              (try? file.read(into: buf, frameCount: chunk)) != nil, buf.frameLength > 0 {
                            let pts = CMTime(seconds: base + Double(frame) / fmt.sampleRate, preferredTimescale: 48000)
                            if let sb = makeSampleBuffer(buf, pts: pts) { t.feed(sb) }
                            frame += Int64(buf.frameLength)
                            Thread.sleep(forTimeInterval: 0.02)
                        }
                        SelfTest.log("fed \(ch.label) \(frame) frames")
                    }
                }
                try? await Task.sleep(for: .seconds(2))
                // wait for both feeders: file length bound
                let maxLen = try [remotePath, localPath].map { p -> Double in
                    let f = try AVAudioFile(forReading: URL(fileURLWithPath: p)); return Double(f.length) / f.processingFormat.sampleRate
                }.max() ?? 0
                try? await Task.sleep(for: .seconds(maxLen * 1.2 + 2))
                for t in ts { await t.finish() }
                store.close()
                SelfTest.log("filetest done")
                exit(0)
            } catch {
                SelfTest.log("filetest failed: \(error)"); exit(2)
            }
        }
        NSApplication.shared.run()
    }

    static func makeSampleBuffer(_ buf: AVAudioPCMBuffer, pts: CMTime) -> CMSampleBuffer? {
        var sb: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(buf.format.sampleRate)),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                   makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: buf.format.formatDescription,
                                   sampleCount: CMItemCount(buf.frameLength), sampleTimingEntryCount: 1,
                                   sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &sb) == noErr, let sb else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(sb, blockBufferAllocator: kCFAllocatorDefault,
                                                             blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                             flags: 0, bufferList: buf.audioBufferList) == noErr else { return nil }
        return sb
    }
}

enum DevModes {
    /// Replays a transcript.jsonl as if it were the last few minutes and runs one advisor cycle.
    static func advisor(jsonl: String, brief: String? = nil) {
        Task {
            let lines = (try? String(contentsOfFile: jsonl, encoding: .utf8))?.split(separator: "\n") ?? []
            let now = Date()
            var us: [Utterance] = []
            for (i, l) in lines.enumerated() {
                guard let o = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any],
                      let text = o["text"] as? String, let ch = Channel(rawValue: o["ch"] as? String ?? "") else { continue }
                us.append(Utterance(t: now.addingTimeInterval(Double(i - lines.count) * 8), ch: ch, text: text))
            }
            let a = Advisor()
            if let brief { a.setContext(URL(fileURLWithPath: brief)) }
            for round in 1...2 {
                let t0 = Date()
                let out = await a.run(utterances: us)
                print("round \(round) (\(String(format: "%.1f", Date().timeIntervalSince(t0)))s):")
                switch out {
                case .items(let items): print(Advisor.markdown(items))
                case .silent: print("  silent / all deduped")
                case .skipped(let w): print("  skipped: \(w)")
                case .failed(let w): print("  failed: \(w)")
                }
            }
            exit(0)
        }
        dispatchMain()
    }

    /// Renders the main window offscreen with sample data to a PNG.
    @MainActor static func render(out: String, dark: Bool, idle: Bool = false) {
        guard #available(macOS 26.0, *) else { exit(1) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let m = AppModel.shared
        let now = Date()
        m.phase = idle ? .idle : .recording
        m.startedAt = now.addingTimeInterval(-1934)
        m.advisorStatus = "Last check 10:32:14 — 3 new"
        // Invented sample data for UI renders — keep real meeting content out of the repo.
        m.utterances = [
            Utterance(t: now.addingTimeInterval(-60), ch: .remote, text: "We'd also like the dashboard to export straight into our finance system every week."),
            Utterance(t: now.addingTimeInterval(-52), ch: .remote, text: "Can you just add that to the reporting module?"),
            Utterance(t: now.addingTimeInterval(-40), ch: .local, text: "Yeah, I think we can probably fold that into the reporting work."),
            Utterance(t: now.addingTimeInterval(-20), ch: .remote, text: "Great. And the weekend team needs its own approval flow too."),
        ]
        m.volatile = [.local: "Let me make sure I understand the timing"]
        let a = [
            Suggestion(at: now, kind: .flag, text: "You just accepted a finance-system export. That's outside the agreed scope — name a change request: \"That's a real need; let me scope it and come back with hours and cost.\""),
            Suggestion(at: now, kind: .ask, text: "Does the finance system need a file drop, or a direct integration with an API?"),
            Suggestion(at: now, kind: .answer, text: "The approval schedule is already agreed: submit by Monday noon, approvals due Tuesday 5pm."),
        ]
        m.suggestions = a + [Suggestion(at: now.addingTimeInterval(-90), kind: .ask, text: "Who owns the source data today, and can we get read access this week?")]
        m.latestBatch = Set(a.map(\.id))
        let view = RootView().environmentObject(m).frame(width: 1400, height: 860)
        let host = NSHostingView(rootView: view)
        host.appearance = app.appearance
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860), styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(2) }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            exit(0)
        }
        app.run()
    }
}
