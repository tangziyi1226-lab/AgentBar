import AppKit
import Foundation
import WebKit

@MainActor
final class WebBalanceExtractor: NSObject, WKNavigationDelegate {
    static let shared = WebBalanceExtractor()

    static let smartAutoExtractJS = #"""
    (() => {
      const href = (location.href || '').toLowerCase();
      const host = (location.hostname || '').toLowerCase();
      const hasPwd = !!document.querySelector('input[type="password"], input[name*="pass" i]');
      const isAuthHost = /(idms|sso|login|signin|oauth|auth\.|okta|pingidentity)/i.test(host + href);
      const bodyText = (document.body ? document.body.innerText : '') || '';
      if (hasPwd || (isAuthHost && bodyText.length < 2500)) {
        return JSON.stringify({ _agentbarSmart: true, needsLogin: true });
      }

      const lines = bodyText.split(/\n+/).map(s => s.trim()).filter(Boolean);
      if (lines.length <= 2 && /loading|spinner|authenticating|加载中/i.test(bodyText)) {
        return JSON.stringify({ _agentbarSmart: true, loading: true });
      }

      let primary = '';
      let secondary = '';
      let usedFraction = null;

      const ratioMatch = bodyText.match(/([\$¥€]\s*\d[\d,]*(?:\.\d+)?)\s*\/\s*([\$¥€]?\s*\d[\d,]*(?:\.\d+)?)/);
      if (ratioMatch) {
        primary = ratioMatch[1].replace(/\s+/g, '') + ' / ' + ratioMatch[2].replace(/\s+/g, '');
        const a = parseFloat(ratioMatch[1].replace(/[^0-9.]/g, ''));
        const b = parseFloat(ratioMatch[2].replace(/[^0-9.]/g, ''));
        if (b > 0 && a >= 0 && a <= b * 2) usedFraction = Math.min(1, a / b);
      }

      const kw = /(balance|remaining|available|budget|quota|credit|spend|spent|cost|usage|limit|tokens?|余额|剩余|可用|额度|已用|消费|账单)/i;
      const moneyRe = /([\$¥€]|USD\s*|CNY\s*)\s*\d[\d,]*(?:\.\d+)?/i;
      const tokRe = /\b\d+(?:\.\d+)?\s*[KMB]\s*(?:tokens?|tok)\b/i;
      const pctRe = /\b(\d{1,3}(?:\.\d+)?)\s*%/;

      for (let i = 0; i < lines.length; i++) {
        const windowText = [lines[i - 1] || '', lines[i], lines[i + 1] || ''].join(' · ');
        if (!kw.test(windowText)) continue;
        if (!primary) {
          const m = windowText.match(moneyRe);
          if (m) {
            primary = m[0].replace(/\s+/g, '');
            secondary = lines[i].length <= 36 ? lines[i] : (lines[i - 1] || '');
          }
        }
        if (usedFraction === null) {
          const pm = windowText.match(pctRe);
          if (pm) {
            const v = parseFloat(pm[1]);
            if (v >= 0 && v <= 100) usedFraction = v / 100.0;
          }
        }
        if (!secondary) {
          const tm = windowText.match(tokRe);
          if (tm) secondary = tm[0];
        }
      }

      if (!primary) {
        const anyMoney = bodyText.match(moneyRe);
        if (anyMoney) primary = anyMoney[0].replace(/\s+/g, '');
      }
      if (!primary) {
        const anyTok = bodyText.match(tokRe);
        if (anyTok) primary = anyTok[0];
      }
      if (usedFraction === null) {
        const bar = document.querySelector('[role="progressbar"][aria-valuenow]');
        if (bar) {
          const now = parseFloat(bar.getAttribute('aria-valuenow') || '');
          const max = parseFloat(bar.getAttribute('aria-valuemax') || '100');
          if (!isNaN(now) && max > 0) usedFraction = Math.min(1, Math.max(0, now / max));
        }
      }
      if (!secondary && document.title) {
        secondary = document.title.slice(0, 32);
      }
      return JSON.stringify({
        _agentbarSmart: true,
        needsLogin: false,
        primary,
        secondary,
        usedFraction
      });
    })()
    """#

    private var loginWindow: NSWindow?
    private var interactiveWebView: WKWebView?
    private var interactiveOnSync: ((String) -> Void)?
    private var interactiveCustomExpr: String = "auto"
    private var headlessWebView: WKWebView?
    private var pendingContinuation: CheckedContinuation<String, Error>?
    private var pendingExpression: String = ""
    private var targetHost: String?
    private var pollTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?

    private var loginWindowCloseObserver: NSObjectProtocol?

    private func tearDownHeadlessWebView() {
        if let wv = headlessWebView {
            wv.stopLoading()
            wv.navigationDelegate = nil
            wv.loadHTMLString("", baseURL: nil)
        }
        headlessWebView = nil
        pollTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    func openInteractiveLoginWindow(
        urlString: String,
        title: String,
        extractorExpression: String = "auto",
        onLiveExtract: ((String) -> Void)? = nil
    ) {
        guard let url = URL(string: urlString) else { return }
        if let oldWin = loginWindow {
            oldWin.close()
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 980, height: 680), configuration: config)
        webView.navigationDelegate = self
        self.interactiveWebView = webView
        self.interactiveOnSync = onLiveExtract
        self.interactiveCustomExpr = extractorExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        webView.load(URLRequest(url: url))

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.isReleasedWhenClosed = false
        win.title = "AgentBar 看板 · \(title)（登录或页面加载后自动同步额度到面板）"
        win.contentView = webView
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.loginWindow = win

        if let obs = loginWindowCloseObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        loginWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.interactiveWebView?.stopLoading()
                self.interactiveWebView?.navigationDelegate = nil
                self.interactiveWebView = nil
                self.interactiveOnSync = nil
                self.loginWindow?.contentView = nil
                self.loginWindow = nil
                if let obs = self.loginWindowCloseObserver {
                    NotificationCenter.default.removeObserver(obs)
                    self.loginWindowCloseObserver = nil
                }
            }
        }
    }

    private static func buildJSExpression(from jsOrSelector: String) -> String {
        let trimmed = jsOrSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "auto" {
            return smartAutoExtractJS
        }
        if trimmed.contains("document.") || trimmed.contains("window.") || trimmed.contains("(") {
            return trimmed
        }
        let escaped = trimmed.replacingOccurrences(of: "'", with: "\\'")
        return "document.querySelector('\(escaped)')?.innerText ?? ''"
    }

    func evaluateOnPage(url: URL, jsOrSelector: String) async throws -> String {
        if pendingContinuation != nil {
            throw NSError(domain: "WebBalanceExtractor", code: 9, userInfo: [NSLocalizedDescriptionKey: "正在加载另一个页面"])
        }
        let expr = Self.buildJSExpression(from: jsOrSelector)
        self.targetHost = url.host?.lowercased()

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        wv.navigationDelegate = self
        self.headlessWebView = wv
        self.pendingExpression = expr

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            self.pendingContinuation = cont
            self.watchdogTask?.cancel()
            self.watchdogTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard let self, !Task.isCancelled, let activeCont = self.pendingContinuation else { return }
                self.pollTask?.cancel()
                var fallback = ""
                if let activeWV = self.headlessWebView,
                   let res = try? await activeWV.evaluateJavaScript(expr) {
                    fallback = "\(res)"
                }
                guard self.pendingContinuation != nil else { return }
                self.pendingContinuation = nil
                self.tearDownHeadlessWebView()
                if !fallback.isEmpty {
                    activeCont.resume(returning: fallback)
                } else {
                    activeCont.resume(throwing: NSError(
                        domain: "WebBalanceExtractor",
                        code: -1001,
                        userInfo: [NSLocalizedDescriptionKey: "页面响应超时"]
                    ))
                }
            }
            wv.load(URLRequest(url: url, timeoutInterval: 18))
        }
    }

    func webView(
        _ webView: WKWebView,
        respondTo challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        (.performDefaultHandling, nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === interactiveWebView {
            let expr = Self.buildJSExpression(from: interactiveCustomExpr)
            let callback = interactiveOnSync
            Task { @MainActor [weak self, weak webView] in
                for delayMs in [900, 2200, 4000] {
                    try? await Task.sleep(for: .milliseconds(delayMs))
                    guard let self, let webView, webView === self.interactiveWebView else { return }
                    if let res = try? await webView.evaluateJavaScript(expr) {
                        let str = "\(res)"
                        if !str.contains("\"loading\":true") && !str.contains("\"needsLogin\":true") {
                            callback?(str)
                        }
                    }
                }
            }
            return
        }

        guard webView === headlessWebView else { return }
        let expr = pendingExpression
        let expectedHost = targetHost
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self, weak webView] in
            var lastString = ""
            for attempt in 0..<8 {
                try? await Task.sleep(for: .milliseconds(attempt == 0 ? 750 : 650))
                if Task.isCancelled { return }
                guard let self, let webView, self.pendingContinuation != nil else { return }

                let currentHost = webView.url?.host?.lowercased()
                if let res = try? await webView.evaluateJavaScript(expr) {
                    lastString = "\(res)"
                    if lastString.contains("\"needsLogin\":true") {
                        if attempt >= 2 { break }
                        continue
                    }
                    if lastString.contains("\"loading\":true") {
                        continue
                    }
                    if expectedHost == nil || currentHost == expectedHost || !lastString.isEmpty {
                        if lastString.contains("\"primary\":\"\"") && attempt < 4 {
                            continue
                        }
                        break
                    }
                }
            }
            guard let self, let cont = self.pendingContinuation else { return }
            self.pendingContinuation = nil
            self.tearDownHeadlessWebView()
            cont.resume(returning: lastString)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === headlessWebView else { return }
        pollTask?.cancel()
        let cont = pendingContinuation
        pendingContinuation = nil
        tearDownHeadlessWebView()
        cont?.resume(throwing: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === headlessWebView else { return }
        pollTask?.cancel()
        let cont = pendingContinuation
        pendingContinuation = nil
        tearDownHeadlessWebView()
        cont?.resume(throwing: error)
    }
}
