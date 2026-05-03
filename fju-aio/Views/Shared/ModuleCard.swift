import SwiftUI

struct ModuleCard: View {
    let module: AppModule
    @Environment(\.openURL) private var openURL
    @AppStorage("openLinksInApp") private var openLinksInApp = true
    @State private var showBrowser = false
    @State private var browserURL: URL? = nil
    @State private var showDormBrowser = false

    private static let dormHost = "dorm.fju.edu.tw"

    var body: some View {
        Group {
            switch module.type {
            case .inApp(let destination):
                NavigationLink(value: destination) {
                    cardContent
                }
            case .webLink(let url):
                Button {
                    if url.host == Self.dormHost {
                        showDormBrowser = true
                    } else if openLinksInApp && (url.scheme == "https" || url.scheme == "http") {
                        browserURL = url
                        showBrowser = true
                    } else {
                        openURL(url)
                    }
                } label: {
                    cardContent
                }
                .sheet(isPresented: $showDormBrowser) {
                    DormBrowserView()
                        .ignoresSafeArea()
                }
                .sheet(isPresented: $showBrowser) {
                    if let browserURL {
                        InAppBrowserView(url: browserURL)
                            .ignoresSafeArea()
                    }
                }
            }
        }
    }

    private var cardContent: some View {
        HStack(spacing: 14) {
            Image(systemName: module.icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(module.color)
                .frame(width: 42, height: 42)
                .background(module.color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 2) {
                Text(module.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if case .webLink = module.type {
                    Text("外部連結")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
    }
}
