import AppKit
import SwiftUI

/// Runs real AppKit layout with synthetic cards; never opens capture or a provider.
enum PrompterWorkflowTests {
    @MainActor static func run() async throws -> [String] {
        var follow = true
        let scroll = FeedScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 420))
        scroll.hasVerticalScroller = true
        scroll.documentView = FlippedFeedDocument()
        let coordinator = AnchoredPrompterFeed.Coordinator()
        coordinator.scroll = scroll
        coordinator.following = Binding(get: { follow }, set: { follow = $0 })
        let ids = (0..<8).map { _ in UUID() }
        func cards(_ count: Int, expanded: Bool = false) -> [PrompterFeedItem] {
            (0..<count).map { i in PrompterFeedItem(id: ids[i], view: AnyView(
                VStack(alignment: .leading) {
                    Text(i == 0 ? "REPORTED · Environment access" : "PROPOSAL · Validate the next step").font(.caption.bold())
                    Text("Confirm the retest owner and evidence before calling the issue resolved.").font(.system(size: 20))
                    if expanded && i == 1 { Text(String(repeating: "Source detail with line references. ", count: 10)) }
                }.padding(16).frame(height: expanded && i == 1 ? 280 : 150)
            )) }
        }
        func require(_ value: Bool, _ message: String) throws { if !value { throw ProjectFailure("Prompter: " + message) } }
        coordinator.items = cards(6); coordinator.layout()
        try require(scroll.contentView.bounds.minY > 300, "initial following did not move to newest cue")
        coordinator.userInput(down: false)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 335))
        let anchorID = ids[2]
        let before = scroll.contentView.bounds.minY - coordinator.hosts[anchorID]!.frame.minY
        coordinator.items = cards(8); coordinator.layout()
        try require(!follow && abs(scroll.contentView.bounds.minY - coordinator.hosts[anchorID]!.frame.minY - before) < 1, "append moved the reading anchor")
        coordinator.items = cards(8, expanded: true); coordinator.layout()
        try require(!follow && abs(scroll.contentView.bounds.minY - coordinator.hosts[anchorID]!.frame.minY - before) < 1, "evidence reflow moved the reading anchor")
        coordinator.userInput(down: true); coordinator.settle()
        try await Task.sleep(for: .milliseconds(250))
        try require(!follow && !coordinator.manualDown, "downward intent did not expire away from bottom")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, scroll.documentView!.bounds.height - scroll.contentView.bounds.height)))
        coordinator.settle()
        try await Task.sleep(for: .milliseconds(250))
        try require(!follow, "layout movement resumed following without a fresh gesture")
        coordinator.userInput(down: true); coordinator.settle()
        try await Task.sleep(for: .milliseconds(250))
        try require(follow, "deliberate bottom scroll did not resume following")
        coordinator.userInput(down: false); follow = true; coordinator.layout()
        try require(follow, "explicit Jump to latest did not resume")
        coordinator.cleanup()
        return ["native feed: append/reflow anchor, expired wheel intent, bottom resume and jump"]
    }
}
