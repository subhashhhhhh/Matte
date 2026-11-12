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
- The app is **Matte** (`PRODUCT_NAME`, Matte.app); the code module stays `Instagram`.
- Install: `xcodebuild … -configuration Release -derivedDataPath <scratchpad>/dd-release build`, quit the
  running app, `ditto <…>/Release/Matte.app /Applications/Matte.app`.
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
- Home feeds: `PolarisFeedTimelineRootV2Query`; Following (chronological) / Favorites are chosen with
  `data.pagination_source` ("following"/"favorites"). The top-level `variant` alone does nothing.
- Collab posts: `coauthor_producers`. Image candidates include square grid crops: pick by shape.
- REST: `feed/timeline/` works with a web session; `feed/reels_tray/`, `direct_v2/*`,
  `clips/home/` don't (use GraphQL).

## Debug launch flags (Debug builds)

- `-IGProbeRest <path> [-IGProbeQuery 'a=1']`, `-IGProbeGQL <Name> [-IGProbeVars '{…}'] [-IGProbeDoc id]`,
  `-IGProbePage YES` — with `-IGProbeOut <file>`; read-only, then quit.
- `-IGRawDir <dir>` — raw responses and the (redacted) GraphQL form for each request.
- `-IGStartPage home|reels|messages`, `-IGOpen post|story` — open on a page / open the first
  post or a story at launch (for screenshots; capture a window with `screencapture -l <id>`).
- `-IGCapture <dir> [-IGCapturePages '/,/reels/'] [-IGCaptureSeconds 12]` — loads the site in an
  off-screen web view with the session and records the web app's own API requests, and the
  first 40 WebSocket frames each way (hex) as `ws-send-*`/`ws-recv-*`.
- `-IGProbeDGW YES [-IGProbeSeconds 30] [-IGProbeDGWRewind N]` (+ `-IGProbeOut`) — connects the
  real-time DM sockets, only listens, writes frame/delta/event counts. Rewind replays the last N deltas.
  Presence: counts only; `-IGProbePresenceReport YES` also reports IDLE like the web app,
  `-IGProbePresenceNoContacts YES` skips asking for thread participants.
- DM screenshots (nothing is sent): `-IGStageFile <path>` (with `-IGOpenThread N`) puts a photo/video in the composer,
  `-IGForwardLast YES` opens "Forward to…", `-IGInboxFolder requests`, `-IGNewMessage <query>`, `-IGNewChatWith <query>`,
  `-IGTestNotification YES` posts a local notification for the first chat. Add `-ApplePersistenceIgnoreState YES`
  so the window isn't restored full screen.
- DM writes (upload, media send, edit, forward, requests, story replies): docs/dm-protocol.md §10b.

## Real-time DMs

`Instagram/DMs/Realtime/`: `DGWFrames` (DGW framing, protobuf `LSResponse`, Thrift compact),
`DGWSocket` (one WebSocket, keepalive), `DMRealtime` (main + typing streams, reconnect,
`AsyncStream<DMRealtimeEvent>`). `InboxModel` applies events; it polls (60 s) only while the
socket is down. What the web app actually sends: docs/dm-protocol.md §5.10. Activity status comes
from a presence stream on the typing socket (§5.11), listen-only; `InboxModel.presence` is keyed by
messaging id.

## Rules

- **Probes are read-only.** Never like, follow, send, mark seen, etc. on the user's account
  to test something; ask the user to try write actions themselves.
- Never commit or print personal data (cookies, tokens, usernames, probe dumps). Keep probe
  output in the scratchpad.
- **Design is fully custom — never stock Apple UI.** Use `Views/Theme.swift` components.
  `~/Developer/Velvet` (YouTube) and `~/Developer/Twitter` are the design references.
- Memory: decode images at display size via `ImagePipeline`, don't hold big JSON trees,
  call `MemoryRelief.soon()` after large parses, never grow collections from untrusted indices.
