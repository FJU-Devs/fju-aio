import SwiftUI
import WebKit

struct BulletinDetailView: View {
    let notification: TronClassNotification
    @State private var selectedURL: URL?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text(notification.bulletinTitle ?? "公告")
                        .font(.title3.weight(.semibold))
                    HStack(spacing: 6) {
                        if let courseName = notification.courseName {
                            Text(courseName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("·")
                                .foregroundStyle(.tertiary)
                        }
                        Text(notification.date, style: .relative)
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()

                Divider()

                if let html = notification.bulletinContent, !html.isEmpty {
                    BulletinWebView(html: html, selectedURL: $selectedURL)
                } else {
                    ContentUnavailableView("無內容", systemImage: "doc.text")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    CloseButton()
                }
            }
            .sheet(isPresented: Binding(
                get: { selectedURL != nil },
                set: { if !$0 { selectedURL = nil } }
            )) {
                if let url = selectedURL {
                    InAppBrowserView(url: url)
                        .ignoresSafeArea()
                }
            }
        }
    }
}

// MARK: - Close Button

private struct CloseButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button("關閉") { dismiss() }
    }
}

// MARK: - WKWebView wrapper

private struct BulletinWebView: UIViewRepresentable {
    let html: String
    @Binding var selectedURL: URL?

    func makeCoordinator() -> Coordinator {
        Coordinator(selectedURL: $selectedURL)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.dataDetectorTypes = [.phoneNumber]
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.bounces = true
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let styledHTML = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>
          :root {
            color-scheme: light dark;
          }
          body {
            font-family: -apple-system, Helvetica Neue, sans-serif;
            font-size: 15px;
            line-height: 1.6;
            margin: 16px;
            padding: 0;
            color: #333;
            word-break: break-word;
          }
          @media (prefers-color-scheme: dark) {
            body { color: #e5e5ea; }
            a { color: #0a84ff; }
          }
          img { max-width: 100%; height: auto; }
          a { color: #007aff; }
        </style>
        </head>
        <body>\(html)</body>
        </html>
        """
        webView.loadHTMLString(styledHTML, baseURL: URL(string: "https://elearn2.fju.edu.tw"))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var selectedURL: URL?

        init(selectedURL: Binding<URL?>) {
            _selectedURL = selectedURL
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Intercept link taps and open them in the in-app browser
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                selectedURL = url
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
