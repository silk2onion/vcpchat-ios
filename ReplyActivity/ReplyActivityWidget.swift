import ActivityKit
import SwiftUI
import WidgetKit

@main struct ReplyActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ReplyActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: context.state.symbol).font(.title2).foregroundStyle(.mint)
                VStack(alignment: .leading) {
                    Text("VChat").font(.caption).foregroundStyle(.secondary)
                    Text(context.state.label).font(.headline)
                }
                Spacer()
                if context.state.phase == .waiting { Text(context.attributes.started, style: .timer).monospacedDigit().multilineTextAlignment(.trailing) }
            }.padding().widgetURL(context.attributes.url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Label("VChat", systemImage: context.state.symbol).foregroundStyle(.mint) }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.phase == .waiting { Text(context.attributes.started, style: .timer).monospacedDigit().multilineTextAlignment(.trailing) }
                }
                DynamicIslandExpandedRegion(.bottom) { Text(context.state.label).frame(maxWidth: .infinity, alignment: .leading) }
            } compactLeading: {
                Image(systemName: context.state.symbol).foregroundStyle(.mint).accessibilityLabel(context.state.label)
            } compactTrailing: {
                Text("AI").font(.caption2.weight(.medium)).accessibilityLabel(context.state.label)
            } minimal: {
                Image(systemName: context.state.symbol).foregroundStyle(.mint).accessibilityLabel(context.state.label)
            }.widgetURL(context.attributes.url)
        }
    }
}
