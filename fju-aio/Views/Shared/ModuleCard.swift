import SwiftUI

struct ModuleCard: View {
    let module: AppModule
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            switch module.type {
            case .inApp(let destination):
                NavigationLink(value: destination) {
                    cardContent
                }
            case .webLink(let url):
                Button {
                    openURL(url)
                } label: {
                    cardContent
                }
            }
        }
    }

    private var cardContent: some View {
        VStack(spacing: 12) {
            Image(systemName: module.icon)
                .font(.system(size: 28))
                .foregroundStyle(module.color)
            Text(module.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
