import SwiftUI

struct SocialBrandIcon: View {
    let platform: SocialPlatform
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(Color(hex: platform.color).opacity(platform == .other ? 0.16 : 1))
                .frame(width: size, height: size)

            if let assetName = platform.assetName {
                Image(assetName)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .padding(size * 0.18)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "link")
                    .font(.system(size: size * 0.46, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(platform.label)
    }
}
