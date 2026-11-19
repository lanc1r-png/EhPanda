import SFSafeSymbols
import SwiftUI

/// A row title with a colored rounded-square icon tile, like the rows of the system Settings app.
struct SettingIconLabel: View {
    @ScaledMetric private var tileSize: CGFloat = 28

    private let title: LocalizedStringResource
    private let symbol: SFSymbol
    private let tint: Color

    init(_ title: LocalizedStringResource, symbol: SFSymbol, tint: Color) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemSymbol: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: tileSize, height: tileSize)
                .background(tint.gradient, in: .rect(cornerRadius: tileSize * 0.28))
        }
    }
}
