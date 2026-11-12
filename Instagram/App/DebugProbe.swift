#if DEBUG
import Foundation

/// Debug-only, read-only probes against the saved session, for building parsers from real
/// responses. Never use them for actions (likes, follows, messages…). Each writes to
/// `-IGProbeOut <file>` and quits.
///
/// - `-IGProbeRest <path> [-IGProbeQuery 'a=1&b=2']`: GET a `/api/v1/` endpoint.
/// - `-IGProbeGQL <FriendlyName> [-IGProbeVars '{json}'] [-IGProbeDoc <doc_id>]`: run a Relay query.
/// - `-IGProbePage YES`: writes the page HTML, its config and the known doc ids next to the
///   output file, and saves the page's scripts in a `scripts/` folder there.
enum DebugProbe {
    static func runIfAsked() async {
        let d = UserDefaults.standard
        guard let out = d.string(forKey: "IGProbeOut") else { return }
        let args = ProcessInfo.processInfo.arguments
        func raw(_ key: String) -> String? {
            args.firstIndex(of: "-" + key).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        guard let session = IGSession.restore() else { fail("not signed in") }
        let client = IGClient(session: session)
        let outURL = URL(fileURLWithPath: out)
        do {
            let json: JSON
            if let path = raw("IGProbeRest") {
                var query: [String: String] = [:]
                for pair in (raw("IGProbeQuery") ?? "").split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    if kv.count == 2 { query[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
                }
                json = try await client.rest(.get, path, query: query)
            } else if let name = raw("IGProbeGQL") {
                let vars = try JSON(data: Data((raw("IGProbeVars") ?? "{}").utf8))
                json = ["data": try await client.graphQL(name, variables: vars, docId: raw("IGProbeDoc"))]
            } else if d.bool(forKey: "IGProbePage") {
                await client.reloadAppPage(keepHTML: true)
                let dir = outURL.deletingLastPathComponent()
                let html = await client.lastPageHTML ?? ""
                try Data(html.utf8).write(to: dir.appending(path: "page.html"))
                let page = await client.page
                let scriptsDir = dir.appending(path: "scripts")
                try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
                for (i, url) in page.scripts.enumerated() {
                    if let js = try? await client.fetchText(url, accept: "*/*") {
                        try? Data(js.utf8).write(to: scriptsDir.appending(path: "\(i).js"))
                    }
                }
                await client.scanScripts()
                json = [
                    "dtsg": page.dtsg.map(JSON.string) ?? .null, "lsd": page.lsd.map(JSON.string) ?? .null,
                    "appId": .string(page.appId), "asbdId": .string(page.asbdId), "rev": page.rev.map(JSON.string) ?? .null,
                    "scripts": .array(page.scripts.map { .string($0.absoluteString) }),
                    "docIds": .object(await client.knownOperations().mapValues(JSON.string)),
                ]
            } else {
                fail("nothing to probe")
            }
            try json.data().write(to: outURL)
            exit(0)
        } catch {
            fail("\(error)")
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("probe: \(message)\n".utf8))
        exit(1)
    }
}
#endif
