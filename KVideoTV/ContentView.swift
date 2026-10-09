//
//  ContentView.swift
//  KVideoTV
//
//  A lightweight tvOS WebView wrapper for KVideo.
//  WebKit is available on tvOS; video playback is handed to the system player,
//  so the remote control can scrub / play / pause natively.
//

import SwiftUI
import WebKit

// MARK: - Configuration

/// Your deployed KVideo instance.
/// Change this single line if you move to another domain.
private let kvideoURL = "https://video.oott.cc.cd/"

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var model = KVideoWebModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            KVideoWebView(webView: model.webView)
                .ignoresSafeArea()

            if model.isLoading, model.errorMessage == nil {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(2)
            }

            if let message = model.errorMessage {
                ErrorOverlay(message: message) {
                    model.load()
                }
            }
        }
        .onAppear {
            model.load()
        }
    }
}

// MARK: - UIViewRepresentable wrapper

struct KVideoWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Nothing to update: the web view owns its own navigation state.
    }
}

// MARK: - Error overlay

private struct ErrorOverlay: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.yellow)

            Text("无法加载 KVideo")
                .font(.title2)
                .fontWeight(.semibold)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 820)

            Text(kvideoURL)
                .font(.footnote)
                .foregroundStyle(.tertiary)

            Button(action: retry) {
                Text("重新加载")
                    .font(.headline)
                    .padding(.horizontal, 20)
            }
            .padding(.top, 8)
        }
        .padding(80)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.black.opacity(0.82))
        )
        .frame(maxWidth: 1000)
    }
}

// MARK: - Web view model

@MainActor
final class KVideoWebModel: NSObject, ObservableObject {
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?

    let webView: WKWebView

    override init() {
        let configuration = WKWebViewConfiguration()

        // tvOS 15.4+ blocks autoplay by default. Clearing this set keeps
        // HTML5 <video autoplay> working inside the wrapper.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true

        // Cookies / localStorage persist across launches by default
        // (WKWebsiteDataStore.default), so a logged-in session survives restarts.
        webView = WKWebView(frame: .zero, configuration: configuration)

        super.init()

        webView.navigationDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false

        // The default UA identifies itself as AppleTV, which makes some sites
        // serve a TV-specific layout. Uncomment to pretend to be desktop Safari
        // if a page renders badly:
        //
        // webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        //     + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    }

    func load() {
        guard let url = URL(string: kvideoURL) else {
            isLoading = false
            errorMessage = "URL 配置有误，请检查 ContentView.swift 里的 kvideoURL。"
            return
        }

        errorMessage = nil
        isLoading = true
        webView.load(URLRequest(url: url))
    }

    func reload() {
        errorMessage = nil
        isLoading = true
        webView.reload()
    }

    private func handle(_ error: Error) {
        let nsError = error as NSError

        // -999 is "cancelled" (redirects, duplicate taps, ...) — not a real failure.
        if nsError.domain == NSURLErrorDomain,
           nsError.code == NSURLErrorCancelled {
            return
        }

        isLoading = false
        errorMessage = nsError.localizedDescription
    }
}

extension KVideoWebModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        errorMessage = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
    }

    func webView(_ webView: WKWebView,
                 didFail navigation: WKNavigation!,
                 withError error: Error) {
        handle(error)
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        handle(error)
    }
}
