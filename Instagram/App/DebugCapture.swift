#if DEBUG
import AppKit
import WebKit

/// `-IGCapture <folder> [-IGCapturePages '/,/reels/,/direct/inbox/']` (Debug): opens
/// instagram.com with the saved session in an off-screen web view, visits each page for a
/// while and records every API request the web app makes (friendly name, doc_id, variables)
/// and its response, one file per request. Only navigates; never clicks or posts.
@MainActor
enum DebugCapture {
    static func runIfAsked() {
        guard let dir = UserDefaults.standard.string(forKey: "IGCapture") else { return }
        guard let session = SessionStore.shared.load() else { print("capture: not signed in"); exit(1) }
        let pages = (UserDefaults.standard.string(forKey: "IGCapturePages") ?? "/,/reels/,/direct/inbox/")
            .split(separator: ",").map(String.init)
        let dwell = UserDefaults.standard.double(forKey: "IGCaptureSeconds").nonZero ?? 12
        let recorder = Recorder(dir: URL(fileURLWithPath: dir))
        Task { await recorder.run(cookies: session, pages: pages, dwell: dwell) }
        keep = recorder
    }

    private static var keep: Recorder?

    final class Recorder: NSObject, WKScriptMessageHandler {
        let dir: URL
        var window: NSWindow?
        var web: WKWebView?
        var count = 0

        init(dir: URL) {
            self.dir = dir
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        func run(cookies: [StoredCookie], pages: [String], dwell: Double) async {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let store = config.websiteDataStore.httpCookieStore
            for c in cookies {
                var props: [HTTPCookiePropertyKey: Any] = [.name: c.name, .value: c.value, .domain: c.domain, .path: c.path]
                if c.secure { props[.secure] = "TRUE" }
                if let e = c.expires { props[.expires] = e }
                if let cookie = HTTPCookie(properties: props) { await store.setCookie(cookie) }
            }
            config.userContentController.add(self, name: "cap")
            config.userContentController.addUserScript(WKUserScript(source: Self.hook, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
            web.customUserAgent = IGClient.userAgent
            let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 1280, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = web
            window.orderFrontRegardless()
            self.web = web
            self.window = window
            for page in pages {
                print("capture: \(page)")
                web.load(URLRequest(url: URL(string: IGClient.origin + page)!))
                try? await Task.sleep(for: .seconds(dwell))
            }
            print("capture: \(count) requests")
            exit(0)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) else { return }
            count += 1
            let name = (body["name"] as? String).map { $0.isEmpty ? "req" : $0 } ?? "req"
            try? data.write(to: dir.appending(path: String(format: "%03d-%@.json", count, name)))
        }

        /// Wraps fetch, XMLHttpRequest and WebSocket to report API traffic.
        static let hook = #"""
        (function(){
          const post = (o) => { try { window.webkit.messageHandlers.cap.postMessage(o); } catch(e) {} };
          const interesting = (u) => /\/(graphql|api\/v1|api\/graphql|ajax)\b/.test(u);
          const nameOf = (body) => { try { const p = new URLSearchParams(body); return p.get('fb_api_req_friendly_name') || ''; } catch(e) { return ''; } };
          const parse = (body) => { const o = {}; try { new URLSearchParams(body).forEach((v,k)=>{ o[k]=v; }); } catch(e) {} return o; };
          const of = window.fetch;
          window.fetch = async function(input, init) {
            const url = typeof input === 'string' ? input : input.url;
            const body = init && typeof init.body === 'string' ? init.body : '';
            const r = await of.apply(this, arguments);
            if (interesting(url)) { r.clone().text().then(t => post({kind:'fetch', url, headers: (init && init.headers) ? JSON.parse(JSON.stringify(init.headers)) : {}, name: nameOf(body) || url.split('?')[0].split('/').filter(Boolean).slice(-2).join('_'), form: parse(body), response: t.slice(0, 400000)})); }
            return r;
          };
          const oo = XMLHttpRequest.prototype.open, os = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.open = function(m, u) { this.__u = u; this.__m = m; this.__h = {}; return oo.apply(this, arguments); };
          const osh = XMLHttpRequest.prototype.setRequestHeader;
          XMLHttpRequest.prototype.setRequestHeader = function(k, v) { if (this.__h) this.__h[k] = /token|csrf|lsd|claim/i.test(k) ? '<' + String(v).length + '>' : v; return osh.apply(this, arguments); };
          XMLHttpRequest.prototype.send = function(body) {
            const u = String(this.__u || '');
            if (interesting(u)) {
              const b = typeof body === 'string' ? body : '';
              this.addEventListener('load', () => post({kind:'xhr', method:this.__m, url:u, headers:this.__h, cookies: document.cookie.split('; ').map(c => c.split('=')[0]), name: nameOf(b) || u.split('?')[0].split('/').filter(Boolean).slice(-2).join('_'), form: parse(b), response: String(this.responseText || '').slice(0, 400000)}));
            }
            return os.apply(this, arguments);
          };
          const OW = window.WebSocket;
          window.WebSocket = function(url, protocols) {
            post({kind:'websocket', name:'websocket', url:String(url), protocols: protocols ? String(protocols) : ''});
            const ws = protocols ? new OW(url, protocols) : new OW(url);
            // DGW frames, as hex (the first few in each direction), to compare with ours.
            const tag = String(url).split('?')[0].split('/').pop();
            const hex = (buf) => Array.from(new Uint8Array(buf).slice(0, 4096)).map(b => b.toString(16).padStart(2, '0')).join('');
            let sent = 0, recv = 0;
            const osend = ws.send.bind(ws);
            ws.send = function(d) {
              if (sent++ < 40) {
                if (d instanceof ArrayBuffer) post({kind:'ws-send', name:'ws-send-' + tag, hex: hex(d), length: d.byteLength});
                else if (ArrayBuffer.isView(d)) post({kind:'ws-send', name:'ws-send-' + tag, hex: hex(d.buffer.slice(d.byteOffset, d.byteOffset + d.byteLength)), length: d.byteLength});
                else post({kind:'ws-send', name:'ws-send-' + tag, text: String(d).slice(0, 4096)});
              }
              return osend(d);
            };
            ws.addEventListener('message', (e) => {
              if (recv++ >= 40) return;
              const d = e.data;
              if (d instanceof ArrayBuffer) post({kind:'ws-recv', name:'ws-recv-' + tag, hex: hex(d), length: d.byteLength});
              else if (d instanceof Blob) d.arrayBuffer().then(b => post({kind:'ws-recv', name:'ws-recv-' + tag, hex: hex(b), length: b.byteLength}));
              else post({kind:'ws-recv', name:'ws-recv-' + tag, text: String(d).slice(0, 4096)});
            });
            ws.addEventListener('close', (e) => post({kind:'ws-close', name:'ws-close-' + tag, code: e.code, reason: e.reason}));
            return ws;
          };
          window.WebSocket.prototype = OW.prototype;
          Object.assign(window.WebSocket, OW);
        })();
        """#
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
#endif
