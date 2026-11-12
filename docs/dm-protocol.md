# Instagram DM protocol (web-cookie session) — implementation spec

Source: mautrix-meta checkout at `/Users/subhash/Developer/Instagram/references/meta` (paths below are relative to it).
All `file:line` references point at that tree. Anything marked **(inferred)** was not read directly from code.

---

## 0. TL;DR — what applies to a web-cookie session

* **Instagram DMs no longer use Lightspeed (LS bytecode / tables) or MQTT-over-websocket at `edge-chat.instagram.com`.**
  instameow explicitly disables the LS table parser when loading the inbox page (`pkg/instameow/client.go:161`, `moduleLoader.LS = nil`).
  The whole `pkg/messagix/table`, `lightspeed`, `socket`, `syncManager` stack is only for Facebook/Messenger now. Ignore it.
* The current Instagram DM stack is Instagram web's **"Slide" (IGD) architecture**:
  * **Reads and writes go through Relay GraphQL**: `POST https://www.instagram.com/api/graphql` with persisted `doc_id`s
    (`pkg/messagix/endpoints/instagram.go:25`, `pkg/messagix/graphql/docs.go:89-224`, `pkg/instameow/graphql.go`).
  * **Real-time comes over "DGW"** (Meta's Direct Gateway), a custom binary framing protocol over a WebSocket:
    * `wss://gateway.instagram.com/ws/lightspeed` — main sync stream ("iris" mailbox deltas). Payloads are a small **protobuf**
      (`LSResponse`) wrapping **JSON** GraphQL-subscription deltas (`slide_delta_processor`) (`pkg/instameow/socket.go:195-388`).
    * `wss://gateway.instagram.com/ws/streamcontroller` — optional, receive typing indicators (Thrift compact) (`pkg/instameow/streamcontroller.go`).
    * `wss://gateway.instagram.com/ws/mqttbypass` — optional, send typing indicators (Thrift compact) (`pkg/instameow/mqttbypass.go`).
  * (The `https://...` constants are converted to `wss://` by the websocket library — `pkg/messagix/endpoints/instagram.go:9,29-31` use `https://gateway.instagram.com`; **(inferred)** you must use `wss://gateway.instagram.com/ws/...` in URLSession.)
* **Decision logic**: the bridge only uses the native/Android transport (HTTP/2 streaming POST to `https://gateway.instagram.com/lightspeed` with FlatBuffers envelope and `Authorization: OAuth …` / Bearer IGT headers) when it has an **Android native session** (`mobileSession != nil`) — `pkg/instameow/socket.go:191-193, 228-232`. Cookie logins have no native session (`pkg/igconnector/login.go` cookie flow; `ClientParams.NativeSession` nil), so they use the **web DGW websocket path with cookie auth**. Even with a native session the bridge falls back to the web socket after `NativeMainStreamAttempts = 2` failures (`socket.go:151-158, 189`).
  **=> Your WKWebView-captured cookies are a fully supported, first-class path. No Android login needed.**
* E2EE: nothing in `pkg/instameow` or `pkg/igconnector` touches E2EE; the `e2ee_ws_url` / `icdc_*` endpoints in `endpoints/instagram.go:37-39` are unused by instameow. Ignore.
* Older Python bridge (`references/instagram-legacy`) used the Android private API + MQTT at `edge-mqtt.facebook.com` (`mauigpapi/mqtt/conn.py:148`, `mauigpapi/http/base.py:74`). That's obsolete and not compatible with web cookies.

### Things that are *not* implemented in the bridge
* **Sharing a post/reel into a thread** — there is no share mutation in instameow. Only `forwarded_from_thread_id` / `is_forwarded_from_own_message` fields exist on the send requests (`slidetypes/requests.go:39-40, 49-50`) and are never set by the bridge. See §5.9.
* Receiving presence/"active now" — streamcontroller only subscribes to typing (`streamcontroller.go:107-109` comment).
* Sending "seen" for stories, voice-note recording, etc.

---

## 1. Identifiers (read this first — the #1 source of bugs)

Instagram web DMs juggle several IDs for the same thing:

| Name used here | Where it comes from | Used for |
|---|---|---|
| **Thread IGID** ("short", `thread_fbid`) | `ThreadInfo.id` == `ThreadInfo.thread_fbid` (`slidetypes/thread.go:41-45`); `Delta.thread_fbid` (`slidetypes/event.go:197`); `Message.thread_fbid` | Almost every GraphQL thread argument: `ig_thread_igid` in text send, `thread_id` in media/reaction/edit, `thread_fbid` in GetThread/admin ops, `id` in message pagination; `thread_id` in typing send. Stored by bridge as `meta.IGID` (`igconnector/chatinfo.go:286-295`). |
| **Thread long ID** (`thread_id`, a.k.a. "IGThreadID", "very long thread ID") | `ThreadInfo.thread_id` (`thread.go:46`); also returned as `thread_igid` by the navigation endpoint (`instameow/route.go:33-36`) | `send_data.thread_id` for unsend (`thread.go:114-117`), `metadata.ig_thread_igid` for mark-read (`thread.go:119-122`), path in typing events `/direct_v2/threads/<long id>/…` (`streamcontroller.go:164`), `forwarded_from_thread_id` (`requests.go:39`). |
| **Thread key** (`thread_key`, int64 "FBID") | `ThreadInfo.thread_key` (string-encoded int64, `thread.go:43`) | The bridge's primary key. URL `/direct/t/<thread_key>/`. For 1:1 chats it equals the other user's `interop_messaging_user_fbid` (`chatinfo.go:168-170, 243-247`); for groups it equals the IGID. |
| **User IGID** (`pk` / `id`) | `User.id`, `User.pk` (`slidetypes/user.go:23,32`), `PolarisViewer.id` | Group admin ops (`user_igids`), block (`target_user_id`), typing `sender_id`, profile query `id`. |
| **User messaging FBID** (`interop_messaging_user_fbid`, "EIMU") | `User.interop_messaging_user_fbid` (`user.go:20`); own: `CurrentUserInitialData.IG_USER_EIMU` (`client.go:247-255`) | `Message.sender_fbid`, `Reaction.sender_fbid`, `ReadReceipt.participant_fbid`, mentions `fbid`, group creation `recipient_eimu_fbids`. |
| `PolarisViewer.data.fbid` | page config | Some "third identifier" (`route.go:64`) used as `x-dgw-uuid` for the main socket and as `client_previous_actor_id`. Must equal `CurrentUserInitialData.NON_FACEBOOK_USER_ID` (`client.go:250`). |
| **Message ID** | `Message.id` (`mid.$…` style, **(inferred)**) — the bridge uses `Message.id` as the message key (`handlemeta.go` `handleMessage`, `backfill.go:204`) | `message_id` in reaction/edit/unsend/mark-read/reply. Note `Message.message_id` also exists (`message.go:30`); bridge always uses `Message.id` / `SentMessage.id` (`handlematrix.go:184`). |
| OTID (`offline_threading_id`) | Generated client-side: `(unixMillis << 22) \| (counter << 12) \| 42` where counter increments within the same millisecond (`pkg/messagix/methods/methods.go:29-42`) | Send/edit/mute/accept/group-create idempotency; echoed back in `Message.offline_threading_id`. |

Maintain three maps like the bridge does (`chatinfo.go:132-150`): long thread ID → thread key, IGID → thread key, user IGID → user FBID. Populate from every `ThreadInfo` you see.

To get IGIDs for a thread key you only know (e.g. new DM to a user FBID): `POST /ajax/navigation/` (§8.1).

---

## 2. Bootstrap after login

### 2.1 Cookies
Required: `sessionid`, `csrftoken`, `ds_user_id`; optional but forwarded: `rur`, `shbid`, `shbts`, `mid`, `ig_did` (`pkg/messagix/cookies/cookies.go:46-48`). Also `datr`, `wd` (viewport, `cookies.go:85-93`) if present.

* Send all cookies as one `Cookie: k=v; k=v` header (`cookies.go:77-85`).
* Update the jar from every response's `Set-Cookie` (`cookies.go:195-217`). For `rur`, `shbid`, `shbts`, `mid`, `ig_did` the bridge parses raw `Set-Cookie` itself to keep the raw value (the `rur` value contains quotes/backslashes like `"CCO\05412345\0541…"` **(inferred)** which Go's parser rejects) (`cookies.go:209-258`). In Swift: keep raw value byte-for-byte; `HTTPCookieStorage` may also mangle it, so consider managing the cookie header yourself.
* If a response sets `xs` or `sessionid` with `Max-Age<0` → logged out (`httpclient/http.go:498-503`).
* Response header `x-ig-set-www-claim` → store and send as `x-ig-www-claim` on subsequent API calls (`cookies.go:214-216`, `http.go:742-744`).

### 2.2 Fetch the inbox HTML page
`GET https://www.instagram.com/direct/inbox/` (`endpoints/instagram.go:15`, `client.go:162`) with "document" headers (`http.go:681-720`, `isSecFetchDocument=true`):

```
accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7
accept-language: en-US,en;q=0.9
dpr: 1
user-agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36
sec-ch-ua: "Chromium";v="141", "Google Chrome";v="141", "Not-A.Brand";v="99"
sec-ch-ua-platform: "Linux"
sec-ch-prefers-color-scheme: light
sec-ch-ua-full-version-list: "Chromium";v="141.0.7390.122", "Google Chrome";v="141.0.7390.122", "Not-A.Brand";v="99.0.0.0"
sec-ch-ua-mobile: ?0
sec-ch-ua-model: ""
sec-ch-ua-platform-version: ""
sec-fetch-dest: document
sec-fetch-mode: navigate
sec-fetch-site: none          ← comment: required, otherwise CSR bitmap data is missing
sec-fetch-user: ?1
upgrade-insecure-requests: 1
cookie: …
viewport-width: <wd cookie width or 1920>
x-asbd-id: 359341
```
(UA constants: `pkg/messagix/useragent/useragent.go:3-35`.) **Recommendation (inferred):** on macOS use a consistent real UA — ideally the same UA string your WKWebView used at login (Safari/macOS), and adjust `sec-ch-*` accordingly (Safari doesn't send `sec-ch-ua*` at all). The bridge spoofs Chrome/Linux and also spoofs Chrome's TLS fingerprint (`http.go:207-221`, `153-205`); URLSession's TLS fingerprint is Safari's, so claiming Safari is the consistent choice.

Redirects: if the request is redirected to a path containing `/challenge/`, `/auth_platform/`, `/accounts/scraping_warning/`, `/accounts/update_risky_contactpoint/` → challenge; `/checkpoint/` → checkpoint; `/accounts/suspended/` → suspended; `/consent/` or `/privacy/consent/*` → consent; `/login.php` → logged out (`http.go:443-508`). Implement with a `URLSessionTaskDelegate.willPerformHTTPRedirection`.

### 2.3 Parse the HTML
Parser: `pkg/messagix/httpclient/js_module_parser.go:106-207`, `modules.go`.

1. Find every `<script>` element; take its first text child (`js_module_parser.go:371-390`). (They also strip the substring `,BootloaderConfig` → `,` before parsing, line 381.)
2. `<script id="envjson">` → JSON; take `routing_namespace` (`modules.go:21-27`, `types/configs.go:197-205`).
3. `<script id="__eqmc">` → JSON `{ "u": "<ajax url>", "e": …, "f": "<fb_dtsg>", … }`; parse the query string of `u`: `jazoest`, `__comet_req` (also `__a`, `__user`) (`modules.go:28-40`, `types/configs.go:207-241`).
4. Every other script whose content parses as JSON object `{ "require": [...] }` (Instagram uses `<script type="application/json" data-sjs>` **(inferred)**): for each entry in `require`, an entry is a JSON array `[name, arg0, arg1, arg2, ...]` (`js_module_parser.go:51-68`):
   * `name == "ScheduledServerJS"` or `"ScheduledServerJSWithCSS"`, `arg0 == "handle"`: `arg2` is an array of objects; each object is `{"__bbox": {"require": [...], "define": [...]}}` (`js_module_parser.go:315-329`, `modules.go:234-277`).
     * For each `define` entry `[ConfigName, deps, data, configID]`: if `configID > 0`, append `configID` to the `__dyn` bitmap list, and if `ConfigName` is one of the names below, decode `data` into it (`modules.go:44-67`).
     * (`require` entries inside `__bbox` are only used for Messenger LS preloads and `RelayPrefetchedStreamCache`; with LS disabled this is a no-op for IG — `modules.go:102-176`.)
   * `name == "Bootloader"`, `arg0 == "handlePayload"`: `arg2` is array of `{ "csrUpgrade": ":1,2,3", "rsrcMap": {k: {"c": int, "p": ":1,2"}} }`; collect ints into the `__csr` bitmap (`js_module_parser.go:330-337`, `modules.go:279-327`). Only needed if you send `__csr`.
   * Bare (non-JSON) scripts starting with `requireLazy` contain the same data in older formats (`js_module_parser.go:213-289`). Probably unnecessary for IG today **(inferred)**.

Config names consumed (field names must match exactly; `types/configs.go:248-302`, `types/account.go`):

| define name | keys | used for |
|---|---|---|
| `DGWWebConfig` | `appId` (string) | `x-dgw-appid`, connect `app_id` (`socket.go:203,291`) |
| `IGDMqttWebDeviceID` | `clientId` | `x-dgw-deviceid`, connect `device_id`, mailbox `device_id_for_iris_subscription` (`socket.go:205`, `graphql.go:107`). If absent the socket generates a random UUID (`dgw/socket.go:68-70`). |
| `PolarisViewer` | `id` (IG user pk), `data.fbid`, `data.username`, `data.full_name`, `data.profile_pic_url(_hd)` | `x-dgw-uuid` (main: `data.fbid`; streamcontroller/mqttbypass: `id`), `client_previous_actor_id`, "is authenticated" check (`client.go:272-274`) |
| `CurrentUserInitialData` | `APP_ID`, `USER_ID`, `IG_USER_EIMU`, `NON_FACEBOOK_USER_ID`, `ACCOUNT_ID`, `NAME`, `SHORT_NAME` | `x-ig-app-id` (`http.go:745`), form `__user` (`http.go:370`), own messaging FBID = `IG_USER_EIMU` (`client.go:247-255`) |
| `DTSGInitData` | `token` | form `fb_dtsg` (`http.go:382`) |
| `LSD` | `token` | form `lsd` + header `x-fb-lsd` (`httpclient/configs.go:42`, `http.go:723-727`) |
| `SiteData` | `haste_session`, `pr`, `__spin_r`, `__spin_b`, `__spin_t`, `hsi` | form `__hs`, `dpr`, `__rev`/`__spin_r`, `__spin_b`, `__spin_t`, `__hsi` (`http.go:365-388`) |
| `WebConnectionClassServerGuess` | `connectionClass` | form `__ccg` |
| `InstagramWebPushInfo` | `rollout_hash` | header `x-instagram-ajax` on `reels_media` (`misc.go:123`) |

Post-processing (`httpclient/configs.go:40-68`): `__s` = web session ID = three random 6-char lowercase alnum groups `xxxxxx:xxxxxx:xxxxxx` (`methods.go:54-62`).

Authenticated iff `sessionid` cookie present AND `PolarisViewer.id != ""` (`client.go:272-274`). Own FBID valid iff `IG_USER_EIMU != ""` and `PolarisViewer.data.fbid == NON_FACEBOOK_USER_ID` (`client.go:247-255`); login aborts otherwise (`igconnector/login.go` "own fbid not found").

Caching: bridge caches the parsed config up to **24 h** (`client.go:296-319`) and refreshes the page at most every **5 min** on (re)connect (`client.go:225`) / **15 min** on "please reload" errors (`client.go:190`). After a reload it also updates the DGW device IDs (`client.go:200-212`).

### 2.4 `__dyn` / `__csr` (optional)
Run-length bitmap encoding (`pkg/messagix/crypto/bitmap.go`): build an int array `bmap` where `bmap[id]=1` for each collected ID; emit `str(bmap[0])` then for each run of equal values the run length `n` encoded as `(len(bin(n))-1)` zeros followed by `bin(n)`; right-pad the bit string with `0` to a multiple of 6; map each 6 bits through `0-9a-zA-Z-_` (`bitmap.go:9, 44-97`). The HTTPQuery struct comments mark `__dyn`, `__csr` and most `__*` params as "not required" (`http.go:306-339`) — start without them.

---

## 3. GraphQL request format (used for nearly everything)

`MakeGraphQLRequest` — `pkg/messagix/httpclient/graphql.go:194-255`, `NewHTTPQuery` — `http.go:365-399`.

`POST https://www.instagram.com/api/graphql` (no trailing slash; `endpoints/instagram.go:25`)
`content-type: application/x-www-form-urlencoded` (`types/contenttypes.go`)

Form fields (Go's `url.Values.Encode()` → **sorted by key**; empty values omitted):

| key | value |
|---|---|
| `__a` | `1` |
| `__ccg` | `WebConnectionClassServerGuess.connectionClass` |
| `__comet_req` | from `__eqmc` |
| `__csr`, `__dyn` | bitmaps (optional) |
| `__d` | `www` (Instagram only, `http.go:392-394`) |
| `__hs` | `SiteData.haste_session` |
| `__hsi` | `SiteData.hsi` |
| `__jssesw` | omitted for all IG DM docs (NewHTTPQuery sets `1` but MakeGraphQLRequest overwrites it with the doc's `Jsessw`, which is empty for IG docs — `http.go:394`, `graphql.go:218`) |
| `__req` | per-client counter, starts at 2 for first request, **base-36** (`http.go:62, 366, 372`) |
| `__rev`, `__spin_r` | `SiteData.__spin_r` |
| `__s` | web session ID (§2.3) |
| `__spin_b`, `__spin_t` | `SiteData` |
| `__user` | `CurrentUserInitialData.USER_ID` |
| `dpr` | `SiteData.pr` formatted `%g` |
| `fb_api_caller_class` | `RelayModern` |
| `fb_api_req_friendly_name` | doc name (e.g. `IGDirectTextSendMutation`) |
| `fb_dtsg` | `DTSGInitData.token` |
| `jazoest` | from `__eqmc` |
| `lsd` | `LSD.token` |
| `server_timestamps` | `true` |
| `variables` | JSON string of the request variables |
| `doc_id` | doc id from table below |

Headers (`http.go:681-748` with `isSecFetchDocument=false`, plus `graphql.go:227-233`):
```
accept: */*
accept-language: en-US,en;q=0.9
dpr: 1
user-agent / sec-ch-ua* : as in §2.2
x-fb-lsd: <LSD.token>
x-csrftoken: <csrftoken cookie>
x-mid: <mid cookie>                      (if present)
x-ig-www-claim: <claim>                  (if one was received)
x-ig-app-id: <CurrentUserInitialData.APP_ID>
X-IG-Max-Touch-Points: 0
cookie: …
viewport-width: 1920
x-asbd-id: 359341
x-fb-friendly-name: <doc name>
sec-fetch-dest: empty
sec-fetch-mode: cors
sec-fetch-site: same-origin
origin: https://www.instagram.com
referer: https://www.instagram.com/direct/inbox//   ← bridge literally sends a double slash (messages endpoint + "/")
```

Response: optionally prefixed with `for (;;);` — strip it (`graphql.go:192, 253`). Body shape (`graphql/responses.go:22-26`, `types/error.go:12-19`):
```json
{ "data": {...}, "errors": [ {message, severity, code, summary, description, path, ...} ],
  "error": 1357004, "errorSummary": "...", "errorDescription": "...", "redirectTo": "...",
  "extensions": {...} }
```
Error handling (`instameow/graphql.go:201-242`): `error == 1357031` (content unavailable) → re-fetch inbox page to look for account notices (max every 8 h); `error == 1357004` ("please reload page") → re-fetch inbox page and retry once; `1357001` = please log in (`types/error.go:56-58`). For `IGDThreadDetailQuery` / `IGDMessageListOffMsysQuery`, partial `errors` with non-null data are ignored (`graphql.go:116-132`). Update cookies from every response (`graphql.go:250-252`).

### 3.1 doc_id table (IG DM-relevant; `pkg/messagix/graphql/docs.go`)

| Friendly name | doc_id | Purpose | Response root key |
|---|---|---|---|
| `PolarisDirectInboxQuery` | `27262915580045003` | initial inbox + iris seq id | `get_slide_mailbox_for_iris_subscription` |
| `IGDThreadListOffMsysPaginationQuery` | `27712934271665380` | older threads | `fetch__SlideMailbox` |
| `IGDThreadDetailQuery` | `37117700834487428` | one thread + first 20 messages | `get_slide_thread_nullable` |
| `IGDMessageListOffMsysQuery` | `27502152406082940` | message pagination | `fetch__SlideThread` |
| `IGDirectTextSendMutation` | `26911679871773184` | send text / reply | `xig_direct_text_send_with_slide_messaging_response` |
| `IGDirectMediaSendMutation` | `25766288509716264` | send uploaded media | `xig_direct_media_send_with_slide_messaging_response` |
| `IGDirectReactionSendMutation` | `24374451552236906` | react / unreact | `xig_direct_reaction_send_with_slide_messaging_response` |
| `IGDirectEditMessageMutation` | `32480262318254796` | edit | `direct_edit_message_with_slide_messaging_response` |
| `IGDMessageUnsendDialogOffMsysMutation` | `26948700068153789` | unsend | `direct_unsend_message` |
| `useIGDMarkThreadAsReadMutation` | `27356881703909995` | mark read | `xig_direct_item_seen_mutation_with_slide_messaging_response` |
| `useIGDMarkThreadAsReadValidationMutation` | `35211594988486314` | mark-read validation (sent right after) | `xig_direct_mark_read_id_validation` |
| `useIGDirectAcceptMessageRequestMutation` | `36571001125823973` | accept request | `ig_direct_accept_message_request` |
| `PolarisDirectMessageRequestQuery` | `27512223021750545` | list requests (defined, unused by bridge) | — |
| `useIGDSystemFolderUnreadThreadCountQuery` | `26619714737686638` | unread count (defined, unused) | — |
| `IGDSlideAsyncFetchAndInsertIGDViewerThreadQuery` | `27257464393915989` | (defined, unused) | — |
| `IGDInboxInfoDeleteThreadDialogOffMsysMutation` | `35352443081068612` | delete/hide thread | `ig_direct_hide_thread` |
| `IGDInboxInfoMuteToggleOffMsysMutation` | `26360506043651125` | mute | `xig_direct_mute_thread_with_fbid` |
| `useIGDPinThreadMutation` | `26491513390471063` | pin thread | `xig_direct_pin_thread` |
| `useIGDPinMessageOffMsysMutation` / `useIGDUnpinMessageOffMsysMutation` | `27027218840244998` / `26919110827778778` | pin message | `xig_direct_pin_message` / `xig_direct_unpin_message` |
| `IGDOmniPickerSearchResultsListQuery` | `27248216181454285` | user search | `xfb_combinedIGSearchQuery.search_messenger_contact_v2` |
| `useIGDCreateOptimisticThreadUserQuery` | `35274961328786258` | user info by messaging FBID | `xig_user_from_messaging_user_fbid` |
| `PolarisProfilePageContentQuery` | `26672929172408668` | profile | `user`, `viewer` |
| `useCreateOpenGroupThreadOffMsysMutation` | `27529949946640544` | create group | `xig_ig_direct_create_thread` |
| `IGDEditThreadNameDialogOffMsysMutation` | `26508340268868683` | rename group | — |
| `IGDAddParticipantSubmitBarMutation` | `27335198219492328` | add members | `xig_ig_direct_add_users` |
| `IGDRemoveFromGroupDialogItemOffMsysMutation` | `27974649738797533` | remove member | `xig_direct_remove_thread_user` |
| `useIGDLeaveChatMutation` | `27243106098639056` | leave | `xig_ig_direct_leave_thread` |
| `IGDAddAdminDialogItemOffMsysMutation` / `IGDRemoveAdminDialogItemOffMsysMutation` | `35563011113312213` / `26688907887428172` | admins | `xig_direct_add_admins` / `xig_direct_remove_admins` |
| `IGDBlockUserDialogOffMsysMutation` / `…UnblockMutation` | `28875204315418002` / `28615617751365746` | block | `xdt_block_v2` / `xdt_unblock` |
| `IGDSlideDeltaProcessorQuery` (subscription, used inside the socket payload) | `27931342966497053` | — | — |
| `IGDTypingIndicatorClientSubscription` | `27563068933278040` | typing subscription | — |

Response struct definitions: `pkg/instameow/slidetypes/responses.go`. **These doc_ids rotate when Instagram ships new web bundles** — see §9.

---

## 4. Initial sync, inbox, history

### 4.1 Connect sequence used by the bridge
`igconnector/client.go:254-376`, `instameow/client.go:216-245`:
1. Load inbox HTML (§2).
2. `PolarisDirectInboxQuery` (§4.2). Save `iris_inactive_subscription_uq_seq_id` as `seqID` and `seqIDTS = now` (`client.go:242-243`).
3. Show threads (`chatsync.go:39-113`). If `page_info.has_next_page`, optionally page more (§4.3).
4. Open the DGW main socket with `last_applied_cursor = {"seq_id": seqID}` (§5 of transport, below). All events after the snapshot arrive as deltas.
5. On later app launches, if you have a saved `seqID` (and cached config < 24 h) you can skip step 2 and connect directly with the saved cursor (`client.go:287-304`, `socket.go:245-270`). The server replays everything after that seq ID.

### 4.2 Inbox — `PolarisDirectInboxQuery`
Variables (`slidetypes/requests.go:188-206`):
```json
{"device_id_for_iris_subscription":"<IGDMqttWebDeviceID.clientId>",
 "__relay_internal__pv__IGDIsProfessionalAccountGKrelayprovider":false,
 "__relay_internal__pv__IGDPinnedThreadsRenderEnabledGKrelayprovider":true,
 "__relay_internal__pv__IGDMaxUnreadMessagesCountrelayprovider":5,
 "__relay_internal__pv__PolarisAIGMAccountLabelEnabledrelayprovider":false,
 "__relay_internal__pv__IGDThreadListActionsEnabledGKrelayprovider":true}
```
Response `data.get_slide_mailbox_for_iris_subscription` (`slidetypes/mailbox.go:19-27`):
```
{ iris_inactive_subscription_uq_seq_id: "<int as string>",
  threads_by_folder: { edges: [ { node: { id, as_ig_direct_thread: ThreadInfo }, cursor } ],
                       page_info: { end_cursor, has_next_page, has_previous_page, start_cursor } },
  pinned_threads_v2: [ {id, as_ig_direct_thread} ], id, __token }
```
`ThreadInfo` (`slidetypes/thread.go:41-81`): `id`, `thread_key` (string int), `thread_fbid`, `thread_subtype` (`IG_ONLY_ONE_TO_ONE`, `IG_BUSINESS_ACCOUNT_ONE_TO_ONE`, `IG_AI_BOT_ONE_TO_ONE`, `IGD_GROUP` — `thread.go:32-37`), `thread_id`, `is_group`, `viewer_id`, `viewer` (User), `thread_title`, `thread_image_url`, `users` [User] (excludes viewer), `nicknames` [{`eimu_id`,`nickname`,`igid`}], `last_activity_timestamp_ms` (string ms), `slide_messages` (Edged messages), `slide_read_receipts` [{`participant_fbid`,`watermark_timestamp_ms`}], `marked_as_unread`, `system_folder` (`PENDING`/`SPAM` = message request, `chatinfo.go:296`), `input_mode`; in list only: `is_muted`, `is_pin`, `folder`, `messaging_folder_tag`, `usersWithoutViewer`, `thread_label`; in detail only: `pinned_messages`, `ig_thread_capabilities`, `reachability_status`, `admin_user_ids` (user IGIDs), `group_creator`.
`User` (`slidetypes/user.go:19-42`): `interop_messaging_user_fbid`, `username`, `full_name`, `id`, `pk`, `profile_pic_url`, `is_verified`, `ai_agent_type`, `friendship_status{is_restricted,blocking,following}`, `fbid_v2`, `latest_reel_media`, ….

**Important:** messages embedded in the inbox list are "stub messages which can't be used safely" (`handlemeta.go` comment in `wrapChatResync`, ~line 186). Use them only for the preview; fetch the thread for real history.

Group vs DM: group if `is_group || users.count > 1` (`chatinfo.go:198-203`). Self-chat ("note to self"): `users` empty and `thread_key == viewer.interop_messaging_user_fbid` (`chatinfo.go:245-247`). Unread: compare own entry in `slide_read_receipts` with `last_activity_timestamp_ms`, overridden by `marked_as_unread` (`backfill.go:118-131`).

### 4.3 Older threads — `IGDThreadListOffMsysPaginationQuery`
(`requests.go:208-233`, `chatsync.go:233-256`)
```json
{"count":5, "cursor":"<page_info.end_cursor>", "folder":"INBOX", "newer_than_timestamp_ms":null,
 "id":"<own messaging FBID as string>",
 "__relay_internal__pv__IGDPinnedThreadsRenderEnabledGKrelayprovider":true,
 "__relay_internal__pv__IGDMaxUnreadMessagesCountrelayprovider":5,
 "__relay_internal__pv__PolarisAIGMAccountLabelEnabledrelayprovider":false,
 "__relay_internal__pv__IGDThreadListActionsEnabledGKrelayprovider":true}
```
`id` = own FBID (bridge passes the user-login ID which is `IG_USER_EIMU`, `chatsync.go:150`, `login.go` `MakeUserLoginID(ownFBID)`). Response `data.fetch__SlideMailbox.threads_by_folder` (same Edged shape). Partial errors with data are tolerated (`chatsync.go:242-245`). Skip edges whose `as_ig_direct_thread` is null or has null `users` (`chatsync.go:189-196`). Bridge waits `batch_delay` (default **2 s**) between pages (`example-config.yaml` thread_backfill, `chatsync.go:236-239`). Other folder values **(inferred)**: requests folder probably `"PENDING"` — untested in bridge.

### 4.4 One thread + newest messages — `IGDThreadDetailQuery`
(`requests.go:158-175`)
```json
{"min_uq_seq_id":null, "thread_fbid":"<thread IGID>",
 "__relay_internal__pv__IGDEnableOffMsysChatThemesQErelayprovider":false,
 "__relay_internal__pv__IGDInitialMessagePageCountrelayprovider":20,
 "__relay_internal__pv__PolarisAIGMAccountLabelEnabledrelayprovider":false}
```
Response `data.get_slide_thread_nullable` = `{id, as_ig_direct_thread: ThreadInfo}` with `slide_messages.edges` **newest first** (`backfill.go:194-196` reverses them) and `page_info.end_cursor/has_next_page` pointing at older messages.

### 4.5 Message history paging — `IGDMessageListOffMsysQuery`
(`requests.go:177-186`, `backfill.go:104-110, 163-170`)
```json
{"after":"<end_cursor or null>", "before":null, "first":20, "last":null,
 "newer_than_message_id":null, "older_than_message_id":"<message id or null>",
 "id":"<thread IGID>", "__relay_internal__pv__IGDInitialMessagePageCountrelayprovider":20}
```
Either pass `after = previous page_info.end_cursor`, or (first call, anchored on a known message) `after=null, older_than_message_id=<Message.id>`. Response `data.fetch__SlideThread.as_ig_direct_thread.slide_messages` (`responses.go:38-41`). Pages are newest→oldest; continue while `has_next_page`.

### 4.6 Message object
`slidetypes/message.go:28-57`:
```
id                      ← canonical message ID (use this)
message_id, offline_threading_id, thread_fbid (thread IGID)
sender_fbid             ← messaging FBID (string-encoded int64)
timestamp_ms            ← string ms
content { __typename, ... }   ← see §6.3
content_type            (e.g. "IG_VIDEO_CALL_XMAT", message.go / from-instagram.go:199-204)
text_body, igd_snippet (preview text)
mentions [{offset,length,profile_range_type: PROFILE|THREAD|THREAD_ACTIVE|COMMUNITY_CHANNEL|SILENT|CUSTOM|AI, user_fbid}]
reactions [{log_message_id, reaction (emoji), reaction_timestamp_ms, sender_fbid}]
replied_to_message_id, replied_to_message (nested Message)
sender { name, id, igid, user_dict: User }
slide_edit_history [{__typename, body, timestamp_ms}]
is_pinned, igd_is_forwarded, is_ai_generated, is_reported
expiration_timestamp_ms, view_expiration_timestamp_ms, __typename
```
Mention offsets/lengths are presumably UTF-16 code units **(inferred — JS origin)**.

---

## 5. Real-time transport: DGW

### 5.1 WebSocket connection
`pkg/messagix/dgw/socket.go:199-231, 515-551`, options from `instameow/socket.go:195-234`.

URL: `wss://gateway.instagram.com/ws/lightspeed?<query>` with query params (URL-encoded, Go sorts them alphabetically on encode):
```
x-dgw-appid=<DGWWebConfig.appId>
x-dgw-appversion=0
x-dgw-authtype=6:0
x-dgw-version=5            (comment: DGWVER_BIG_IDS)
x-dgw-uuid=<PolarisViewer.data.fbid>         ← main socket
x-dgw-tier=prod
x-dgw-deviceid=<IGDMqttWebDeviceID.clientId>
[x-dgw-loggingid=<random uuid>]              ← only mqttbypass socket
[x-dgw-app-stream-group=group1]              ← only streamcontroller socket
```
Handshake headers:
```
cookie: <all cookies>
user-agent: <UA>
origin: https://www.instagram.com
sec-fetch-dest: empty
sec-fetch-mode: websocket
sec-fetch-site: same-site
```
Read limit unlimited. The bridge forces HTTP/1.1 + Chrome TLS fingerprint for the websocket (`http.go:110-122, 153-205`). Handshake timeout 20 s (`http.go:293`). In Swift: `URLSessionWebSocketTask` with a `URLRequest` carrying these headers **(inferred: verify that URLSession forwards `Origin` and `Cookie` as set; disable `httpShouldHandleCookies` and set Cookie manually)**.

Only **binary** websocket messages are meaningful; text messages are dropped (`dgw/socket.go:429-435`). A single websocket message may contain **several concatenated DGW frames**; parse in a loop (`dgw/socket.go:436-445`). Frames don't span websocket messages (TODO comment line 440). The client also writes several frames in one websocket message (establish + first data, `persistentstream.go:61-75`).

Close codes: 4000 graceful, 4001 keepalive timeout, 4002 server error, **4003 unauthorized**, 4004 rejected, 4005 bad request (`dgw/frames.go:31-38`).

### 5.2 DGW frame layout (all integers little-endian)
`pkg/messagix/dgw/frames.go`. `u24` = 3-byte LE length.

| Type byte | Name | Layout |
|---|---|---|
| `0x03` | Drain | `03 \| u24 len(=1) \| reason:u8` (0 ELB,1 SLB,2 AppServerPush,3 GracePeriodExpired,4 Unknown,5 MaxConnectionAgeExceeded) (`frames.go:40-49, 241-266`) — informational; server will close soon **(inferred)**. |
| `0x04` | Deauth | `04` (1 byte). On websocket transport the bridge only logs it; it's fatal only on the native HTTP transport (`dgw/socket.go:400-404`). Treat as logout signal **(inferred)**. |
| `0x09` | Ping | `09` |
| `0x0A` | Pong | `0A` |
| `0x0C` | Ack | `0C \| streamID:u16 \| u24 len(=2) \| ackID:u16` (`frames.go:412-444`) |
| `0x0D` | Data | `0D \| streamID:u16 \| u24 len \| ackField:u16 \| payload` where `len = 2 + payload.count`; `ackField` low 15 bits = ackID, top bit (bit 15, i.e. `0x80` of the second byte) = requiresAck (`frames.go:332-402`) |
| `0x11` | ExtendedData | same as Data but `len = 3 + payload.count` and one extra `contentType:u8` byte after ackField. Received data of either type must be accepted. Only native HTTP transport sends this (`frames.go:555-566`). |
| `0x0E` | EndOfData | `0E \| streamID:u16` (3 bytes) |
| `0x0F` | EstablishStream | `0F \| streamID:u16 \| u24 len \| JSON params` (`frames.go:514-549`) |
| `0x10` | EndOfDataWithReason | `10 \| streamID:u16 \| u24 len(≥1) \| reason:u8` (0 Unknown,1 UpstreamTermination,2 ClientHasFinishedSending,3 StreamError,4 AuthError,5 ParsingError,6 ClientPubackError,7 UpstreamException,8 Draining,9 EndpointRegistrationFailed) (`frames.go:70-83`) |
| other | Unsupported (2 Empty, 5/6/8 deprecated, 7 SmallAck) — log and drop the rest of the message (`frames.go:115-130, 220-235`) |

### 5.3 Socket-level behavior
`dgw/socket.go:256-513`:
* Send `Ping` (0x09) every **10 s**. Any Ping or Pong from server resets a **30 s** pong-timeout; on timeout, close and reconnect (`socket.go:256-260, 306, 344-348, 449-478`).
* Reply to server `Ping` with `Pong`.
* Data frame with `requiresAck` → after your handler succeeds, send `Ack{streamID, ackID}` (`persistentstream.go:105-123`). Data for unknown streams is still acked (`socket.go:356-364`). **If your handler fails, don't ack** — bridge tears down the connection (`socket.go:327-331`) so the server replays.
* Stream IDs: client-chosen u16, counter **reset to 0 on each new connection** (`socket.go:87-107, 507`). First stream opened = 0.
* Ack IDs: per stream, start at 0, wrap at `0x7FFF` (`persistentstream.go:183-199`).
* Write timeout 20 s; ack timeout 5 s; one-off response timeout 30 s (`socket.go:256-260`).

### 5.4 Opening a stream
`persistentstream.go:60-103`: write in one websocket message:
1. `EstablishStream{streamID, params}` — for the main lightspeed stream `params` is **empty (zero-length)** because `StreamInit.Parameters` is nil (`instameow/socket.go:211-221`); streamcontroller passes JSON (§5.7).
2. optionally a `Data{streamID, requiresAck=true, ackID=next, initPayload}`.

Then wait ≤5 s for the server's `EstablishStream` reply on that stream ID whose JSON is either `{"code":200,...}` or the bare number `200`; anything else = error (`basestream.go:60-79`). Then wait ≤5 s for the `Ack` of the init payload.
Server `EndOfData`/`EndOfDataWithReason` on an established stream → stream closed; for the main stream the bridge treats it as fatal (`ErrMainStreamClosed`, after a 3 s delay) and reconnects (`instameow/socket.go:213-220`).

### 5.5 Main stream (`/ws/lightspeed`) init payload — web
`instameow/socket.go:236-297`. The init Data payload is UTF-8 JSON:
```json
{"app_id":"<DGWWebConfig.appId>",
 "device_id":"<IGDMqttWebDeviceID.clientId>",
 "payload":"<STRING: JSON of DatabaseQuery below>",
 "request_id": 4 + retryCount,
 "type": 2}
```
`DatabaseQuery` (`pkg/messagix/socket/socket.go:14-22`):
```json
{"database":223,
 "last_applied_cursor":"<STRING: {\"seq_id\":<seqID int>}>",
 "sync_params":"<STRING: JSON of syncParams>",
 "epoch_id":0,
 "version":-3,
 "failure_count":<retryCount>}
```
`syncParams` (`socket.go:244-249, 255-265`):
```json
{"user_agent":"WMI Web",
 "snapshot_at_ms":<seqIDTS unix ms>,
 "prevalidated_graphql_doc_id":"27931342966497053"}
```
(`snapshot_app_version` omitted on web.) `retryCount` = number of reconnects of this connection loop so far (`socket.go:106, 130`). Note `version` is a JSON number (`json.Number`), `last_applied_cursor` and `sync_params` are JSON-in-a-string. Zero `snapshot_at_ms` → `0` **(inferred from mautrix `jsontime` behavior)**.

### 5.6 Main stream incoming frames
`instameow/socket.go:299-388`:
1. Data payload is JSON `{"request_id": <int|null>, "payload": "<base64>"}` (Go `[]byte` → standard base64) (`socket.go:299-302, 310`).
2. base64-decode `payload` → protobuf `LSResponse` (`pkg/instameow/mdCoreSync/MDCoreSync.proto`, proto2):
```proto
message LSResponse { optional bytes controlHeader = 1; repeated Operation operations = 2; optional TransactionParams transactionParams = 3; }
message Operation { oneof operation { OnIrisSubscribe subscribe = 1; OnResnapshot resnapshot = 2; OnMailboxDelta delta = 3; Noop noop = 4; HandleSyncFailure failure = 5; } }
message OnIrisSubscribe { optional int32 groupID = 1; optional int64 subscribedSeqID = 2; optional int64 latestSeqID = 3; }
message OnResnapshot   { optional int32 groupID = 1; optional string errorMessage = 2; optional int32 errorType = 3; optional bytes snapshotPayload = 4; }
message OnMailboxDelta { optional int32 groupID = 1; optional string delta = 2; }
message Noop {}
message HandleSyncFailure { required int32 groupID = 1; required string errorMessage = 2; }
message TransactionParams { optional bool useTransactionLogic=1; optional int32 groupID=2; optional int64 syncEpochID=3; optional string previousCursor=4; optional string nextCursor=5; optional int32 syncStatus=6; optional int32 syncChannel=7; optional int64 userID=8; optional bool skipMismatchLog=9; }
```
   You only need fields 2 of LSResponse and the Operation oneof. A ~100-line hand-written protobuf varint/length-delimited reader is enough (no SwiftProtobuf needed).
3. Per operation:
   * `subscribe` → connected. If `subscribedSeqID >= latestSeqID` you're caught up; otherwise deltas up to `latestSeqID` are a replay (`handlemeta.go:109-118`).
   * `resnapshot` → your seq ID is too old/invalid: discard seqID, close, re-run full bootstrap (inbox query) and resync threads active since the old `seqIDTS` (`socket.go:119-125, 344-346`; `handlemeta.go:173-177`; `client.go:498-520`; `chatsync.go:65-108`).
   * `delta` → `delta` is a **JSON string**: array of `{"data":{"slide_delta_processor":[Delta,…]}}` (`slidetypes/event.go:188-192`). Process each Delta (§6). After processing, if any `uq_seq_id` > stored seqID, persist new seqID + timestamp (`socket.go:347-379`).
   * `noop` → ignore.
   * `failure` → reconnect (`socket.go:382-384`).
4. A delta that keeps failing is skipped after 5 attempts on the same `uq_seq_id` (`socket.go:43-46, 390-408`); backoff `min(2^attempts s, 60 s)`.

### 5.7 Reconnect policy
`instameow/socket.go:77-173`, `igconnector/handlemeta.go:122-147`, `client.go:254-376, 443-486`:
* Connection failed before subscribing: backoff `min(2^min(n,10) s, 60 s)`; after a successful connection drop: reconnect immediately.
* Unauthorized (close 4003 / `dgw.ErrUnauthorized`) → stop; treat as logged out.
* Main stream closed >5 times in a row → give up with error.
* Bootstrap retries: `2^attempt` s, up to 10 attempts (`client.go:190, 278-286`).
* Bridge forces a full reconnect (page reload + reconnect) every **20 h** by default (`force_refresh_interval_seconds: 72000`), and after "account restricted"-type errors rechecks every 5 min doubling up to 8× (`client.go:443-486`).
* On macOS wake/network change: just reconnect with the saved cursor (inferred).

### 5.8 Typing — receive (`/ws/streamcontroller`, optional)
`instameow/streamcontroller.go:77-220`. Second DGW websocket, URL `wss://gateway.instagram.com/ws/streamcontroller`, same query params except `x-dgw-uuid=<PolarisViewer.id>` and `x-dgw-app-stream-group=group1`.
On connect, open stream 0 with EstablishStream **params JSON**:
```json
{"x-dgw-app-XRSS-method":"FBGQLS:XDT_DIRECT_REALTIME_EVENT",
 "x-dgw-app-XRSS-doc_id":"27563068933278040",
 "x-dgw-app-XRSS-routing_hint":"IGDTypingIndicatorClientSubscription",
 "x-dgw-app-xrs-body":"true",
 "x-dgw-app-XRS-Accept-Ack":"RSAck",
 "x-dgw-app-XRSS-http_referer":"https://www.instagram.com/direct/"}
```
(no init payload). After established, send one Data frame (requiresAck) whose payload is **Thrift Compact** `requeststream.Payload{ request_body (field 2): RequestStreamBody{ body (field 1, binary): <JSON> } }` with JSON:
```json
{"input_data":{"user_id":"<PolarisViewer.id>"},"%options":{"useOSSResponseFormat":true,"client_has_ods_usecase_counters":true}}
```
Compact bytes: `2C 18 <varint len> <json bytes> 00 00` (field-delta 2 struct = `0x2C`; field-delta 1 binary = `0x18`; stop `0x00` for inner and outer struct). Thrift IDL: `pkg/instameow/thrift/requeststream.thrift`.

Incoming Data frames: Thrift Compact `Payload` union (fields: 2 request_body, 3 amend, 4 ack, 5 response, 6 ping, 7 pong). Only handle field 5 `StreamResponse{1: i64 response_id, 2: list<StreamResponseDelta> delta, 3: AckLevel, 4: binary, 5: binary}`; each `StreamResponseDelta` is a union: 1 `flow_status` (i32 enum: 1 Accepted, 2 Started, 3 Stopped), 2 log, 3 rewrite, 4 `data: ResponseData{1: binary bytes, 2: string metadata}`, 5 termination{1 reason (40 Rejected,50 Error,80 TryAgain,99 Closed), 2 message, 3 retry_delay_ms}, 6 amend_ack. `flow_status == 2` means subscription active (`streamcontroller.go:176-180`). `data.bytes` is JSON (`slidetypes/streamcontroller.go:23-44`):
```json
{"data":{"xdt_direct_realtime_event":{"event":"patch","data":[
  {"op":"add","path":"/direct_v2/threads/<LONG thread id>/activity_indicator_id/<x>",
   "value":"<JSON string: {\"timestamp\":<µs>,\"sender_id\":<user IGID>,\"ttl\":<int>,\"activity_status\":<0|1>,\"attribution\":…}>"}]}}}
```
Path regex: `^/direct_v2/threads/(\d+)/activity_indicator_id/.+$` (`streamcontroller.go:164`). `activity_status` 1 = typing, 0 = stopped; bridge shows typing for 6 s (`handlemeta.go:693-724`). Map long thread ID → thread, user IGID → user.
Reconnect same as main, but stop on unauthorized (`streamcontroller.go:37-75`). You need a minimal Thrift compact **decoder** (varints, zigzag, field headers, lists, nested structs, skip unknown) — ~200 lines.

### 5.9 Typing — send (`/ws/mqttbypass`, optional)
`instameow/mqttbypass.go`. Lazily opened third DGW websocket `wss://gateway.instagram.com/ws/mqttbypass`, query: `x-dgw-uuid=<PolarisViewer.id>`, plus `x-dgw-loggingid=<random UUID>`.
On connect: EstablishStream (empty params) + init Data (requiresAck) = Thrift Compact `mqttbypass.RequestPayload{ connectRequest (field 1): ConnectRequest }` with web values (`mqttbypass.go:100-103`; required fields are always written — generated code):
```
ConnectRequest { 1: i64 sessionId = 0, 2: i64 clientCapabilities = 0, 3: string userAgent = "",
                 4: string deviceId = <IGDMqttWebDeviceID.clientId>, 5: string familyDeviceId = "",
                 6: SubscribeRequest subscription = { 1: list<string> topics = [] } }
```
Compact bytes: `1C | 16 00 | 16 00 | 18 00 | 18 <len> <deviceId> | 18 00 | 1C 19 08 00 | 00 | 00`
(`0x1C`=field1 struct; `0x16`=delta1 i64, value zigzag-varint 0; `0x18`=delta1 binary; `0x19 08` = delta1 list, header size 0 / elem type 8 (binary); stops.) Thrift IDL: `pkg/instameow/thrift/mqttbypass.thrift`.

To send typing: Data frame **without ack** (`SendDataNoAck`, `mqttbypass.go:81`) with `RequestPayload{ publishRequest (field 2): PublishRequest{ 1: binary payload, 2: string mqttTopic = "/ig_send_message" } }`, payload JSON:
```json
{"action":"indicate_activity","activity_status":1,"client_context":"","thread_id":"<thread IGID>"}
```
(`activity_status` 0 to stop.) Compact: `2C 18 <len> <json> 18 10 "/ig_send_message" 00 00`. Incoming frames are `ResponsePayload` and can be ignored (`mqttbypass.go:202-216`). The config comment notes typing costs **2 extra connections per user** (`example-config.yaml` `disable_typing`). Bridge's `client_context` is always empty (Go zero value).

### 5.10 Observed web client (captured 2026-11-12 with `-IGCapture`) — differences from the bridge
Verified against our implementation with `-IGProbeDGW` (both streams subscribe; replayed deltas decode).
* Sockets opened by `/direct/inbox/`: `ws/lightspeed`, `ws/streamcontroller`, `ws/realtime`, `ws/rpsignaling`
  (calls) and the legacy `edge-chat.instagram.com/chat`. Only the first two are needed for DMs.
* Query order is not sorted: `x-dgw-appid, x-dgw-appversion, x-dgw-authtype, x-dgw-version, x-dgw-uuid,
  x-dgw-tier, [x-dgw-loggingid,] x-dgw-deviceid[, x-dgw-app-stream-group]`.
* `x-dgw-uuid` is `PolarisViewer.data.fbid` on **every** gateway socket (also streamcontroller, not `PolarisViewer.id`).
  The typing subscription's `input_data.user_id` is `PolarisViewer.id`.
* `x-dgw-deviceid` / init `device_id` = the page's `IGDMqttWebDeviceID.clientId` (it changes per page load;
  use the same value the inbox query sent as `device_id_for_iris_subscription`).
* Main stream `EstablishStream` params are `{}` (2 bytes), not empty. Init payload keys as in §5.5, with
  `prevalidated_graphql_doc_id` = **29464536269817547** (bridge: 27931342966497053).
* Typing subscription doc id = **28367799366176340**; `x-dgw-app-XRSS-http_referer` = `https://www.instagram.com/direct/inbox/`.
  The web app opens two more streams on the same streamcontroller socket (`GRAPHQL:useFeatureLimitsOffMsysQuery`,
  `PresenceUnifiedJSON` presence reporting); this client doesn't (presence reporting would show the user active).
* Server establish answer: `{"code":200}`; first main data frame: `{"request_id":4,"payload":"<b64 LSResponse>"}`
  with a `subscribe` op (groupID 223).

### 5.11 Activity status ("Active now" / "Active 12m ago") — presence stream
From the web app's `PresenceUnifiedClient`, `IGDDesktopPresenceUnifiedClientSingleton`, `XDTUserDictPresenceInfoResolver`
and `usePresenceUnifiedStatusText` modules (lazy scripts), checked with `-IGProbeDGW` (2026-11-12).
* A stream on the **stream-controller socket** (the web app uses stream 2; we use 1, after typing on 0). EstablishStream params:
  `{"x-dgw-app-XRSS-method":"PresenceUnifiedJSON","x-dgw-app-xrs-body":"true","x-dgw-app-XRS-Accept-Ack":"RSAck","x-dgw-app-XRSS-http_referer":"https://www.instagram.com/direct/inbox/"}`.
* After `{"code":200}`, one Data frame (ack required), Thrift `Payload{2: RequestStreamBody{1: JSON}}` with
  `{"appFamily":3,"pollingMode":1,"appId":"936619743392459","publishEncoding":2}`. The web app adds
  `"presenceReportingRequest":{"capabilities":"268435466","mutationId":<uuid>,"availability":2}` (2 = IDLE; 1 = ACTIVE, 3 = OFFLINE)
  and later amends its own availability. **Not needed to receive presence** (same results with or without), so we don't report.
* Server Data frames: `Payload{5: StreamResponse{2: [delta]}}`; delta `{1: flow_status}` (2 = started) or `{4: {1: JSON}}`:
  `{"publishId","publishType":1 (Full: replace the map) | 2 (Incremental),"presenceUpdates":[{"userId":"<messaging id (EIMU)>",
  "presenceStatus":2 (Active) | 0 (Inactive) | null,"lastActiveTimeSeconds":<unix s>|null,…}]}`. Entries with `userId:"0"` occur; skip them.
  Amend acks arrive as `{6: {1: amendment_id, 2: true}}`.
* Asking for specific people (`addAdditionalContacts`, by messaging id): an amendment Data frame (ack required, ack id = amendment id)
  `Payload{3: AmendStream{1: i64 amendment_id (1, 2, …), 2: JSON}}` with
  `{"payload":{"additionalContacts":{"additionalContacts":["<messaging id>",…]}}}`; the web app repeats it every 2.5 min.
  The answer is an incremental publish.
* Text: "Active now" if any other participant has `presenceStatus == 2`; else, 1:1 only, "Active {relative time} ago" from
  `lastActiveTimeSeconds` if > 0; otherwise nothing. People with activity status off (or not shared with you) never appear.

---

## 6. Parsing deltas (incoming events)

`slidetypes/event.go:188-267`. Each delta object: `__typename`, `uq_seq_id` (string int64), `thread_fbid` (thread IGID; for some messages empty — fall back to `message.thread_fbid`, `handlemeta.go:304-310`), plus type-specific fields:

| `__typename` | Fields | Meaning |
|---|---|---|
| `SlideUQPPNewMessage`, `SlideUQPPNewRavenMessage` (view-once), `SlideUQPPNewGenieMessage` (AI) | `message` (Message §4.6), `thread_read_state_effect` | new message (incl. your own echoes — match by `offline_threading_id`) |
| `SlideUQPPAdminTextMessage` | `message`, `skip_bump_thread` | system/admin message |
| `SlideUQPPCreateReaction` | `message_id`, `reaction{log_message_id,reaction,reaction_timestamp_ms,sender_fbid}`, `reacted_to_message_sender_fbid` | reaction added |
| `SlideUQPPDeleteReaction` | `message_id`, `reaction{…}` — `sender_fbid` may be 0; then look up by `reaction.log_message_id` (store log_message_id→(target msg, sender) from creates and from `Message.reactions`) (`handlemeta.go` handleReactionDelete, `backfill.go:216-229`) | reaction removed |
| `SlideUQPPMarkRead` | `read_timestamp_ms` | *you* read the thread on another device |
| `SlideUQPPIGMarkThreadUnread` | `marked_as_unread` | |
| `SlideUQPPReadReceipt` | `read_receipt{participant_fbid, watermark_timestamp_ms}` | other participant's seen |
| `SlideUQPPEditMessage` | `message_id`, `text_body`, `igd_snippet`, `slide_edit_history_entry{timestamp_ms}` | edit |
| `SlideUQPPDeleteMessage` | `message_id` | unsend |
| `SlideUQPPDeleteThread` | — | thread deleted for you |
| `SlideUQPPUpdateThreadFolder` | `folder` (`PENDING`/`SPAM` = request, `OTHER`…), `ig_inbox_folder` | |
| `SlideUQPPThreadName` | `message`, `thread_name` | |
| `SlideUQPPThreadImage` | `message`, `thread_image{uri}` | |
| `SlideUQPPParticipantLeftGroupThread` | `actor_fbid`, `left_participant_fbid`, `viewer_fbid`, `thread{id,thread_title,input_mode}`, `message` | |
| `SlideUQPPParticipantsAddedToGroupThread` | `message`, `thread{id,thread_title,users[]}` | |
| `SlideUQPPGenericMapAdminsKeyMutation` | `admin_igids[]` | refetch thread |
| `SlideUQPPChangeMuteSettings` | `is_muted_now` | |
| `SlideUQPPPinnedThread` | `is_pinned` | |
| `SlideUQPPPinUnpinMessage` | `pinned_messages[]`, `unpinned_messages[]` | |
| `SlideUQPPNotYetImplementedMutation`, `SlideUQPPNoOpMutation`, `SlideUQPPCreate1To1Thread`, `SlideUQPPUserReachabilityStatus` | — | ignore |
| anything else | — | log & ignore |

Unknown thread? Fetch it with `IGDThreadDetailQuery` (`handlemeta.go:212-258`), except for delete/read/leave/unread events and unpins (`handlemeta.go:290-301`).

Typing is not in this stream (§5.8).

### 6.3 Message content (`message.content.__typename`)
`slidetypes/messagecontent.go:284-329`:

| `__typename` | Fields | How to render |
|---|---|---|
| `SlideMessageText` | `text_body` | text + `mentions` |
| `SlideMessageAdminText` | `is_reaction_action_log`, `text_fragments[{plaintext, link_fragment{uri}}]` | system notice; bridge hides all except `content_type == "IG_VIDEO_CALL_XMAT"` (`from-instagram.go:194-204`) |
| `SlideMessageImageContent` | `attachments[Attachment]` | images |
| `SlideMessageVideosContent` | `videos[Attachment]` | videos |
| `SlideMessageMultiMediaContent` | `ordered_photo_video_attachments[Attachment]` | album |
| `SlideMessageAudiosContent` | `audio_attachments[{attachment_fbid, waveform_data[], playable_duration_ms, attachment_cdn_url}]` | voice note |
| `SlideMessageAnimatedMediaContent` | `animated_media[{preview_cdn_url, alt_text, attachment_webp_url, attachment_mp4_url, preview_width/height, is_sticker}]` | GIF/sticker |
| `SlideMessageRavenImageContent` / `SlideMessageRavenVideoContent` | `view_mode` (0 view-once, 1 allow replay, 2 keep in chat), `attachment` (Attachment or null once viewed) | disappearing media |
| `SlideMessageStoreStickerContent`, `SlideMessageAvatarStickerXMAContent`, `SlideMessageCutoutStickerXMAContent`, `SlideMessageAIStickerXMAContent` | `alt_text`, `preview_url`, `preview_width`, `preview_height` | sticker |
| `SlideMessageXMAContent` | `xma{…}`, `xma_text_body` | shared post/reel/story/link — §7.2 |
| `SlideMessageMusicStickerXMAContent` | `media_content_fbid`, `audio_track{web_30s_preview_download_url,title,display_artist}`, `audio_asset_id`, `attribution_link`, `preview_url` | music |
| `SlideMessageGenAIRichResponseXMAContent` | `unified_response` | AI (schema unconfirmed) |
| `SlideMessageGenAISearchPluginResponseXMAContent` | `messasge_text_body` (sic), `search_sources[]` | AI (unconfirmed) |
| other | — | "unsupported, open Instagram" |

`Attachment` (`messagecontent.go:95-112`): `__typename`, `attachment_fbid`, `attachment_type`, `attachment_cdn_url`, `attachment_cdn_fallback_url`, `preview_cdn_url`, `preview_cdn_fallback_url`, `preview_width`, `preview_height`, `dash_manifest` (videos).

Replies: `replied_to_message_id` + `replied_to_message` (`from-instagram.go:76-84`).

---

## 7. Media in DMs

### 7.1 Direct attachments
URL to download = `attachment_cdn_url`, else `preview_cdn_url` (`from-instagram.go:326-336`); audio: `attachment_cdn_url`; animated: webp if sticker or no mp4, else `attachment_mp4_url`, else `preview_cdn_url` (`from-instagram.go:351-378`). `*_fallback_url` fields exist too. For video you can also use `dash_manifest` for adaptive playback **(inferred)**.

Downloads are plain unauthenticated GETs to fbcdn (`mediadl/download.go:129-163`) with browser-ish headers (`download.go:95-115`): `Accept: image/avif,image/webp,*/*` for images else `*/*`; `Sec-Fetch-Dest: image|video|audio|empty`; `Sec-Fetch-Mode: no-cors`; `Sec-Fetch-Site: cross-site`; UA + `sec-ch-ua*`. Don't send a Referer (comment: "seems to disable redirects"). A `302` to `video.xx.fbcdn.net` → do a `HEAD` and fetch in 1 MiB `Range` chunks (`download.go:148-153, 210-245`). AVPlayer can probably stream directly **(inferred)**.

**CDN URLs expire.** Bridge refresh strategy (`igconnector/directmedia.go:184-300`): re-fetch the message (via `IGDMessageListOffMsysQuery` with `older_than_message_id = <next newer message id>`, or `IGDThreadDetailQuery` if it's the newest) and pick the attachment with the same `attachment_fbid`.

### 7.2 XMA (shared posts, reels, stories, story replies, links)
`messagecontent.go:176-234`, `igconv/from-instagram.go:153-180`, `igconv/xma.go`.
XMA fields: `target_url`, `target_id`, `title_text`, `header_title_text`, `subtitle_text`, `caption_body_text`, `eyebrow_text` (quoted text, e.g. story/"instant" reply), `preview_image{url, fallback_url, width, height}` (or `xmaPreviewImage`), `header_icon{url}`, `cta_buttons[{action_url,cta_type,title}]`, `preview_layout_type`, `verified_type`.
Rules:
* If `xma_text_body` non-empty and (`xma` null or `target_id` empty) → it's a text message with a link preview (unwrap `l.facebook.com/?u=` shims) (`from-instagram.go:154-176`, `xma.go:98-105`).
* Else render preview image + caption (eyebrow quote, bold title truncated to 100 chars, subtitle, caption, link) (`xma.go:61-96`), followed by `xma_text_body` as a separate text part.
* Resolving full media (`xma.go:199-262`):
  * **Story**: `target_url` path starts with `/stories/` and last path component is numeric → `mediaID = last component`, `reelID = ?reel_id=` → `POST /api/v1/feed/reels_media/` (§8.3) and pick item with `pk == mediaID` (`xma.go:314-345`).
  * **Post/reel**: `target_id` numeric → shortcode from `target_url` path regex `/(?:reel|p)/([a-zA-Z0-9_-]+)/?`, optional `?carousel_share_child_media_id=` → `GET /api/v1/media/<target_id>/info/` (§8.2); pick `items[0]` (or the carousel child whose `id` contains the child id) (`xma.go:347-382`).
  * Best playable URL: largest `video_versions[].url` by width×height; else largest `image_versions2.candidates[].url` (`xma.go:384-412`).
  * Bridge by default does **not** fetch XMA media during backfill (`disable_xma_backfill: true`) — it's extra API traffic; do it lazily on view.

### 7.3 Sending images/video/audio/files (web path)
Step 1 — upload: `POST https://www.instagram.com/ajax/mercury/upload.php?<query>` (`endpoints/instagram.go:41`, `httpclient/mercury.go:65-112`).
* Query string = the same `NewHTTPQuery()` fields as §3 (`__a`, `__user`, `__req`, `__hs`, `dpr`, `__ccg`, `__rev`, `__s`, `__hsi`, `__dyn`, `__csr`, `__comet_req`, `fb_dtsg`, `jazoest`, `lsd`, `__spin_*`, `__d=www`, `__jssesw=1`) — here `__jssesw=1` *is* sent since it isn't overridden.
* Headers: §3 headers (with x-csrftoken etc.), plus `accept: */*`, `origin: https://www.instagram.com`, `referer: https://www.instagram.com/direct/t/<thread_key>/`, `priority: u=1, i`, `sec-fetch-dest: empty`, `sec-fetch-mode: cors`, `sec-fetch-site: same-origin` ("header is required").
* Body: `multipart/form-data; boundary=----WebKitFormBoundary<16 random alnum>`. For voice: field `voice_clip=true` and optionally `voice_clip_waveform_data={"amplitudes":[0..1 floats],"sampling_frequency":9}`. File part: `Content-Disposition: form-data; name="farr"; filename="<name>"`, `Content-Type: <mime>` (`mercury.go:175-223`, `mediadl/upload.go:55-65`).
* Response (strip `for (;;);`): `{"payload":{"uploadID":…,"metadata": …}, "error":…, "redirect":…}`. `metadata` is an **array** `[{"image_id":…,"filename","filetype","src","fbid"}]` for images, or an **object** `{"0":{"video_id"|"audio_id"|"file_id"|"gif_id":…}}` for video etc. IDs may be string or number. Attachment ID = first non-zero of `video_id, audio_id, image_id, gif_id, file_id` (`types/mercury.go:45-99`, `mercury.go:146-172`). `redirect` containing `/consent/` → consent required. Non-zero `error` → error (1357004 → reload page & retry once, `igconv/from-matrix.go:100-113`). Retries ≤5 with 3 s·n backoff (`mercury.go:73-111`).
* Known issue: some accounts can't upload **video** via web (fbid 0). Fallback uses the Android rupload host with a cookie-derived bearer token (`mediadl/upload.go:98-106, 113-167`): `POST https://rupload.facebook.com/messenger_video/<uploadID>` with `authorization: Bearer IGT:2:<base64({"ds_user_id":…,"sessionid":…})>` (`mercury.go:43-49`), Android UA, `ig-intended-user-id`, `ig-u-ds-user-id`, `ig-u-rur`, `x-entity-*`, `video_type: FILE_ATTACHMENT`, etc. — response `{"media_id":…}`. This impersonates the Android app with web cookies; risky, use only if needed.

Step 2 — send: `IGDirectMediaSendMutation` (`requests.go:44-51`, `from-matrix.go:90-118`):
```json
{"attachment_fbid":"<id from upload>", "thread_id":"<thread IGID>",
 "offline_threading_id":"<OTID>", "reply_to_message_id":"<Message.id or null>",
 "forwarded_from_thread_id":null, "is_forwarded_from_own_message":null}
```
Response `data.xig_direct_media_send_with_slide_messaging_response = {message_id, timestamp_ms, id}` (`message.go:175-179`). Requires a known thread IGID (no recipient-based variant).

---

## 8. Sending — exact payloads

All via §3 GraphQL. OTID per §1.

### 8.1 Text / reply / mentions — `IGDirectTextSendMutation`
`requests.go:23-42`, `from-matrix.go:68-89`:
```json
{"ig_thread_igid":"<thread IGID>",            // or null when using recipient_igids
 "offline_threading_id":"<OTID>",
 "recipient_igids":null,                      // new 1:1 without thread: ["<target>"] (see below)
 "replied_to_client_context":null,
 "replied_to_item_id":null,
 "reply_to_message_id":"<Message.id>"|null,
 "sampled":null,
 "text":{"sensitive_string_value":"hello"},
 "mentions":[{"offset":0,"length":5,"fbid":"<user FBID>"}]|null,
 "mentioned_user_ids":["<user FBID>"]|null,
 "commands":[{"offset":0,"length":9,"type":"EVERYONE","user_or_thread_fbid":"<thread id>"}]|null,
 "forwarded_from_thread_id":null,
 "is_forwarded_from_own_message":null,
 "send_attribution":"igd_web_chat_tab:in_thread"}
```
(Go marshals nil slices as `null`.) Response: `data.xig_direct_text_send_with_slide_messaging_response = {message_id, timestamp_ms, id}`. The echo also arrives via the socket as `SlideUQPPNewMessage` with the same `offline_threading_id`.
New DM with no existing thread: bridge sets `recipient_igids = ["<thread_key>"]` i.e. the target user's **messaging FBID** with a `TODO should this be actual IG user IDs?` (`from-matrix.go:80-85`). Prefer first resolving via `/ajax/navigation/` (§8.10) or `useIGDCreateOptimisticThreadUserQuery`.

### 8.2 Reaction — `IGDirectReactionSendMutation`
`requests.go:139-156`, `handlematrix.go:201-256`:
```json
{"input":{"emoji":"❤","item_id":"","message_id":"<Message.id>","reaction_status":"created","thread_id":"<thread IGID>"}}
```
`reaction_status: "deleted"` to remove (pass the previous emoji). One reaction per user per message (`MaxReactions: 1`, `handlematrix.go:192-199`); strip emoji variation selectors (`handlematrix.go:196`). Response `data.xig_direct_reaction_send_with_slide_messaging_response = {id, reactions[]}`.

### 8.3 Mark read — two mutations in sequence
`handlematrix.go:307-359`, `requests.go:66-77`, `thread.go:119-122`:
1. `useIGDMarkThreadAsReadMutation`:
```json
{"metadata":{"ig_thread_igid":"<LONG thread_id>"},"data":{"message_id":"<Message.id>","item_id":""}}
```
   → `data.xig_direct_item_seen_mutation_with_slide_messaging_response = {participant_fbid, watermark_timestamp_ms}`
2. `useIGDMarkThreadAsReadValidationMutation` (no reload/retry):
```json
{"metadata":{"ig_thread_igid":"<LONG thread_id>"},"data":{"message_id":"<Message.id>","message_timestamp_ms":"<ms as string>"}}
```
   → `data.xig_direct_mark_read_id_validation: true`
Note it's the **long** thread ID here.

### 8.4 Typing — §5.9.

### 8.5 Unsend — `IGDMessageUnsendDialogOffMsysMutation`
```json
{"message_id":"<Message.id>","send_data":{"thread_id":"<LONG thread_id>"}}
```
→ `data.direct_unsend_message: true` (`requests.go:61-64`, `handlematrix.go:286-305`).

### 8.6 Edit — `IGDirectEditMessageMutation`
```json
{"thread_id":"<thread IGID>","target_item_id":"","body":{"sensitive_string_value":"new"},"offline_threading_id":"<OTID>","target_message_id":"<Message.id>"}
```
(`requests.go:53-59`, `handlematrix.go:258-284`).

### 8.7 Thread management
* Accept request: `{"thread_fbid":"<IGID>","ig_inbox_folder":null,"offline_threading_id":"<OTID>"}` (`requests.go:116-120`).
* Delete/hide: `{"thread_fbid":"<IGID>","should_move_future_requests_to_spam":false}` (`requests.go:79-82`).
* Mute: `{"thread_fbid":"<IGID>","mute_seconds":-1|0|N,"offline_threading_id":"<OTID>"}` (-1 forever, 0 unmute; `requests.go:122-126`).
* Pin thread: `{"thread_fbid":"<IGID>","pin":true}`; pin message `{"thread_fbid","message_id","should_replace_oldest_pin"?}`.
* Leave: `{"thread_fbid":"<IGID>"}`; remove member `{"thread_fbid","user_igid"}`; add members `{"thread_fbid","user_igids":[…],<3 relay providers as in requests.go:93-109>}`; admins `{"thread_fbid","user_igids"}`; rename `{"thread_fbid","new_title"}` (`graphql/docs.go:232-235`).
* Create group: `{"recipient_eimu_fbids":["<FBID>",…],"offline_threading_id":"<OTID>","entry_point":null}` → `data.xig_ig_direct_create_thread.{id, as_ig_direct_thread}` (`requests.go:259-263`, `responses.go:161-166`).
* Block: `{"target_user_id":"<user IGID>","surface":"direct_thread_info"}` / unblock `{"target_user_id":…}` (`graphql.go:158-177`).
* Group avatar uses Android rupload + `i.instagram.com/graphql_www` with Bearer IGT — skip (`instameow/android.go:39-167`).

### 8.8 Search / user lookup
* `IGDOmniPickerSearchResultsListQuery` `{"search_text":"…"}` → `data.xfb_combinedIGSearchQuery.search_messenger_contact_v2[{interop_messaging_user_fbid, username, full_name, pk, profile_pic_url, is_verified}]` (`responses.go:155-159`, `user.go:44-51`).
* `useIGDCreateOptimisticThreadUserQuery` `{"messaging_user_fbid":"<FBID>"}` → `data.xig_user_from_messaging_user_fbid` (User).
* `PolarisProfilePageContentQuery` `{"enable_integrity_filters":true,"id":"<user IGID>", "__relay_internal__pv__PolarisCannesGuardianExperienceEnabledrelayprovider":true, "__relay_internal__pv__PolarisCASB976ProfileEnabledrelayprovider":false, "__relay_internal__pv__PolarisWebSchoolsEnabledrelayprovider":false, "__relay_internal__pv__PolarisRepostsConsumptionEnabledrelayprovider":true}` (`requests.go:235-253`).

### 8.9 Sharing a post/reel into a thread
**Not implemented by the bridge.** Options **(inferred)**: (a) send the post URL as text (`https://www.instagram.com/p/<shortcode>/`) — IG renders a link preview XMA; (b) capture the real web client's share mutation (look in DevTools for a `fb_api_req_friendly_name` like `…Share…Mutation` when using "Send to" on a post) and add it to the doc table.

### 8.10 Thread ID resolution — `POST /ajax/navigation/`
`instameow/route.go:54-107`. Form = §3 query fields plus `route_url=/direct/t/<thread_key>/`, `routing_namespace=<envjson routing_namespace>`, `__crn=comet.igweb.PolarisDirectInboxRoute`, `client_previous_actor_id=<PolarisViewer.data.fbid>`. Headers §3 + `origin`, `referer: https://www.instagram.com/direct/t/<thread_key>/`, `priority: u=1, i`, `sec-fetch-*` cors/same-origin. Strip `for (;;);`; read `payload.payload.result.exports.rootView.props = {"thread_igid": <LONG id>, "thread_fbid": <IGID>}`. 404 / missing props → thread doesn't exist yet.

---

## 9. Other REST endpoints usable with a web session

| Endpoint | Method | Purpose | Notes |
|---|---|---|---|
| `https://www.instagram.com/api/v1/media/<media_id>/info/` | GET | resolve shared post/reel (`misc.go:79-110`) | Headers: §3 set + `x-requested-with: XMLHttpRequest`, `referer: https://www.instagram.com/p/<shortcode>/` (or base URL), `sec-fetch-*` cors/same-origin, `X-Web-Session-ID: <__s value>`. Response `{items:[{pk,id,video_versions[{width,height,url}],image_versions2{candidates[{width,height,url}]},carousel_media[…]}]}` (`responses/media.go`). |
| `https://www.instagram.com/api/v1/feed/reels_media/` | POST form | resolve shared story (`misc.go:112-149`) | form `reel_ids=["<reelID>"]` (JSON array), `media_id=<id>`, `fb_dtsg`, `jazoest`; extra header `x-instagram-ajax: <rollout_hash>`. Response `{reels:{"<reelID>":{items:[…]}}}` (`responses/reel.go:8-12`). |
| `https://www.instagram.com/api/v1/web/push/register/` | POST form | Web push (VAPID) registration (`misc.go:32-77`) | `device_token=<push endpoint>`, `device_type=web_vapid`, `mid`, `subscription_keys={"p256dh","auth"}`, `jazoest`, `fb_dtsg`; header `x-requested-with`. Not useful for a native app unless you run a Web Push receiver. |
| `https://www.instagram.com/api/v1/users/web_profile_info/?` | defined (`endpoints/instagram.go:49`) but unused by instameow. |

Required API headers (from `addInstagramHeaders`, `http.go:729-748`): `x-csrftoken` (= `csrftoken` cookie), `x-ig-app-id` (= `CurrentUserInitialData.APP_ID`, normally `936619743392459` — that's the hard-coded fallback in `httpclient/configs.go:56-60`), `x-ig-www-claim` (if received), `x-mid`, `X-IG-Max-Touch-Points: 0`, `x-asbd-id: 359341`, `x-fb-lsd`.

---

## 10. Errors, logout, rate limits, anti-flag measures

* **Logged out**: `sessionid`/`xs` deleted via Set-Cookie; redirect to `/login.php` (`http.go:498-506`); DGW close 4003 or Deauth frame (`dgw/socket.go:188-192, 400-404`); GraphQL `error: 1357001`.
* **Challenge/checkpoint/suspended/consent**: redirects (§2.2) — bridge stops and asks the user to open `https://www.instagram.com/` (`igconnector/client.go:192-252`). In your app: show the WKWebView at the redirect URL.
* **Account restricted**: `error: 1357031` ("content unavailable") → reload the inbox page to surface notices, at most every 8 h (`graphql.go:181-199, 226-227`).
* **Please reload**: `error: 1357004` → refetch HTML config (≤ once per 15 min) and retry once (`graphql.go:228-240`).
* `error: 1357053` during bootstrap → treated as bad credentials (`igconnector/client.go:328-330`).
* **HTTP**: 429 → `ErrRateLimited`, considered permanent (no retry except via new proxy) (`http.go:413, 452-460, 557-564, 647-649`); 5xx/network errors retried up to 5× with `3 s × attempt` backoff (×2 for 429) (`http.go:531-599`); other 4xx not retried.
* **Anti-flag behaviors** in the bridge:
  * Browser impersonation: consistent UA + `sec-ch-*` + Chrome TLS fingerprint; websocket forced to HTTP/1.1 (`http.go:153-221`).
  * Reuses the page's `IGDMqttWebDeviceID` and DGW app id rather than inventing values.
  * Throttles page reloads (5/15 min), account-notice checks (8 h), thread-list paging (2 s/batch, 5 threads per page), caps concurrent backfills; XMA fetch disabled in backfill by default.
  * Persists seq ID so restarts resume instead of re-snapshotting; full refresh only every 20 h.
  * Optional per-user proxy, rotated on 429/network errors (`igconnector/client.go:97-137, 267-276`).
  * Recommendation **(inferred)**: since your cookies came from WKWebView (Safari engine), send Safari's UA and *omit* `sec-ch-ua*` headers; keep one consistent identity; never run the inbox page fetch or GraphQL in tight loops.

---

## 11. Recommended implementation order (first working version)

| # | Piece | Notes | Complexity |
|---|---|---|---|
| 1 | Cookie jar + header builder | manual Cookie header, Set-Cookie updates incl. raw `rur`, www-claim, redirect classification | S (½–1 day) |
| 2 | Inbox page bootstrap parser | fetch `/direct/inbox/`, find JSON script tags, walk `ScheduledServerJS → __bbox.define`, extract ~9 configs + `__eqmc` + `envjson`. Skip `__dyn/__csr` initially. | M (1–2 days; HTML is large ~1–3 MB, use a regex/lightweight scan for `<script…>…</script>` instead of a full HTML parser) |
| 3 | GraphQL client | form builder, headers, `for (;;);` strip, error envelope, 1357004 retry | S (1 day) |
| 4 | Inbox + thread detail + message paging | `PolarisDirectInboxQuery`, `IGDThreadDetailQuery`, `IGDMessageListOffMsysQuery`, Codable models for ThreadInfo/User/Message/content union | M (2–3 days; content union decoding is the bulk) |
| 5 | Send text/reply, react, mark-read, unsend | 4 mutations, ID bookkeeping (IGID vs long ID vs key) | S (1 day) |
| 6 | DGW websocket + main stream | frame codec, ping/pong/ack, establish stream, JSON connect payload, base64 → protobuf `LSResponse` mini-decoder, delta JSON dispatch, seq ID persistence, reconnect/resnapshot | M–L (3–5 days) |
| 7 | Media download + XMA rendering | CDN fetch, expiry refresh, `media/<id>/info`, `reels_media` | M (2 days) |
| 8 | Image upload + send | multipart to `ajax/mercury/upload.php`, `IGDirectMediaSendMutation` | S–M (1–2 days) |
| 9 | Typing receive (streamcontroller) | second socket + Thrift compact encoder/decoder | M (2 days) |
| 10 | Typing send (mqttbypass) | third socket, reuse Thrift encoder | S (½ day after #9) |
| 11 | Thread paging, requests folder, groups admin, search | | S–M |

Minimal "it works" milestone = 1–6 (+5): ~1.5–2 weeks for one developer **(estimate)**.

---

## 12. Biggest risks

1. **doc_id rot**: every GraphQL `doc_id` (§3.1) and the delta-processor doc id in the socket payload (`27931342966497053`) are tied to Instagram's current web bundle. When IG redeploys they can start failing (`error` / "please reload" / unknown doc). The bridge hard-codes them and ships updates. Plan for a remote-updatable doc_id table, or scrape them from the JS bundles (look for `__d("<Name>_instagramRelayOperation",…,e.exports="<id>")` **(inferred)**).
2. **Relay provider variables** (`__relay_internal__pv__…`) must match the doc's expectations exactly; a mismatch yields GraphQL errors.
3. **ID confusion** (IGID vs long thread ID vs thread key vs user IGID vs messaging FBID) — §1.
4. **Fingerprint consistency**: mixing a Chrome UA with Apple's TLS stack/Safari-captured cookies may increase checkpoint risk (inferred).
5. **Delta schema drift**: unknown `__typename`s must be tolerated (bridge logs and ignores them).
6. **Video upload** may fail on some accounts via web (bridge falls back to Android rupload).
