import AppComponents
public import ComposableArchitecture
import ReadingSettingFeature
import Resources
import SFSafeSymbols
public import SwiftUI

public struct SettingView: View {
    @Environment(\.isPresented) private var isPresented
    @Environment(\.tabBarPlacement) private var tabBarPlacement

    @Bindable private var store: StoreOf<SettingReducer>

    public init(store: StoreOf<SettingReducer>) {
        self.store = store
    }

    /// The title mode this screen is designed around, which differs by how it is presented.
    ///
    /// As a tab root the screen owns the whole tab, so its title stays prominent while the list
    /// scrolls: that is what `inlineLarge` buys, and it is the designed appearance. Inside a sheet
    /// the same mode reads wrong — the sheet already carries a title band of its own, and a title
    /// that never yields makes the sheet look like a second, competing navigation bar — so a sheet
    /// takes the ordinary large title that collapses on scroll.
    private var designedTitleDisplayMode: ToolbarTitleDisplayMode {
        isPresented ? .large : .inlineLarge
    }

    // MARK: SettingView
    public var body: some View {
        NavigationStack(path: $store.scope(\.path, action: \.path)) {
            List {
                ForEach(SettingReducer.RootScreen.sections, id: \.first) { screens in
                    Section {
                        ForEach(screens) { screen in
                            SettingRow(rowType: screen) {
                                store.send(.settingRowTapped($0))
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationTitle(.RLocalizable.setting)
            .toolbarTitleDisplayMode(designedTitleDisplayMode)
        } destination: { pathStore in
            destination(pathStore)
        }
        .scrollEdgeEffectStyle(softBottomEdge ? .soft : .automatic, for: .bottom)
        .contentMargins(.bottom, softBottomEdge ? Self.softBottomEdgeClearance : 0, for: .scrollContent)
    }

    /// Whether a bottom tab bar floats over the pages, so their scroll content fades into the soft bottom edge.
    private var softBottomEdge: Bool {
        !isPresented && tabBarPlacement == .bottomBar
    }

    /// Room under the end of every page's scroll content, pushed pages included (the margin reaches their scroll
    /// views through the environment): the soft edge fades the last points above the tab bar, and a footer that ends
    /// flush with the bar's top, like General's analytics footer, was left half under the fade.
    private static let softBottomEdgeClearance: CGFloat = 16

    // MARK: Destinations
    @ContentBuilder
    private func destination(_ pathStore: StoreOf<SettingPath>) -> some View {
        switch pathStore.case {
        case .account(let accountStore):
            AccountSettingView(store: accountStore)

        case .general(let generalStore):
            GeneralSettingView(
                store: generalStore,
                tagTranslatorLoadingState: store.tagTranslatorLoadingState
            )

        case .appearance(let appearanceStore):
            AppearanceSettingView(store: appearanceStore)

        case .login(let loginStore):
            LoginView(store: loginStore)

        case .ehSetting(let ehSettingStore):
            EhSettingView(store: ehSettingStore)

        case .appActivityLogs(let logsStore):
            AppActivityLogsView(store: logsStore)

        case .download:
            DownloadSettingView()

        case .reading(let readingStore):
            ReadingSettingView(store: readingStore)

        case .laboratory(let laboratoryStore):
            LaboratorySettingView(store: laboratoryStore)

        case .about:
            AboutView()

        case .appIcon(let appIconStore):
            AppIconView(store: appIconStore)

        case .blockedUsers(let blockedUsersStore):
            BlockedUsersView(store: blockedUsersStore)
        }
    }
}

// MARK: SettingRow
/// A root row is a `Button` whose label is the row's `Label`, so it carries the button role and
/// its visible title as both the VoiceOver label and the Voice Control name. The list supplies the
/// pressed highlight and the grouped Liquid Glass card; the row only draws its colored icon tile.
private struct SettingRow: View {
    @ScaledMetric private var tileSize: CGFloat = 30

    private let rowType: SettingReducer.RootScreen
    private let tapAction: (SettingReducer.RootScreen) -> Void

    init(rowType: SettingReducer.RootScreen, tapAction: @escaping (SettingReducer.RootScreen) -> Void) {
        self.rowType = rowType
        self.tapAction = tapAction
    }

    var body: some View {
        Button {
            tapAction(rowType)
        } label: {
            Label {
                Text(rowType.value)
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemSymbol: rowType.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: tileSize, height: tileSize)
                    .background(rowType.tint.gradient, in: .rect(cornerRadius: tileSize * 0.28))
            }
            .withArrow()
        }
    }
}

// MARK: Definition
extension SettingReducer.RootScreen {
    var value: LocalizedStringResource {
        switch self {
        case .account:
            return .settingStateRouteAccount
        case .general:
            return .settingStateRouteGeneral
        case .appearance:
            return .settingStateRouteAppearance
        case .download:
            return .settingStateRouteDownload
        case .reading:
            return .settingStateRouteReading
        case .laboratory:
            return .settingStateRouteLaboratory
        case .about:
            return .settingStateRouteAbout
        }
    }

    /// The settings groups of the root list, in display order.
    static let sections: [[SettingReducer.RootScreen]] = [
        [.account],
        [.general, .appearance, .reading],
        [.download, .laboratory],
        [.about]
    ]

    var tint: Color {
        switch self {
        case .account:
            return .blue
        case .general:
            return .gray
        case .appearance:
            return .indigo
        case .download:
            return .green
        case .reading:
            return .orange
        case .laboratory:
            return .purple
        case .about:
            return .teal
        }
    }

    var symbol: SFSymbol {
        switch self {
        case .account:
            return .personFill
        case .general:
            return .gearshape
        case .appearance:
            return .paintbrushPointedFill
        case .download:
            return .arrowDownCircleFill
        case .reading:
            return .bookFill
        case .laboratory:
            return .testtube2
        case .about:
            return .infoCircleFill
        }
    }
}

#Preview("Initial") {
    SettingView(
        store: .init(initialState: .init(), reducer: SettingReducer.init)
    )
}
