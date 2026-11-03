import SwiftUI

struct TopicCloudView: View {
    let topics: [LiveTopic]
    @Binding var selectedID: UUID?
    private var visible: [LiveTopic] { topics.filter { $0.slot < 4 }.sorted { $0.slot < $1.slot } }
    private var hidden: [LiveTopic] { topics.filter { $0.slot >= 4 }.sorted { $0.slot < $1.slot } }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("IN FOCUS").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                if !hidden.isEmpty {
                    Menu("+\(hidden.count) more") {
                        ForEach(hidden) { topic in Button(topic.title) { selectedID = topic.id } }
                    }.font(.caption).menuStyle(.borderlessButton).fixedSize()
                }
            }
            if visible.isEmpty { Text("Topics will appear as the discussion develops.").font(.caption).foregroundStyle(.secondary) }
            else {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(visible) { topic in
                        Button { selectedID = selectedID == topic.id ? nil : topic.id } label: {
                            HStack(spacing: 6) {
                                if topic.pinned { Image(systemName: "pin.fill").font(.caption2) }
                                if topic.current { Circle().fill(Color.teal).frame(width: 6, height: 6) }
                                Text(topic.title).font(.system(size: size(topic.priority), weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                            }.padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                                .background(selectedID == topic.id ? Color.teal.opacity(0.18) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).help(topic.status)
                    }
                }
            }
        }
    }
    private func size(_ priority: TopicPriority) -> CGFloat {
        switch priority { case .attention: return 24; case .discussion: return 20; case .background: return 16 }
    }
}
