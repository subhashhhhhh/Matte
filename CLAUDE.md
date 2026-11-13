# Matte — a native macOS Instagram client

Matte is a SwiftUI app that talks to instagram.com's own web API with the signed-in user's
session cookies. Sign-in is a one-time WKWebView sheet on Instagram's login page; after that
everything is native. It's built for the desktop (a feed in columns, real-time DMs, Reels, stories,
posting, a story editor) and to stay light: instagram.com in a browser takes 4–5 GB.

Matte isn't affiliated with Instagram or Meta. It only does what the website does, as the website
does it.

## Build and run

- The Xcode project is generated: edit `project.yml`, run `xcodegen generate` (Homebrew: `brew install xcodegen`).
- macOS 15+, Xcode 27, Swift 6 with **MainActor default isolation**. Types that cross actors are
  `nonisolated`; `IGClient`, `IGSession`, `ImagePipeline` are actors.
- The app is **Matte** (`PRODUCT_NAME`, bundle id `com.subhash.Matte`); the code module and scheme are still
  called `Instagram`. Before 1.0 the bundle id was `com.subhash.Instagram`; `IdentityMigration` moves that
  identity's logins and settings over on first launch.
- Debug build: `xcodebuild -project Instagram.xcodeproj -scheme Instagram -configuration Debug -derivedDataPath build
  CURRENT_PROJECT_VERSION=$(git rev-list --count HEAD) build` (a fresh build number each time: macOS caches app icons by version).
- Tests (Swift Testing, hosted in the app): `xcodebuild test -project Instagram.xcodeproj -scheme Instagram`.
  Read the whole result, including the summary at the end.
- Releases (maintainer): `scripts/release.sh [--publish]` builds Apple silicon and Intel DMGs and zips signed with the
  "Matte Self-Signed" certificate (docs/signing.md), and with `--publish` creates the GitHub release, writes
  `updates/latest.json` (the in-app updater's feed) and updates the Homebrew cask (`packaging/matte.rb`). Release notes
  live in `docs/releases/<version>.md`.

## Layout

- `Instagram/API/` — `IGClient` (REST `/api/v1/…` and Relay GraphQL on `/graphql/query`,
  `doc_id` registry read from instagram.com's scripts), `JSON` (exact 64-bit integers,
  streamed multi-part responses), `RegexHelpers`.
- `Instagram/Auth/` — `IGSession` (cookies, `csrftoken`, `ds_user_id`), `SignInView`, `AccountStore`
  (several accounts: the current one is `session.json`, the others are parked in `accounts/<id>.json`,
  `accounts.json` lists names/avatars; switching parks the current one and rebuilds every model).
- **Manager tools**
  (`AppModel.managerMode`) follow the account type, no switch: on for a professional (business/creator) account
  (`Parser.isProfessional`: `is_professional_account` / `account_type` 2|3 in the profile query, remembered as
  `AccountSummary.professional`). Manager-only features (planner, scheduling, replies, insights) appear only then.
- `Instagram/Planner/` (Manager mode): the Planner page (month calendar + upcoming list of the account's
  scheduled posts, cancel) and `SchedulePicker`. Scheduling is Instagram's own (`API/Endpoints+Schedule.swift`,
  docs/create-protocol.md "Scheduling"); the create sheet's Schedule switch sets `PostOptions.scheduledAt`.
  Photos and reels can be scheduled (recorded); carousels not yet. A scheduled post's caption and time can be
  edited (click it in the Planner). `-IGPlannerSample YES` shows a made-up scheduled reel in the edit dialog;
  `-IGPlannerSave YES [-IGPlannerSaveCaption YES] -IGDryRunWrites <dir>` saves it in the dry run.
- `Instagram/Replies/` (Manager mode): comments on the account's last 12 posts, newest first, "Needs reply"
  (no reply from you yet; checks the replies of up to 25 comments per refresh) and "All", reply inline
  (the "@name" is added on send), like, mark done, saved replies (UserDefaults `savedReplies`).
  `-IGRepliesUser <username>` reads another public account's comments, `-IGRepliesOpen YES` opens the
  first reply box (screenshots; nothing is sent).
- Settings (`Views/SettingsView.swift`, sections down the side) read and write `App/Preferences.swift` (UserDefaults
  `pref.*`): appearance, open-on page, starting feed, hide suggested, start muted, hover previews, mini player,
  notifications, Dock badge, ghost mode (no story seen / read receipts / typing), download place, storage, accounts, about.
  `-IGSettingsSection <name>` opens a section; `-IGRenderSettings <dir>` renders every section (light and dark) without a window.
- `site/` — the website (matte.subhashh.tech): Astro, static, light (the icon's paper) and dark themes, served by a
  Cloudflare Worker (`site/wrangler.jsonc`). Version and changelog come from `docs/releases/*.md` at build time.
  `cd site && npm install && npm run build`. Its window screenshots and the README images are drawn in React
  (`docs/graphics/app.jsx`, made-up accounts) and rendered by `docs/graphics/render.jsx` (`npm run render` there; macOS).
- Feed refresh: Following and Favorites look for newer posts every 3 min while on screen and Matte is active
  (`FeedModel.refreshLive`); scrolled down they wait behind a "N new posts" pill. For You isn't refreshed that way
  (it's re-ranked each load). `-IGFeedRefreshSeconds N` checks every N s and logs `FEED check/live` to stderr.
  A post opened >60 s after its comments were read (hover prewarm) reloads them and its counts (`refreshIfStale`).
- `Instagram/Images/` — `ImagePipeline` (downsampled decode, cost-limited cache), `RemoteImage`.
- `Instagram/App/` — `AppModel`, `MemoryRelief`, `ResponseCache`, debug tools.
- `ResponseCache`: last good first pages (feed per source, tray, reels, Explore, inbox, 20 recent
  profiles) as Codable models in `~/Library/Caches/com.subhash.Matte/data/<ds_user_id>/`.
  Models show them as `stale` (no cursor: paging refetches page 1 first), refresh replaces them
  unless the user scrolled or opened a post. Off in tests; sign-out wipes it. A model field added
  without a default-tolerant decoder makes old files a miss (once), never a failure.
- `docs/dm-protocol.md` — DM protocol spec written from mautrix-instagram
  (`references/meta`, not tracked; `git clone https://github.com/mautrix/meta references/meta`).
- On disk: `~/Library/Application Support/com.subhash.Matte/` — `session.json` (0600),
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
- `-IGOpenSettings YES` — open Settings at launch. `-IGForceManager YES` shows the manager tools for a personal account too;
  `-IGStartPage planner` opens the Planner; `-IGCreateScheduleDays N` (with `-IGCreateFiles`) sets the sheet to
  publish in N days (dry-run it with `-IGCreateShare YES -IGDryRunWrites <dir>`). `-IGCaptureAccount <username>`
  records as a parked account. `-IGSwitchAccount YES` — switch to the next signed-in account 5 s after launch.
- `-IGStartPage home|reels|messages`, `-IGOpen post|story` — open on a page / open the first
  post or a story at launch (for screenshots; capture a window with `screencapture -l <id>`).
- `-IGCapture <dir> -IGCaptureInteractive YES`: a visible, signed-in instagram.com window; the user
  performs a write action themselves (watch a story, like…) and closes it; every request is recorded.
  Prefer this over guessing write mutations from the scripts (the scripts' "obvious" one can be wrong).
- `-IGDryRunWrites <dir>`: every write (GraphQL mutation, REST POST, DM upload) is written to `<dir>`
  as JSON (tokens redacted) instead of sent, and fails with "Dry run". `-IGProbeWrites YES -IGDryRunWrites <dir>
  -IGProbeOut <file>` runs every write Matte makes with made-up ids, for diffing against a recording.
  Every write was matched to two recordings of instagram.com on 2026-11-12 (shape and doc ids).
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
- Creating (docs/create-protocol.md; `Instagram/Create/`, `API/Endpoints+Create.swift`): `-IGMakeTestMedia <dir>`
  writes test photos and a 3 s MP4 and quits; `-IGCreateFiles 'a.jpg,b.jpg' [-IGCreateTarget post|reel|story]
  [-IGCreateShape square|portrait|landscape|tall] [-IGCreateCaption …]` opens the create sheet;
  `-IGCreateShare YES` presses Share **only with `-IGDryRunWrites`**. `-IGProbeCreate YES -IGDryRunWrites <dir>
  -IGProbeOut <file>` dry-runs every create/edit/delete flow. Uploads to `i.instagram.com/rupload_*` are
  dry-run too (headers + body size recorded, fake success, so the publish step is recorded next).
  `-IGOpenMe YES -IGOwnPostDialog caption|delete` shows those dialogs for your first post.
  The probe also runs the story editor's photo and video through the same story upload.
- Story editor (`Instagram/StoryEditor/`, docs/create-protocol.md "Story editor"): the sheet does Post and
  Reel only; stories are edited on a 9:16 canvas and uploaded flattened. `-IGStoryEditor photo|landscape|video|rotated|empty`
  opens it with generated media; `-IGStorySample YES`, `-IGStoryMode text|draw|stickers|filters`,
  `-IGStoryFilter oslo`, `-IGStorySelect YES`, `-IGStoryTrim '1,6'`, `-IGStoryMute YES`, `-IGStoryZoom 1.4` set it up;
  `-IGStoryClose YES` presses Close; `-IGStoryExport <dir>` writes the flattened file (+ `export.json`) and quits; `-IGStoryKeep <dir>` copies what's
  shared; `-IGStorySelfTest YES` checks edits/undo and quits; `-IGStoryShare YES` only with `-IGDryRunWrites`.
  `-IGShowCreateMenu YES` opens the "+" menu, `-IGDropTest video|photo` acts as a dropped test file.
- Story stickers (`Media.storyStickers`, parsed from `story_feed_media` / `story_bloks_stickers` mentions /
  `story_link_stickers` / `story_hashtags`; a post sticker's pk comes from its `media_code`): `-IGStickerTest bubble|open`
  starts the story at the first item with one and clicks it. `-IGAddToStory YES` opens "Add to story" for the first feed post.

## Playback

Pages stay alive while hidden, so anything with sound follows `EnvironmentValues.onScreen` (set in
`RootView`: the shown page, not covered by a profile, story, story editor, opened post or the create
sheet): videos (`StageVideo`, Reels, DM videos and voice notes) pause when it turns false and resume
after; post songs (`PostMusic`, one player, shared by holders) are released. Debug builds log
`MUSIC play/stop` and `VIDEO play/pause` to stderr; `-IGSwitchTo <page>` switches page 12 s after
launch and back 6 s later.

Mini player (`Views/MiniPlayer.swift`): the post or reel open in a viewer (`AppModel.presentedPost`, registered
by `PostLightbox` and the Reels page while on screen) shrinks into the corner whenever you leave it (a profile,
another tab, Back); clicking it goes back to that page/profile stack and grows it into place. Players are handed
over, never restarted (`VideoHandoff` for videos, `PostMusic` holders for songs). Debug: `-IGMiniTest YES
[-IGMiniExpand YES]`, `-IGSwitchTo <page> [-IGMiniBack YES]`.

## Real-time DMs

`Instagram/DMs/Realtime/`: `DGWFrames` (DGW framing, protobuf `LSResponse`, Thrift compact),
`DGWSocket` (one WebSocket, keepalive), `DMRealtime` (main + typing streams, reconnect,
`AsyncStream<DMRealtimeEvent>`). `InboxModel` applies events; it polls (60 s) only while the
socket is down. What the web app actually sends: docs/dm-protocol.md §5.10. Activity status comes
from a presence stream on the typing socket (§5.11), listen-only; `InboxModel.presence` is keyed by
messaging id.

## Rules

- **Probes are read-only.** Never like, follow, send, mark seen, etc. on a real account to test something; ask the
  person to try write actions themselves. Every write Matte makes was recorded from instagram.com first
  (`-IGCapture … -IGCaptureInteractive YES`) and is checked with the dry run (`-IGDryRunWrites`); don't guess mutations.
- Never commit or print personal data (cookies, tokens, usernames, user ids, probe dumps). Keep probe output out of
  the repository.
- **Design is fully custom; no stock Apple controls.** Use `Views/Theme.swift` components (and `Darkroom` colours on
  the welcome screen). The design follows Velvet (github.com/subhashhhhhh/Velvet).
- Memory: decode images at display size via `ImagePipeline`, don't hold big JSON trees, call `MemoryRelief.soon()`
  after large parses, never grow collections from untrusted indices.
- Write for people: plain words in UI text, comments and commit messages.
