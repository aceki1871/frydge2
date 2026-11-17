import SwiftUI

struct MainTabView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .detail
    @State private var browsingNavigation = BrowsingNavigationState()
    /// Pages the user has visited this run. They stay mounted (see `pages`).
    @State private var mountedTabs: Set<Tab> = []
    @Namespace private var tabBarNamespace
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    // Marketplace is gated until launch; see MarketplaceAvailability.
    @ObservedObject private var marketplace = MarketplaceAvailability.shared

    enum Tab: Hashable, CaseIterable {
        case recipes
        case shoppingList
        case frydge
        case marketplace

        var systemImage: String {
            switch self {
            case .frydge: return "refrigerator.fill"
            case .recipes: return "book.fill"
            case .shoppingList: return "cart.fill"
            case .marketplace: return "storefront.fill"
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .frydge: return "Fridge"
            case .recipes: return "Recipes"
            case .shoppingList: return "Shopping List"
            case .marketplace: return "Marketplace"
            }
        }
    }

    var body: some View {
        if horizontalSizeClass == .regular {
            sidebarLayout
        } else {
            mainContent
        }
    }

    private var sidebarLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredCompactColumn) {
            List(selection: Binding<Tab?>(
                get: { appState.selectedTab },
                set: { tab in
                    guard let tab else { return }
                    appState.selectedTab = tab
                    preferredCompactColumn = .detail
                }
            )) {
                sidebarDestination(.frydge, shortcut: "1")
                sidebarDestination(.recipes, shortcut: "2")
                sidebarDestination(.shoppingList, shortcut: "3")
                if marketplace.isEnabled {
                    sidebarDestination(.marketplace, shortcut: "4")
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Frydge")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            mainContent
        }
        .navigationSplitViewStyle(.balanced)
    }

    private func sidebarDestination(_ tab: Tab, shortcut: KeyEquivalent) -> some View {
        Button {
            appState.selectedTab = tab
            preferredCompactColumn = .detail
        } label: {
            Label(tab.title, systemImage: tab.systemImage)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut, modifiers: .command)
        .tag(tab)
    }

    // MARK: - Pages

    /// The tab actually on screen. Deep links or a stale selection can still
    /// point at the marketplace while the gate is closed; show the fridge.
    private var visibleTab: Tab {
        if appState.selectedTab == .marketplace && !marketplace.isEnabled {
            return .frydge
        }
        return appState.selectedTab
    }

    private var mainContent: some View {
        ZStack(alignment: .bottom) {
            pages

            if horizontalSizeClass != .regular {
                floatingTabBar
            }
        }
        .environment(browsingNavigation)
        .onChange(of: appState.selectedTab, initial: true) { _, tab in
            mountedTabs.insert(tab)
            browsingNavigation.isHidden = false
        }
        // If the gate closes while the marketplace tab is selected, hop back
        // to the fridge so the user isn't left on a tab that no longer exists.
        .onChange(of: marketplace.isEnabled, initial: true) { _, enabled in
            if !enabled && appState.selectedTab == .marketplace {
                appState.selectedTab = .frydge
            }
        }
        .sheet(isPresented: $appState.showProductDetailsFromWidget) {
            ProductDetailsView(
                isShowing: $appState.showProductDetailsFromWidget,
                productDetails: OFFProduct(
                    code: nil,
                    productName: "",
                    ingredientsText: "",
                    quantity: "",
                    imageUrl: nil,
                    nutriments: nil
                ),
                context: .shopping,
                autoStartScanner: appState.productDetailsFromWidgetAutoStartScanner
            )
        }
    }

    /// Every page visited this run stays mounted; switching tabs only changes
    /// which one is visible and hit-testable. Rebuilding a page on each switch
    /// re-ran its onAppear work (file loads, CloudKit pulls, recipe fetches),
    /// recreated its view models and threw away scroll position and
    /// navigation state. Pages are mounted lazily so launch cost is unchanged.
    private var pages: some View {
        let visible = visibleTab
        let mounted = Tab.allCases.filter { $0 == visible || mountedTabs.contains($0) }
        return ZStack {
            ForEach(mounted, id: \.self) { tab in
                page(for: tab)
                    .opacity(tab == visible ? 1 : 0)
                    .allowsHitTesting(tab == visible)
                    .accessibilityHidden(tab != visible)
                    .zIndex(tab == visible ? 1 : 0)
            }
        }
    }

    @ViewBuilder
    private func page(for tab: Tab) -> some View {
        switch tab {
        case .recipes:
            RecipeListView()
        case .shoppingList:
            ShoppingListView()
        case .frydge:
            FrydgeView()
        case .marketplace:
            LocalMarketplaceView()
        }
    }

    // MARK: - Floating tab bar

    /// Liquid Glass bar. Expanded it is a capsule holding the tab icons and a
    /// collapse chevron; collapsed (by that chevron or by scrolling down) it
    /// morphs into a single glass button in the bottom-right corner showing
    /// the current tab, and tapping that brings the bar back.
    private var floatingTabBar: some View {
        let collapsed = browsingNavigation.isHidden
        return GlassEffectContainer(spacing: 24) {
            HStack {
                Spacer(minLength: 0)
                if collapsed {
                    cornerToggle
                } else {
                    expandedBar
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var expandedBar: some View {
        HStack(spacing: 4) {
            tabBarItem(.frydge)
            tabBarItem(.recipes)
            tabBarItem(.shoppingList)
            if marketplace.isEnabled {
                tabBarItem(.marketplace)
            }

            Button {
                setBarCollapsed(true)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 50)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide tab bar")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 60)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectID("tabBar", in: tabBarNamespace)
    }

    private var cornerToggle: some View {
        Button {
            setBarCollapsed(false)
        } label: {
            Image(systemName: visibleTab.systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 54, height: 54)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID("tabBar", in: tabBarNamespace)
        .accessibilityLabel("Show tab bar")
    }

    private func setBarCollapsed(_ collapsed: Bool) {
        guard browsingNavigation.isHidden != collapsed else { return }
        withAnimation(reduceMotion ? nil : .bouncy(duration: 0.4)) {
            browsingNavigation.isHidden = collapsed
        }
    }

    private func tabBarItem(_ tab: Tab) -> some View {
        let isSelected = appState.selectedTab == tab
        return Button {
            if isSelected {
                appState.tabResetCounters[tab, default: 0] += 1
            } else {
                // Replace navigation stacks without animating their teardown.
                // The selected tab icon supplies its own animation.
                appState.selectedTab = tab
            }
        } label: {
            Image(systemName: tab.systemImage)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(width: 50, height: 50)
                .background {
                    // Bubble/Pill effect for selected tab
                    Circle()
                        .fill(colorScheme == .dark
                              ? Color.white.opacity(0.2)
                              : Color.black.opacity(0.08))
                        .scaleEffect(isSelected ? 1.0 : 0.8)
                        .opacity(isSelected ? 1 : 0)
                }
                .scaleEffect(isSelected ? 1.05 : 1.0)
                .animation(.spring(response: 0.35, dampingFraction: 0.6), value: appState.selectedTab)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Shared only by the main browsing screens; sheets can use the same views
/// without requiring a navigation controller in their environment.
@MainActor
@Observable
final class BrowsingNavigationState: Equatable {
    var isHidden = false

    nonisolated static func == (lhs: BrowsingNavigationState, rhs: BrowsingNavigationState) -> Bool {
        lhs === rhs
    }
}

private struct BrowsingScrollModifier: ViewModifier {
    @Environment(BrowsingNavigationState.self) private var navigation: BrowsingNavigationState?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var gestureStartOffset: CGFloat?

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { oldPhase, newPhase, context in
                let offset = context.geometry.contentOffset.y + context.geometry.contentInsets.top
                if newPhase == .interacting {
                    gestureStartOffset = offset
                } else if oldPhase == .interacting {
                    defer { gestureStartOffset = nil }
                    guard newPhase != .animating, let start = gestureStartOffset else { return }
                    // Decide once per gesture, so collapsing the header cannot
                    // feed geometry changes back into the scroll direction.
                    let distance = offset - start
                    if voiceOverEnabled || offset <= 8 || distance < -16 {
                        setHidden(false)
                    } else if distance > 24 {
                        setHidden(true)
                    }
                } else if newPhase == .idle, offset <= 8 {
                    setHidden(false)
                }
            }
            .onChange(of: voiceOverEnabled) { _, enabled in
                if enabled { setHidden(false) }
            }
            .onAppear { setHidden(false) }
    }

    private func setHidden(_ hidden: Bool) {
        guard let navigation, navigation.isHidden != hidden else { return }
        withAnimation(reduceMotion ? nil : .bouncy(duration: 0.4)) {
            navigation.isHidden = hidden
        }
    }
}

private struct BrowsingHeaderModifier: ViewModifier {
    @Environment(BrowsingNavigationState.self) private var navigation: BrowsingNavigationState?

    func body(content: Content) -> some View {
        let hidden = navigation?.isHidden == true
        content
            .frame(height: hidden ? 0 : nil, alignment: .top)
            .opacity(hidden ? 0 : 1)
            .clipped()
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
    }
}

extension View {
    func browsingScrollNavigation() -> some View {
        modifier(BrowsingScrollModifier())
    }

    func browsingHeader() -> some View {
        modifier(BrowsingHeaderModifier())
    }
}
