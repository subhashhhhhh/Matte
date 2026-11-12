# Instagram — a native macOS Instagram client

SwiftUI app that talks to instagram.com's own web API with the signed-in user's session
cookies. Sign-in is a one-time WKWebView sheet on Instagram's login page; after that
everything is native. Main uses: **DMs and Reels**, plus feed and stories. The goal is low
memory (the website uses 4–5 GB on an 8 GB Mac).

## Build, test, install

- The Xcode project is generated: edit `project.yml`, run `xcodegen generate`.
- macOS 15, Swift 6, **MainActor default isolation**. Types that cross actors are
  `nonisolated`; `IGClient`, `IGSession`, `ImagePipeline` are actors.
- Debug build: `xcodebuild -project Instagram.xcodeproj -scheme Instagram -configuration Debug -derivedDataPath <scratchpad>/dd build`
- Tests: `xcodebuild test -project Instagram.xcodeproj -scheme Instagram -derivedDataPath <scratchpad>/dd-test`.
  Read the whole result, including the trailing summary.
- **Commit and push after every working step** (private repo, `main`). The Mac shuts down
  without warning.

## Working with the test author

`InstagramTests/` belongs to a separate agent that writes tests (see its README). Fix the app
code; don't edit their tests. **Commit only `Instagram/`, `Support/`, `docs/`,
`Instagram.xcodeproj`, `project.yml` and this file** — never `git add -A`.

## Layout

- `Instagram/API/` — `IGClient` (REST `/api/v1/…` and Relay GraphQL on `/graphql/query`,
  `doc_id` registry read from instagram.com's scripts), `JSON` (exact 64-bit integers,
  streamed multi-part responses), `RegexHelpers`.
- `Instagram/Auth/` — `IGSession` (cookies, `csrftoken`, `ds_user_id`), `SignInView`.
- `Instagram/Images/` — `ImagePipeline` (downsampled decode, cost-limited cache), `RemoteImage`.
- `Instagram/App/` — `AppModel`, `MemoryRelief`, debug tools.
- `docs/dm-protocol.md` — DM protocol spec written from mautrix-instagram
  (`references/meta`, not tracked; `git clone https://github.com/mautrix/meta references/meta`).
- On disk: `~/Library/Application Support/com.subhash.Instagram/` — `session.json` (0600),
  `operations.json` (doc ids).

## How the API layer works

- Every request: session cookies, `x-csrftoken`, `x-ig-app-id` (936619743392459),
  `x-asbd-id`, `x-ig-www-claim` (from `x-ig-set-www-claim`), `x-mid`.
- GraphQL form: `av` = page's `actorID`, `fb_dtsg`, `lsd`, `jazoest`, `__spin_*`, `__hs`,
  `__hsi`, `__s`, `fb_api_req_friendly_name`, `variables`, `doc_id`. **`/graphql/query` works;
  `/api/graphql` answers error 1357054** for this session.
- `doc_id`s: scripts declare `__d("NameQuery_instagramRelayOperation",[],(function(…){a.exports="123"})`.
  Only scripts in the initial page are scanned; DM docs live in lazy chunks (seed from the spec).
- Error 1357054 ("Your request couldn't be processed") = bad variables/doc or wrong endpoint.
- REST: `feed/timeline/` works with a web session; `feed/reels_tray/`, `direct_v2/*`,
  `clips/home/` don't (use GraphQL).

## Debug launch flags (Debug builds)

- `-IGProbeRest <path> [-IGProbeQuery 'a=1']`, `-IGProbeGQL <Name> [-IGProbeVars '{…}'] [-IGProbeDoc id]`,
  `-IGProbePage YES` — with `-IGProbeOut <file>`; read-only, then quit.
- `-IGRawDir <dir>` — raw responses and the (redacted) GraphQL form for each request.
- `-IGStartPage home|reels|messages`, `-IGOpen post|story` — open on a page / open the first
  post or a story at launch (for screenshots; capture a window with `screencapture -l <id>`).
- `-IGCapture <dir> [-IGCapturePages '/,/reels/'] [-IGCaptureSeconds 12]` — loads the site in an
  off-screen web view with the session and records the web app's own API requests.

## Rules

- **Probes are read-only.** Never like, follow, send, mark seen, etc. on the user's account
  to test something; ask the user to try write actions themselves.
- Never commit or print personal data (cookies, tokens, usernames, probe dumps). Keep probe
  output in the scratchpad.
- **Design is fully custom — never stock Apple UI.** Use `Views/Theme.swift` components.
  `~/Developer/Velvet` (YouTube) and `~/Developer/Twitter` are the design references.
- Memory: decode images at display size via `ImagePipeline`, don't hold big JSON trees,
  call `MemoryRelief.soon()` after large parses, never grow collections from untrusted indices.
