import SwiftUI
import SwiftData
import WebKit
import UIKit

// MARK: - Downloads

@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()
    @Published var toast: String?

    func show(_ text: String) {
        toast = text
        Task { try? await Task.sleep(for: .seconds(3)); if toast == text { toast = nil } }
    }

    /// Downloads a plain http(s) file into /Downloads. Cookies/referer are forwarded so
    /// ordinary direct-file links that need a logged-in session still work.
    func download(_ url: URL, referer: URL?, cookies: [HTTPCookie]) async {
        guard url.scheme?.hasPrefix("http") == true else { return }
        var req = URLRequest(url: url)
        if let referer { req.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        for (k, v) in HTTPCookie.requestHeaderFields(with: cookies) { req.setValue(v, forHTTPHeaderField: k) }

        let bg = UIApplication.shared.beginBackgroundTask()      // short grace period if app is backgrounded
        defer { UIApplication.shared.endBackgroundTask(bg) }
        do {
            let (tmp, resp) = try await URLSession.shared.download(for: req)
            if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 400 { throw URLError(.badServerResponse) }
            let name = FileService.shared.sanitized(resp.suggestedFilename ?? url.lastPathComponent)
            let dest = try FileService.shared.moveToDownloads(tmp, name: name)

            let ctx = ModelContext(Persistence.container)
            ctx.insert(DownloadRecord(filename: dest.lastPathComponent, source: url.absoluteString))
            try? ctx.save()
            show("Media downloaded to Files > \(FileService.appName)")
        } catch {
            show("Download failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Browser model

@MainActor
final class BrowserModel: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    @Published var address = ""
    @Published var progress = 0.0
    private var observers: [NSKeyValueObservation] = []

    /// Injected into every frame. Media events don't bubble, so we listen in the capture phase.
    /// `ended` fires only when playback reaches 100%.
    static let hook = """
    (function () {
      if (window.__offlineHook) return; window.__offlineHook = true;
      const post = o => window.webkit.messageHandlers.media.postMessage(o);
      document.addEventListener('ended', function (e) {
        const m = e.target;
        if (!(m instanceof HTMLMediaElement)) return;
        post({kind: 'ended', src: m.currentSrc || m.src || '', page: location.href});
      }, true);
      let timer = null;
      document.addEventListener('touchstart', function (e) {
        const img = e.target.closest && e.target.closest('img');
        if (!img) return;
        timer = setTimeout(() => post({kind: 'image', src: img.currentSrc || img.src, page: location.href}), 700);
      }, {passive: true, capture: true});
      ['touchend', 'touchmove', 'touchcancel'].forEach(t =>
        document.addEventListener(t, () => clearTimeout(timer), {passive: true, capture: true}));
    })();
    """

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.allowsPictureInPictureMediaPlayback = true
        let ucc = WKUserContentController()
        cfg.userContentController = ucc
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        ucc.add(self, name: "media")
        ucc.addUserScript(WKUserScript(source: Self.hook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        observers = [
            webView.observe(\.url) { [weak self] w, _ in
                let raw = w.url?.absoluteString ?? ""
                let s = raw == "about:blank" ? "" : raw
                Task { @MainActor in self?.address = s }
            },
            webView.observe(\.estimatedProgress) { [weak self] w, _ in
                let p = w.estimatedProgress
                Task { @MainActor in self?.progress = p }
            }
        ]
        showHome()
    }

    func showHome() { webView.loadHTMLString(Self.startPage, baseURL: nil) }

    static let startPage = """
    <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
    body{margin:0;padding:28px 16px;background:#111;color:#eee;font-family:-apple-system,sans-serif}
    .grid{display:grid;grid-template-columns:repeat(4,1fr);gap:22px 8px;text-align:center}
    a{color:#ddd;text-decoration:none;font-size:12px}
    .i{width:56px;height:56px;border-radius:28px;margin:0 auto 6px;display:flex;align-items:center;
       justify-content:center;font-size:24px;font-weight:700;color:#fff}
    </style></head><body><div class="grid">
    <a href="https://m.youtube.com"><div class="i" style="background:#e62117">▶</div>YouTube</a>
    <a href="https://music.youtube.com"><div class="i" style="background:#ff0000">♪</div>YT Music</a>
    <a href="https://m.facebook.com"><div class="i" style="background:#1877f2">f</div>Facebook</a>
    <a href="https://www.instagram.com"><div class="i" style="background:#c13584">◎</div>Instagram</a>
    <a href="https://x.com"><div class="i" style="background:#000;border:1px solid #444">X</div>X</a>
    <a href="https://www.tiktok.com"><div class="i" style="background:#000;border:1px solid #444">♫</div>TikTok</a>
    <a href="https://www.google.com"><div class="i" style="background:#4285f4">G</div>Google</a>
    </div></body></html>
    """

    func go(_ input: String) {
        let t = input.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var url: URL?
        if t.contains("://") { url = URL(string: t) }
        else if t.contains("."), !t.contains(" ") { url = URL(string: "https://" + t) }
        if url == nil {
            let q = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t
            url = URL(string: "https://www.google.com/search?q=" + q)
        }
        if let url { webView.load(URLRequest(url: url)) }
    }

    // JS -> Swift
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? [String: Any],
              let kind = body["kind"] as? String,
              let src = body["src"] as? String else { return }
        let page = body["page"] as? String
        Task { await handle(kind: kind, src: src, page: page) }
    }

    /// Auto-download is not offered on YouTube / Google video hosts.
    private static let skippedHosts = ["youtube.com", "youtu.be", "youtube-nocookie.com", "googlevideo.com", "ytimg.com"]

    private func isSkipped(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return Self.skippedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private func handle(kind: String, src: String, page: String?) async {
        if kind == "ended", !UserDefaults.standard.bool(forKey: "autoDownload") { return }
        let pageURL = page.flatMap { URL(string: $0) }
        guard !src.isEmpty, !src.hasPrefix("blob:"), !src.hasPrefix("data:"),
              let url = URL(string: src, relativeTo: webView.url)?.absoluteURL else {
            if kind == "image" { DownloadManager.shared.show("Can't save this image.") }
            return                                   // streams (blob:) are ignored silently
        }
        if isSkipped(url) || isSkipped(pageURL) { return }
        if kind == "ended", ["m3u8", "mpd"].contains(url.pathExtension.lowercased()) { return }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        await DownloadManager.shared.download(url, referer: pageURL, cookies: cookies)
    }

    // Links the web view can't render (zip, pdf attachments, ...) go to /Downloads.
    func webView(_ w: WKWebView, decidePolicyFor r: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if !r.canShowMIMEType, let url = r.response.url {
            Task { await handle(kind: "file", src: url.absoluteString, page: w.url?.absoluteString) }
            return .cancel
        }
        return .allow
    }
}

// MARK: - SwiftUI bridge + screen

struct WebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserView: View {
    @ObservedObject var browser: BrowserModel
    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search or enter web address", text: $input)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.webSearch)
                .focused($focused)
                .onSubmit { browser.go(input); focused = false }
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(8)
            if browser.progress < 1 { ProgressView(value: browser.progress) }
            WebViewRepresentable(webView: browser.webView)
            HStack(spacing: 40) {
                Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                Button { browser.webView.goForward() } label: { Image(systemName: "chevron.right") }
                Button { browser.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                Button { browser.showHome() } label: { Image(systemName: "house") }
            }
            .padding(.vertical, 10)
        }
        .onChange(of: browser.address) { _, new in if !focused { input = new } }
    }
}
