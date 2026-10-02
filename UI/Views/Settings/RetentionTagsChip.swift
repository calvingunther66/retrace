import SwiftUI
import Shared

struct RetentionTagsChip<PopoverContent: View>: View {
    let selectedTagIds: Set<Int64>
    let availableTags: [Tag]
    @Binding var isPopoverShown: Bool
    @ViewBuilder var popoverContent: () -> PopoverContent

    @State private var isHovered = false

    private var selectedTags: [Tag] {
        availableTags.filter { selectedTagIds.contains($0.id.value) }
    }

    private var isActive: Bool {
        !selectedTagIds.isEmpty
    }

    var body: some View {
        Button(action: {
            isPopoverShown.toggle()
        }) {
            HStack(spacing: 6) {
                RetraceSymbol("tag.fill", size: 12)

                if selectedTags.count == 1 {
                    Text(selectedTags[0].name)
                        .font(.retraceCaption)
                        .lineLimit(1)
                } else if selectedTags.count > 1 {
                    Text("\(selectedTags.count) tags")
                        .font(.retraceCaption)
                } else {
                    Text("None")
                        .font(.retraceCaption)
                }

                RetraceSymbol("chevron.down", size: 10, weight: .semibold)
                    .rotationEffect(.degrees(isPopoverShown ? 180 : 0))
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selectedTagIds)
            .foregroundColor(isActive ? .retraceInk : .retraceInk2)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                    .fill(isActive ? Color.retraceAccentWash : (isHovered ? Color.retraceSurfaceHover : Color.retraceSurfaceSunken))
                    .overlay(
                        RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                            .stroke(isActive ? Color.retraceAccent : Color.retraceBorderStrong, lineWidth: 1)
                    )
            )
            .retraceFocusRing(cornerRadius: .radiusSm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .popover(isPresented: $isPopoverShown, arrowEdge: .bottom) {
            popoverContent()
        }
    }
}
