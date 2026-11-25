import SwiftUI
import VChatCore

/// Manual disclosures are keyed to the original blocks, so a just-arrived
/// result or the final turn wrapper doesn't discard a tap in mid-stream.
struct ToolTimeline<BlockContent: View>: View {
    var items: [ToolPresentation.Item]
    var display: ToolDisplay
    var options: RenderOptions
    var streaming: Bool
    @ViewBuilder var blockView: (RenderBlock) -> BlockContent
    private struct GroupKey: Hashable { var id: Int; var style: ToolPresentation.Group.Style }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rows: [Int: Bool] = [:]
    @State private var groups: [GroupKey: Bool] = [:]

    private var disclosureAnimation: Animation? {
        options.motion && !reduceMotion ? .linear(duration: 0.2) : nil
    }

    var body: some View {
        ForEach(items) { item in
            switch item {
            case .group(let group): groupView(group)
            default: itemView(item)
            }
        }
        .onChange(of: display) { _,_ in rows.removeAll(); groups.removeAll() }
    }

    @ViewBuilder private func itemView(_ item: ToolPresentation.Item) -> some View {
        switch item {
        case .block(let block): blockView(block.value)
        case .row(let row): rowView(row)
        case .group: EmptyView()
        }
    }

    private func groupView(_ group: ToolPresentation.Group) -> some View {
        let key = GroupKey(id: group.id,style: group.style)
        let expanded = groups[key] ?? (group.startsOpen || group.members.contains {
            if case .row(let row) = $0 { return row.choice(in: rows) == true }
            return false
        })
        let mediaRows = group.mediaRows
        let animation = groups[key] == nil ? nil : disclosureAnimation
        return VStack(alignment: .leading,spacing: 0) {
            ToolDisclosureHeader(title: group.title,detail: group.stats,status: nil,icon: group.icon,
                                 expanded: expanded,muted: group.style == .turn,animation: animation) {
                groups[key] = !expanded
            }
            if !mediaRows.isEmpty {
                ToolDisclosureBody(expanded: !expanded,animation: animation) {
                    mediaButton {
                        groups[key] = true
                        for id in mediaRows { rows[id] = true }
                    }.padding(.leading,34).padding(.bottom,6)
                }
            }
            ToolDisclosureBody(expanded: expanded,animation: animation) {
                VStack(alignment: .leading,spacing: 9) {
                    ForEach(group.members) { itemView($0) }
                }.padding(.leading,12).padding(.bottom,5)
            }
        }.frame(maxWidth: .infinity,alignment: .leading)
            .background(.secondary.opacity(group.style == .grouped ? 0.07 : 0),in: RoundedRectangle(cornerRadius: 12))
    }

    private func rowView(_ row: ToolPresentation.Row) -> some View {
        let expanded = row.choice(in: rows) ?? row.startsOpen(display.expansion)
        let animation = rows[row.id] == nil ? nil : disclosureAnimation
        let compact = display.mode == .compact || display.mode == .grouped
        let title = row.lineTitle(display.mode,streaming: streaming)
        let detail = row.status == .failed && !row.preview.isEmpty ? row.preview
            : !row.resource.isEmpty ? row.resource : !row.detail.isEmpty ? row.detail : row.preview
        return VStack(alignment: .leading,spacing: 0) {
            ToolDisclosureHeader(title: compact && row.hasResult ? title + " · 结果" : title,
                                 detail: detail,status: row.status == .summary ? nil : row.status,
                                 icon: row.kind.icon,expanded: expanded,animation: animation) {
                rows[row.id] = !expanded
                if let partner = row.partnerID { rows[partner] = !expanded }
            }
            if row.media {
                ToolDisclosureBody(expanded: !expanded,animation: animation) {
                    mediaButton { rows[row.id] = true }.padding(.leading,34).padding(.bottom,6)
                }
            }
            ToolDisclosureBody(expanded: expanded,animation: animation) {
                VStack(alignment: .leading,spacing: 8) {
                    if row.isRequest && row.partner != nil {
                        Text("请求 · " + row.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    ToolPayload(segment: row.segment, options: options, streaming: streaming,
                                receipt: row.block.receipt, results: row.block.results)
                    if let result = row.partner {
                        Divider()
                        Text("输出").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ToolPayload(segment: result, options: options, streaming: streaming, receipt: row.partnerReceipt)
                    }
                }.frame(maxWidth: .infinity,alignment: .leading).padding(.horizontal,12).padding(.bottom,9)
            }
        }.frame(maxWidth: .infinity,alignment: .leading)
            .background(.secondary.opacity(compact ? 0.065 : 0),in: RoundedRectangle(cornerRadius: 10))
    }

    private func mediaButton(_ reveal: @escaping () -> Void) -> some View {
        Button(action: reveal) { Label("查看图片 / 媒体",systemImage: "photo.on.rectangle").font(.caption).frame(minHeight: 36) }
            .buttonStyle(.plain).foregroundStyle(.tint)
    }
}

private struct ToolDisclosureHeader: View {
    var title: String
    var detail: String
    var status: ToolPresentation.Status?
    var icon: String
    var expanded: Bool
    var muted = false
    var animation: Animation?
    var toggle: () -> Void
    private var problem: Bool { status?.needsAttention == true }
    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(muted ? .caption2 : .caption).frame(width: 16)
                    .foregroundStyle(problem ? Color.red : .secondary)
                Text(title).font(muted ? .footnote : .callout.weight(.semibold))
                    .foregroundStyle(muted ? .secondary : .primary).lineLimit(1).layoutPriority(1)
                if !detail.isEmpty {
                    Text(detail).font(.caption).lineLimit(1).foregroundStyle(status == .failed ? Color.red : .secondary)
                }
                Spacer(minLength: 0)
                if let status {
                    Text(status.rawValue).font(.caption2.weight(.medium)).fixedSize()
                        .foregroundStyle(problem ? Color.red : .secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: muted ? 9 : 10,weight: muted ? .medium : .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(.secondary)
                    .animation(animation,value: expanded)
            }.padding(.horizontal,11).frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel([title,detail,status?.rawValue ?? ""].filter { !$0.isEmpty }.joined(separator: "，"))
            .accessibilityValue(expanded ? "已展开" : "已收起")
    }
}

/// Animate the height that the body contributes to its parent. An opacity
/// transition alone lets a self-sizing List row jump to its new height first.
private struct ToolDisclosureBody<Content: View>: View {
    let expanded: Bool
    let animation: Animation?
    @ViewBuilder let content: () -> Content
    @State private var fraction: CGFloat
    @State private var mounted: Bool
    @State private var revision = 0

    init(expanded: Bool,animation: Animation?,@ViewBuilder content: @escaping () -> Content) {
        self.expanded = expanded; self.animation = animation; self.content = content
        _fraction = State(initialValue: expanded ? 1 : 0)
        _mounted = State(initialValue: expanded)
    }

    var body: some View {
        ToolDisclosureLayout(fraction: fraction) {
            if mounted { content().allowsHitTesting(expanded).accessibilityHidden(!expanded) }
        }.clipped()
            .onChange(of: expanded) { _, open in
                revision += 1
                let current = revision
                guard let animation else {
                    fraction = open ? 1 : 0
                    mounted = open
                    return
                }
                if open { mounted = true }
                withAnimation(animation,completionCriteria: .removed) {
                    fraction = open ? 1 : 0
                } completion: {
                    if revision == current && !open { mounted = false }
                }
            }
    }
}

private struct ToolDisclosureLayout: Layout {
    var fraction: CGFloat

    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize,subviews: Subviews,cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width,height: nil))
        return CGSize(width: size.width,height: size.height * fraction)
    }

    func placeSubviews(in bounds: CGRect,proposal: ProposedViewSize,subviews: Subviews,cache: inout ()) {
        subviews.first?.place(at: bounds.origin,anchor: .topLeading,proposal: ProposedViewSize(width: bounds.width,height: nil))
    }
}
