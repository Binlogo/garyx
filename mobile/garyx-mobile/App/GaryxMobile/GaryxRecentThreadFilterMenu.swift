import SwiftUI

struct GaryxRecentThreadFilterMenu: View {
    let selection: GaryxRecentThreadFilter
    let isHidden: Bool
    let onSelect: (GaryxRecentThreadFilter) -> Void

    init(
        selection: GaryxRecentThreadFilter,
        isHidden: Bool = false,
        onSelect: @escaping (GaryxRecentThreadFilter) -> Void
    ) {
        self.selection = selection
        self.isHidden = isHidden
        self.onSelect = onSelect
    }

    var body: some View {
        Menu {
            Picker(
                "Recent filter",
                selection: Binding(
                    get: { selection },
                    set: onSelect
                )
            ) {
                ForEach(GaryxRecentThreadFilter.homeMenuOptions, id: \.self) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(GaryxFont.fixedSystem(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                // Resolve visibility before GlassEffectContainer captures
                // this node into its shared pass.
                .opacity(isHidden ? 0 : 1)
                .garyxAdaptiveGlass(
                    .regular,
                    isInteractive: true,
                    in: Circle(),
                    isEnabled: !isHidden
                )
                .contentShape(Circle())
        }
        .menuOrder(.fixed)
        .menuIndicator(.hidden)
        .buttonStyle(GaryxPressableRowStyle())
        .allowsHitTesting(!isHidden)
        .accessibilityLabel("Recent filter")
        .accessibilityValue(selection.displayName)
        .accessibilityHidden(isHidden)
    }
}
