import SwiftUI
import WebKit
import UIKit

// MARK: - 嗅探到的直链

struct SniffedLink: Identifiable, Hashable {
    let id = UUID()
    var url: URL
    var foundAt: Date

    var host: String { url.host ?? "" }

    var fileName: String {
        let last = url.lastPathComponent
        if !last.isEmpty {
            return last.removingPercentEncoding ?? last
        }
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            for key in ["filename", "fn", "name"] {
                if let v = comps.queryItems?.first(where: { $0.name == key })?.value, !v.isEmpty {
                    return v.removingPercentEncoding ?? v
                }
            }
        }
        return url.host ?? url.absoluteString
    }
}

/// 收集浏览器里冒出来的链接，过滤掉明显不是下载的资源
final class LinkStore: ObservableObject {

    @Published var links: [SniffedLink] = []

    // 这些后缀是网页自身的资源，不可能是下载文件
    private static let blockExt: Set<String> = [
        "js", "css", "png", "jpg", "jpeg", "gif", "svg", "ico", "webp", "bmp",
        "woff", "woff2", "ttf", "eot", "otf", "html", "htm", "php", "asp", "aspx",
        "json", "xml", "txt", "map", "manifest", "webmanifest"
    ]

    func add(_ url: URL) {
        let s = url.absoluteString
        guard s.hasPrefix("http://") || s.hasPrefix("https://") else { return }

        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty && Self.blockExt.contains(ext) { return }

        DispatchQueue.main.async {
            guard !self.links.contains(where: { $0.url.absoluteString == s }) else { return }
            self.links.insert(SniffedLink(url: url, foundAt: Date()), at: 0)
            if self.links.count > 60 {
                self.links.removeSubrange(60..<self.links.count)
            }
        }
    }

    func clear() {
        DispatchQueue.main.async { self.links.removeAll() }
    }
}

// MARK: - 浏览器状态

final class BrowserViewModel: ObservableObject {
    @Published var address: String = ""
    @Published var pageTitle: String = ""
    @Published var isLoading: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false

    var webView: WKWebView?

    func go(to text: String) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return }
        if !t.hasPrefix("http://") && !t.hasPrefix("https://") { t = "https://" + t }
        guard let u = URL(string: t) else { return }
        address = t
        webView?.load(URLRequest(url: u))
    }

    func goBack()    { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload()    { webView?.reload() }
    func stop()      { webView?.stopLoading() }
}

// MARK: - WKWebView 包装

struct MTWebView: UIViewRepresentable {

    @ObservedObject var vm: BrowserViewModel
    var store: LinkStore
    let initialURL: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(vm: vm, store: store)
    }

    func makeUIView(context: Context) -> WKWebView {
        let js = """
        (function(){
          var send=function(u){try{window.webkit.messageHandlers.sniff.postMessage(String(u));}catch(e){}};
          document.addEventListener('click',function(e){
            var t=e.target; var a=(t&&t.closest)?t.closest('a'):null;
            if(a&&a.href){send(a.href);}
          },true);
          var _o=window.open;
          window.open=function(u){send(u);return _o.apply(window,arguments);};
        })();
        """

        let ctrl = WKUserContentController()
        ctrl.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        ctrl.add(context.coordinator, name: "sniff")

        let cfg = WKWebViewConfiguration()
        cfg.userContentController = ctrl
        cfg.allowsInlineMediaPlayback = true

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true

        vm.webView = wv
        wv.load(URLRequest(url: initialURL))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) { }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

        let vm: BrowserViewModel
        let store: LinkStore

        init(vm: BrowserViewModel, store: LinkStore) {
            self.vm = vm
            self.store = store
            super.init()
        }

        // JS 抓到的链接（点击 a 标签、window.open）
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "sniff",
                  let s = message.body as? String,
                  let u = URL(string: s) else { return }
            store.add(u)
        }

        // 页面发起的每次跳转
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let u = navigationAction.request.url { store.add(u) }
            decisionHandler(.allow)
        }

        // 服务器返回的内容浏览器显示不了 —— 说明这是个下载，拦下来取直链
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if !navigationResponse.canShowMIMEType, let u = navigationResponse.response.url {
                store.add(u)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async { self.vm.isLoading = true }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.vm.isLoading = false
                self.vm.pageTitle = webView.title ?? ""
                self.vm.canGoBack = webView.canGoBack
                self.vm.canGoForward = webView.canGoForward
                if let u = webView.url { self.vm.address = u.absoluteString }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.vm.isLoading = false }
        }
    }
}

// MARK: - 浏览器页面

struct BrowserView: View {

    @StateObject private var vm = BrowserViewModel()
    @StateObject private var store = LinkStore()
    @State private var input: String = "https://www.123pan.com"
    @State private var showLinks = false

    private let homeURL = URL(string: "https://www.123pan.com")!

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button(action: { vm.goBack() }) {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!vm.canGoBack)

                    Button(action: { vm.goForward() }) {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!vm.canGoForward)

                    TextField("输入网址", text: $input, onCommit: { vm.go(to: input) })
                        .textFieldStyle(.roundedBorder)
                        .font(.footnote)
                        .autocapitalization(.none)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)

                    Button("前往") { vm.go(to: input) }
                        .font(.footnote)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                if vm.isLoading {
                    ProgressView()
                        .frame(height: 2)
                        .scaleEffect(x: 1, y: 0.6, anchor: .center)
                }

                MTWebView(vm: vm, store: store, initialURL: homeURL)
                    .ignoresSafeArea(.container, edges: .bottom)

                Divider()

                HStack(spacing: 10) {
                    Image(systemName: "link.badge.plus")
                        .foregroundColor(.secondary)
                    Text("抓到 \(store.links.count) 条直链")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("清空") { store.clear() }
                        .font(.caption)
                    Button("查看") { showLinks = true }
                        .font(.caption)
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .navigationTitle(vm.pageTitle.isEmpty ? "浏览器" : vm.pageTitle)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showLinks) {
                LinkListView(store: store)
            }
        }
    }
}

// MARK: - 直链列表

struct LinkListView: View {

    @ObservedObject var store: LinkStore
    @EnvironmentObject var dm: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var copiedName = ""

    var body: some View {
        NavigationStack {
            Group {
                if store.links.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "link")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("还没有抓到直链")
                            .foregroundColor(.secondary)
                        Text("在浏览器里点一下下载按钮，\n或者直接点文件链接，直链就会出现在列表里。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(store.links) { link in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(link.fileName)
                                    .font(.footnote)
                                    .lineLimit(3)
                                Text(link.host)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)

                                HStack(spacing: 12) {
                                    Button {
                                        UIPasteboard.general.string = link.url.absoluteString
                                        copiedName = link.fileName
                                    } label: {
                                        Label("复制直链", systemImage: "doc.on.doc")
                                    }
                                    .buttonStyle(.bordered)

                                    Button {
                                        dm.start(urlString: link.url.absoluteString, threads: 8)
                                        dismiss()
                                    } label: {
                                        Label("下载", systemImage: "arrow.down.circle")
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                                .font(.caption)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
            .navigationTitle("直链")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !copiedName.isEmpty {
                    Text("已复制：\(copiedName)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 6)
                }
            }
        }
    }
}
