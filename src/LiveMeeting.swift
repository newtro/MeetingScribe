import Foundation
import Combine

struct LiveCue: Identifiable, Codable, Sendable {
    var id = UUID()
    var at: Date
    var text: String
    var kind: SuggestionKind
    var claimKind: ClaimKind
    var sourceIDs: [String]
    var quotes: [String]
    var issueID: UUID?
    var status: String
    var assumptions: [String] = []
    var validation: String? = nil
    var trigger: SpeechReference? = nil
    var evidenceDetails: [String] = []
    var proposalStatus: String? = nil
    var label: String { claimKind.rawValue.uppercased() }
    var evidence: String { evidenceDetails.isEmpty ? sourceIDs.joined(separator: ", ") : evidenceDetails.joined(separator: "\n") }
    var suggestion: Suggestion {
        Suggestion(at: at, kind: kind, text: "[\(label)] \(text)" + (sourceIDs.isEmpty ? "" : " [\(evidence)]"))
    }
}

struct LiveTopic: Identifiable, Codable, Sendable {
    var id = UUID()
    var key: String
    var title: String
    var status: String
    var priority: TopicPriority
    var current: Bool
    var slot: Int
    var cueID: UUID?
    var pinned = false
}

struct LiveIssue: Identifiable, Codable, Sendable {
    var id = UUID()
    var title: String
    var question: String
    var state: String
    var priority: Int
    var reason: String
    var firstSeen: Date
    var updatedAt: Date
    var trigger: SpeechReference?
    var sourceIDs: [String] = []
    var isOpen: Bool { ["open", "answeredReported", "answeredSupported"].contains(state) }
}

/// Owns live advice, not capture or archival transcript. Main-actor isolation serializes publication.
@MainActor final class LiveMeetingCoordinator: ObservableObject {
    @Published private(set) var cues: [LiveCue] = []
    @Published private(set) var backgroundCues: [LiveCue] = []
    @Published private(set) var topics: [LiveTopic] = []
    @Published private(set) var issues: [LiveIssue] = []
    @Published private(set) var status = "Not listening"
    @Published private(set) var lastReceipt: ModelReceipt?
    @Published var fastMode = false
    var onCue: ((LiveCue) -> Void)?

    private let provider: AdviceProvider
    private let debounceNanoseconds: UInt64
    private var sessionID: UUID?
    private var sessionDir: URL?
    private var packet: PreparedPacket?
    private var corpus = LocalCorpus()
    private var speech: [UUID: SpeechEvent] = [:]
    private var transcriptRevision = 0
    private var contextRevision = 0
    private var typedQuestions: [UUID: String] = [:]
    private var debounceTask: Task<Void, Never>?
    private var detectorTask: Task<Void, Never>?
    private var workerTask: Task<Void, Never>?
    private var runningJob: ResearchRequest?
    private var queue = ResearchQueue()
    private var detectorAgain = false
    private var lastDetection = Date.distantPast
    private var storageError: String?
    private var activeStateSessionID: UUID?
    private var savedPacketIDs = Set<UUID>()
    private var downgrades: [UUID: (priority: TopicPriority, count: Int, began: Date)] = [:]

    init(provider: AdviceProvider = .live, debounceNanoseconds: UInt64 = 550_000_000) {
        self.provider = provider; self.debounceNanoseconds = debounceNanoseconds
    }

    func start(sessionID: UUID, sessionDir: URL, packet: PreparedPacket?) {
        stop()
        self.sessionID = sessionID; self.sessionDir = sessionDir; self.packet = packet
        activeStateSessionID = sessionID
        speech = [:]; transcriptRevision = 0; contextRevision = 0; typedQuestions = [:]
        cues = []; backgroundCues = []; issues = []; topics = []; storageError = nil; lastReceipt = nil; fastMode = false
        savedPacketIDs = []; downgrades = [:]
        loadCorpus(); seedTopics()
        saveContextRevision()
        setStatus(packet == nil || corpus.excerpts.isEmpty ? "Listening · project evidence unavailable" : "Listening")
        persist()
    }

    func setCorpus(_ excerpts: [SourceExcerpt]) { corpus = LocalCorpus(excerpts: excerpts) }

    private func loadCorpus() {
        guard let packet else { corpus = LocalCorpus(); return }
        do { corpus = LocalCorpus(excerpts: try ProjectStore().excerpts(for: packet)) }
        catch { corpus = LocalCorpus(); setStatus("Listening · evidence snapshot unavailable") }
    }

    private func seedTopics() {
        topics = (packet?.topics ?? []).enumerated().map { slot, topic in
            LiveTopic(key: LocalCorpus.tokens(topic.key).sorted().joined(separator: " "), title: String(topic.title.prefix(30)), status: topic.reason,
                      priority: topic.priority, current: false, slot: slot, cueID: nil)
        }
    }

    func ingest(_ event: SpeechEvent) {
        guard sessionID != nil else { return }
        if let previous = speech[event.id], event.revision <= previous.revision { return }
        speech[event.id] = event; transcriptRevision += 1
        // Retracted/revised premises revoke dependent suggestions immediately, without waiting for AI.
        for index in cues.indices where cues[index].trigger?.id == event.id &&
            (event.retracted || cues[index].trigger?.revision != event.revision) {
            cues[index].status = "superseded"
        }
        for index in backgroundCues.indices where backgroundCues[index].trigger?.id == event.id &&
            (event.retracted || backgroundCues[index].trigger?.revision != event.revision) {
            backgroundCues[index].status = "superseded"
        }
        for index in issues.indices where issues[index].trigger?.id == event.id &&
            (event.retracted || issues[index].trigger?.revision != event.revision) {
            issues[index].state = "superseded"; issues[index].updatedAt = Date()
        }
        queue.remove { $0.trigger?.id == event.id && (event.retracted || $0.trigger?.revision != event.revision) }
        if let job = runningJob, job.trigger?.id == event.id && (event.retracted || job.trigger?.revision != event.revision) {
            workerTask?.cancel() // publication also validates this reference after awaiting.
        }
        if event.retracted { persist() }
        scheduleDetection()
    }

    func ask(_ text: String, research: Bool = false) {
        guard let sessionID else { return }
        let question = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        guard !question.isEmpty else { return }
        let typedID = UUID(), now = Date()
        typedQuestions[typedID] = question // Separate provenance: never inserted into speech.
        let issue = LiveIssue(title: String(question.prefix(80)), question: question, state: "open", priority: 3,
                              reason: "Typed question", firstSeen: now, updatedAt: now, trigger: nil)
        issues.append(issue)
        submit(ResearchRequest(sessionID: sessionID, packetID: packet?.id, issueID: issue.id, trigger: nil,
                               typedQuestionID: typedID, transcriptRevision: transcriptRevision, query: question,
                               priority: 3, submittedAt: now, deadline: now.addingTimeInterval(research ? 25 : 10),
                               role: research ? .research : .cue))
        persist()
    }

    func replaceContext(_ packet: PreparedPacket?) {
        guard sessionID != nil else { self.packet = packet; return }
        contextRevision += 1; self.packet = packet
        detectorTask?.cancel(); workerTask?.cancel(); debounceTask?.cancel()
        queue.clear()
        for index in cues.indices where cues[index].status != "superseded" { cues[index].status = "previous context" }
        for index in backgroundCues.indices where backgroundCues[index].status != "superseded" { backgroundCues[index].status = "previous context" }
        // Whole-meeting unresolved issues survive a context refresh.
        loadCorpus(); saveContextRevision(); setStatus("Context updated · previous cues retained for review")
        persist(); scheduleDetection()
    }

    func stop() {
        sessionID = nil // Close publication before cancellation or persistence.
        debounceTask?.cancel(); detectorTask?.cancel(); workerTask?.cancel()
        debounceTask = nil; detectorTask = nil; workerTask = nil; runningJob = nil
        queue.clear(); detectorAgain = false
        persist(); sessionDir = nil; status = storageError ?? "Stopped"
    }

    func dismiss(cueID: UUID) {
        if let index = cues.firstIndex(where: { $0.id == cueID }) { cues[index].status = "dismissed"; persist() }
        if let index = backgroundCues.firstIndex(where: { $0.id == cueID }) { backgroundCues[index].status = "dismissed"; persist() }
    }

    func pin(topicID: UUID) {
        if let index = topics.firstIndex(where: { $0.id == topicID }) { topics[index].pinned.toggle(); persist() }
    }

    func showBackground(cueID: UUID) {
        guard let index = backgroundCues.firstIndex(where: { $0.id == cueID }), backgroundCues[index].status == "background" else { return }
        var cue = backgroundCues.remove(at: index); cue.status = "review"
        cues.append(cue); persist()
    }

    func setProposalStatus(cueID: UUID, status: String) {
        guard ["proposed", "discussed", "investigate", "acceptedForImplementation", "rejected", "superseded"].contains(status) else { return }
        if let index = cues.firstIndex(where: { $0.id == cueID && $0.claimKind == .proposal }) { cues[index].proposalStatus = status }
        if let index = backgroundCues.firstIndex(where: { $0.id == cueID && $0.claimKind == .proposal }) { backgroundCues[index].proposalStatus = status }
        persist()
    }

    private func setStatus(_ text: String) { status = storageError.map { text + " · " + $0 } ?? text }

    private func scheduleDetection() {
        guard sessionID != nil else { return }
        if detectorTask != nil { detectorAgain = true; return }
        // Coalesce deltas without postponing indefinitely while somebody keeps speaking.
        guard debounceTask == nil else { return }
        let wait = max(Double(debounceNanoseconds) / 1_000_000_000, 2.5 - Date().timeIntervalSince(lastDetection))
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.debounceTask = nil; self.detect()
        }
    }

    private func current(_ reference: SpeechReference, finalOnly: Bool = false) -> Bool {
        guard let segment = speech[reference.id], segment.revision == reference.revision, !segment.retracted else { return false }
        return !finalOnly || segment.final
    }

    private func recentSpeech() -> [SpeechEvent] {
        let cutoff = Date().addingTimeInterval(-90)
        return speech.values.filter { !$0.retracted && $0.t >= cutoff }.sorted {
            $0.t == $1.t ? $0.id.uuidString < $1.id.uuidString : $0.t < $1.t
        }
    }

    private func speechPrompt() -> String {
        let lines = recentSpeech().map {
            "id=\($0.id) revision=\($0.revision) \($0.final ? "FINAL" : "PARTIAL") \($0.channel.rawValue) speaker=\($0.speaker ?? "unknown") source=speech:\($0.id.uuidString)\n\($0.text)"
        }.joined(separator: "\n")
        return Self.suffixUTF8(lines, maxBytes: 20 * 1024)
    }

    private func issuePrompt() -> String {
        var chosen = Array(issues.filter(\.isOpen).sorted { $0.priority > $1.priority }.prefix(12))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        while !chosen.isEmpty {
            if let data = try? encoder.encode(chosen), data.count <= 8 * 1024 { return String(decoding: data, as: UTF8.self) }
            chosen.removeLast()
        }
        return "[]"
    }

    private func evidencePrompt(_ excerpts: [SourceExcerpt]) -> String {
        excerpts.map { "SOURCE \($0.source.id) path=\($0.source.relativePath) observed=\(Fmt.iso.string(from: $0.source.observedAt)) kind=\($0.source.kind.rawValue)\n\($0.text)" }.joined(separator: "\n\n")
    }

    private func detect() {
        guard let session = sessionID, detectorTask == nil, !recentSpeech().isEmpty else { return }
        let context = contextRevision, revision = transcriptRevision
        let packetID = packet?.id, text = speechPrompt()
        let evidence = corpus.search(query: recentSpeech().suffix(4).map(\.text).joined(separator: " "), limit: 6, byteLimit: 16 * 1024)
        let prompt = AdviceSchemas.safety + "\nMaintain topic/issue state. Reference only exact supplied segment IDs and revisions.\n" +
            "OPEN ISSUES\n" + issuePrompt() + "\nPROJECT\n" + String((packet?.projectSummary ?? "No project evidence").prefix(2000)) +
            "\nEVIDENCE\n" + evidencePrompt(evidence) + "\nRECENT SPEECH\n" + text
        lastDetection = Date(); setStatus("Listening · checking attention")
        detectorTask = Task { [weak self, provider] in
            guard let self else { return }
            defer {
                if self.sessionID == session {
                    self.detectorTask = nil
                    if self.detectorAgain { self.detectorAgain = false; self.scheduleDetection() }
                }
            }
            do {
                let result = try await provider.detect(prompt)
                guard !Task.isCancelled, self.sessionID == session, self.contextRevision == context, self.packet?.id == packetID else { return }
                let response = try JSONDecoder().decode(ListenerResponse.self, from: Data(result.text.utf8))
                self.lastReceipt = result.receipt
                self.apply(response, snapshotRevision: revision, evidence: evidence)
                self.setStatus(self.runningJob == nil ? "Listening" : "Listening · researching")
                self.metric("detector_complete", receipt: result.receipt)
            } catch is CancellationError { }
            catch {
                guard self.sessionID == session, self.contextRevision == context else { return }
                self.setStatus(error is DecodingError ? "Listening · invalid attention response rejected" : "Listening · attention check unavailable")
                self.metric("detector_failed")
            }
        }
    }

    private func apply(_ response: ListenerResponse, snapshotRevision: Int, evidence: [SourceExcerpt]) {
        guard response.schemaVersion == 1, response.topics.count <= 4, response.issues.count <= 6, response.research.count <= 2 else {
            setStatus("Listening · invalid attention response rejected"); return
        }
        for change in response.topics where current(change.trigger) {
            let key = LocalCorpus.tokens(change.key).sorted().joined(separator: " ")
            guard !key.isEmpty else { continue }
            let priority: TopicPriority = change.priority >= 3 ? .attention : change.priority >= 2 ? .discussion : .background
            let confirmed = current(change.trigger, finalOnly: true) && snapshotRevision == transcriptRevision
            if confirmed && change.current {
                for index in topics.indices { topics[index].current = topics[index].key == key }
            }
            if let index = topics.firstIndex(where: { $0.key == key }) {
                // Slot remains stable; higher consequence can promote immediately.
                topics[index].status = String(change.reason.prefix(120)); topics[index].current = change.current
                if Self.rank(priority) >= Self.rank(topics[index].priority) {
                    topics[index].priority = priority; downgrades.removeValue(forKey: topics[index].id)
                } else if confirmed {
                    let id = topics[index].id
                    let previous = downgrades[id]
                    let count = previous?.priority == priority ? (previous?.count ?? 0) + 1 : 1
                    let began = previous?.priority == priority ? previous!.began : Date()
                    downgrades[id] = (priority, count, began)
                    if count >= 2 && Date().timeIntervalSince(began) >= 4 { topics[index].priority = priority; downgrades.removeValue(forKey: id) }
                }
                if confirmed && change.current { promoteTopic(at: index) }
            } else {
                topics.append(LiveTopic(key: key, title: String(change.title.prefix(30)), status: String(change.reason.prefix(120)),
                                        priority: priority, current: change.current, slot: topics.count, cueID: nil))
                if confirmed && change.current { promoteTopic(at: topics.count - 1) }
            }
        }
        for change in response.issues where current(change.trigger, finalOnly: true) {
            guard change.title.count <= 160, change.question.count <= 1000, change.reason.count <= 400,
                  ["open", "answeredReported", "answeredSupported", "resolved", "dismissed", "superseded"].contains(change.state) else { continue }
            if let id = change.id {
                guard let index = issues.firstIndex(where: { $0.id == id }) else { continue }
                // A state-changing conclusion requires the complete current conversational snapshot.
                guard change.state == "open" || snapshotRevision == transcriptRevision else { continue }
                if change.state == "resolved" || change.state == "answeredSupported" {
                    // A detector assertion alone cannot establish resolution; require a supported cue.
                    guard let cue = response.cue, cue.issueID == id, !cue.sourceIDs.isEmpty,
                          validate(cue, evidence: evidence, requireFinal: true) else { continue }
                }
                issues[index].state = change.state; issues[index].updatedAt = Date()
                issues[index].priority = min(3, max(0, change.priority)); issues[index].reason = change.reason
                issues[index].trigger = change.trigger
            } else {
                let key = LocalCorpus.tokens(change.question)
                guard !issues.contains(where: { $0.isOpen && LocalCorpus.tokens($0.question) == key }) else { continue }
                issues.append(LiveIssue(title: change.title, question: change.question, state: "open",
                                        priority: min(3, max(0, change.priority)), reason: change.reason,
                                        firstSeen: Date(), updatedAt: Date(), trigger: change.trigger))
            }
        }
        if let cue = response.cue, snapshotRevision == transcriptRevision, validate(cue, evidence: evidence, requireFinal: true) {
            publish(cue, status: "current")
        }
        for request in response.research where current(request.trigger) {
            guard let sessionID, request.query.count <= 1000, !request.query.isEmpty else { continue }
            let issueID: UUID
            if let id = request.issueID {
                guard issues.contains(where: { $0.id == id && $0.isOpen }) else { continue }
                issueID = id
            } else if let issue = issues.last(where: { $0.trigger == request.trigger && $0.isOpen }) { issueID = issue.id }
            else {
                // Partial speech can start retrieval without claiming a durable decision/commitment.
                let issue = LiveIssue(title: String(request.query.prefix(80)), question: request.query, state: "open",
                                      priority: min(2, max(0, request.priority)), reason: "Investigating provisional speech",
                                      firstSeen: Date(), updatedAt: Date(), trigger: request.trigger)
                issues.append(issue); issueID = issue.id
            }
            submit(ResearchRequest(sessionID: sessionID, packetID: packet?.id, issueID: issueID,
                                   trigger: request.trigger, typedQuestionID: nil, transcriptRevision: snapshotRevision,
                                   query: request.query, priority: min(3, max(0, request.priority)),
                                   submittedAt: Date(), deadline: Date().addingTimeInterval(25)))
        }
        persist()
    }

    private func submit(_ request: ResearchRequest) {
        if runningJob?.key == request.key { return }
        guard queue.submit(request) else { metric("queue_duplicate_or_full"); return }
        if let running = runningJob, request.priority >= 3, running.priority < request.priority {
            workerTask?.cancel() // Do not start the next process until cancellation finishes.
            metric("worker_preempted")
        }
        startWorker()
    }

    private func jobCurrent(_ job: ResearchRequest) -> Bool {
        guard sessionID == job.sessionID, packet?.id == job.packetID,
              issues.contains(where: { $0.id == job.issueID && $0.isOpen }) else { return false }
        if let typedID = job.typedQuestionID { return typedQuestions[typedID] != nil }
        return job.trigger.map { current($0) } ?? false
    }

    private func startWorker() {
        guard workerTask == nil, let job = queue.next(), jobCurrent(job) else {
            if workerTask == nil, !queue.pending.isEmpty { startWorker() }
            return
        }
        runningJob = job
        let context = contextRevision
        let evidence = corpus.search(query: job.query)
        let prompt = AdviceSchemas.safety + "\nAnswer this question or return cue:null and explicit unknown.\nQUESTION\n" + job.query +
            "\nIssue ID: \(job.issueID)\nTrigger: " + (job.trigger.map { "\($0.id) revision=\($0.revision)" } ?? "typed question; trigger must be null") +
            "\nEVIDENCE\n" + evidencePrompt(evidence) + "\nRECENT SPEECH\n" + speechPrompt()
        let fast = fastMode && job.role == .research; setStatus("Listening · researching")
        workerTask = Task { [weak self, provider] in
            guard let self else { return }
            defer {
                if self.runningJob?.id == job.id {
                    self.workerTask = nil; self.runningJob = nil
                    self.startWorker()
                }
            }
            do {
                let result = try await provider.answer(prompt, job.role, fast, max(0.1, job.deadline.timeIntervalSinceNow))
                guard !Task.isCancelled, self.contextRevision == context, self.jobCurrent(job), Date() <= job.deadline else { return }
                struct Answer: Decodable { var cue: ProposedCue?; var unknown: String }
                let answer = try JSONDecoder().decode(Answer.self, from: Data(result.text.utf8))
                self.lastReceipt = result.receipt
                if let cue = answer.cue,
                   cue.issueID == job.issueID, cue.trigger == job.trigger,
                   self.validate(cue, evidence: evidence, requireFinal: true, typed: job.typedQuestionID != nil) {
                    // Useful completed research is retained when the speaking opportunity has passed.
                    self.publish(cue, status: job.transcriptRevision == self.transcriptRevision ? "current" : "background")
                } else { self.setStatus("Listening · answer not established") }
                self.metric("research_complete", receipt: result.receipt); self.persist()
            } catch is CancellationError { }
            catch {
                guard self.contextRevision == context, self.sessionID == job.sessionID else { return }
                self.setStatus("Listening · research unavailable"); self.metric("research_failed")
            }
        }
    }

    private func validate(_ cue: ProposedCue, evidence: [SourceExcerpt], requireFinal: Bool, typed: Bool = false) -> Bool {
        guard !cue.text.isEmpty, cue.text.count <= 600, cue.text.split(whereSeparator: \.isWhitespace).count <= 45,
              SuggestionKind(rawValue: cue.kind) != nil, cue.sourceIDs.count <= 6,
              cue.sourceIDs.count == cue.quotes.count, cue.quotes.allSatisfy({ $0.count <= 2000 }),
              (cue.assumptions ?? []).count <= 3, (cue.assumptions ?? []).allSatisfy({ $0.count <= 400 }),
              (cue.validation ?? "").count <= 600 else { return false }
        if let issueID = cue.issueID, !issues.contains(where: { $0.id == issueID }) { return false }
        if let trigger = cue.trigger { guard current(trigger, finalOnly: requireFinal) else { return false } }
        else if !typed { return false }
        if cue.sourceIDs.isEmpty {
            return cue.claimKind == .proposal && cue.text.contains("?") && !(cue.validation ?? "").isEmpty
        }
        for (id, quote) in zip(cue.sourceIDs, cue.quotes) {
            guard !quote.isEmpty else { return false }
            if let source = evidence.first(where: { $0.source.id == id }) {
                guard source.text.contains(quote), source.source.observedAt <= (packet?.preparedAt ?? Date()) else { return false }
                if cue.claimKind == .fact && [.executionReport, .conversation, .proposal].contains(source.source.kind) { return false }
            } else if id.hasPrefix("speech:"), cue.claimKind != .fact,
                      let uuid = UUID(uuidString: String(id.dropFirst(7))), let event = speech[uuid] {
                guard event.final, !event.retracted, event.text.contains(quote) else { return false }
            } else { return false }
        }
        if cue.claimKind == .proposal { return !(cue.validation ?? "").isEmpty }
        return true
    }

    private func publish(_ candidate: ProposedCue, status: String) {
        let words = LocalCorpus.tokens(candidate.text)
        guard !(cues + backgroundCues).suffix(12).contains(where: {
            $0.status != "superseded" && $0.claimKind == candidate.claimKind &&
            $0.sourceIDs == candidate.sourceIDs && LocalCorpus.tokens($0.text) == words
        }) else { return }
        let details = zip(candidate.sourceIDs, candidate.quotes).map { id, quote -> String in
            if let source = corpus.excerpts.first(where: { $0.source.id == id })?.source {
                return "\(source.relativePath):\(source.startLine)–\(source.endLine) · observed \(Fmt.iso.string(from: source.observedAt))\n“\(quote)”"
            }
            return "Meeting speech · \(id.replacingOccurrences(of: "speech:", with: ""))\n“\(quote)”"
        }
        let cue = LiveCue(at: Date(), text: candidate.text, kind: SuggestionKind(rawValue: candidate.kind)!,
                          claimKind: candidate.claimKind, sourceIDs: candidate.sourceIDs, quotes: candidate.quotes,
                          issueID: candidate.issueID, status: status, assumptions: candidate.assumptions ?? [],
                          validation: candidate.validation, trigger: candidate.trigger, evidenceDetails: details,
                          proposalStatus: candidate.claimKind == .proposal ? "proposed" : nil)
        if status == "background" { backgroundCues.append(cue) } else { cues.append(cue) }
        if let issueID = candidate.issueID, let index = issues.firstIndex(where: { $0.id == issueID }) {
            issues[index].sourceIDs = candidate.sourceIDs
        }
        if let topic = topics.firstIndex(where: \.current) { topics[topic].cueID = cue.id }
        append(cue, to: "evidence.jsonl")
        onCue?(cue)
    }

    private func persist() {
        guard let sessionDir else { return }
        struct State: Encodable {
            let schemaVersion = 1
            var sessionID: UUID?
            var packetID: UUID?
            var contextRevision: Int
            var transcriptRevision: Int
            var issues: [LiveIssue]
            var topics: [LiveTopic]
            var cues: [LiveCue]
            var backgroundCues: [LiveCue]
        }
        do {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(State(sessionID: activeStateSessionID, packetID: packet?.id, contextRevision: contextRevision,
                                     transcriptRevision: transcriptRevision, issues: issues, topics: topics, cues: cues, backgroundCues: backgroundCues))
                .write(to: sessionDir.appendingPathComponent("advice-state.json"), options: .atomic)
        } catch { storageError = "Advice storage failed"; setStatus("Listening") }
    }

    private func append<T: Encodable>(_ value: T, to filename: String) {
        guard let sessionDir else { return }
        do {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(value); data.append(10)
            let url = sessionDir.appendingPathComponent(filename)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
            try file.seekToEnd(); try file.write(contentsOf: data); try file.synchronize()
        } catch { storageError = "Advice storage failed"; setStatus("Listening") }
    }

    private func metric(_ event: String, receipt: ModelReceipt? = nil) {
        struct Metric: Encodable { var at: Date; var event: String; var receipt: ModelReceipt? }
        append(Metric(at: Date(), event: event, receipt: receipt), to: "advice-metrics.jsonl")
    }

    private static func rank(_ priority: TopicPriority) -> Int {
        switch priority { case .attention: return 3; case .discussion: return 2; case .background: return 1 }
    }

    private func promoteTopic(at index: Int) {
        guard topics[index].slot >= 4 else { return }
        let candidates = topics.indices.filter { topics[$0].slot < 4 && !topics[$0].pinned && !topics[$0].current }
        guard let replaced = candidates.min(by: { Self.rank(topics[$0].priority) < Self.rank(topics[$1].priority) }) else { return }
        let slot = topics[replaced].slot
        topics[replaced].slot = topics[index].slot; topics[index].slot = slot
    }

    private func saveContextRevision() {
        guard let sessionDir else { return }
        do {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            if let packet, !savedPacketIDs.contains(packet.id) {
                let directory = sessionDir.appendingPathComponent("context-snapshots", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try encoder.encode(packet).write(to: directory.appendingPathComponent("\(packet.id).json"), options: .atomic)
                try encoder.encode(corpus.excerpts).write(to: directory.appendingPathComponent("\(packet.id)-excerpts.json"), options: .atomic)
                savedPacketIDs.insert(packet.id)
            }
            struct ContextRevision: Encodable { var at: Date; var revision: Int; var packetID: UUID? }
            append(ContextRevision(at: Date(), revision: contextRevision, packetID: packet?.id), to: "context.jsonl")
        } catch { storageError = "Context snapshot storage failed"; setStatus("Listening") }
    }

    private static func suffixUTF8(_ text: String, maxBytes: Int) -> String {
        var result = text
        while result.utf8.count > maxBytes { result.removeFirst(min(256, result.count)) }
        return result
    }
}
