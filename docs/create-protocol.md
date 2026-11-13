# Posting, editing and deleting — what instagram.com sends

Written from recordings of instagram.com (2026-11-12/13: a photo post, a carousel, a reel, a
photo story in phone mode, caption edits, post and story deletes, the commenting toggle) and
from the web app's scripts (`PolarisCreationAPI`, `PolarisCreationV2Actions`,
`PolarisAPIRuploadPhoto`, `PolarisAPIRuploadVideo`, `polarisResumableVideoUpload`,
`polarisConfigureToClipsRetry`, `PolarisStoryCreationActions`, `PolarisAPICreationFinalizeStory`,
`PolarisAPIDeletePost`, `PolarisPostActionEditPost`). Code: `Instagram/API/Endpoints+Create.swift`.
**R** = recorded, **S** = read from the scripts (not recorded).

## Uploads (`i.instagram.com`, raw bytes)

- Upload id: `Date.now()` in ms, kept increasing (`createUploadId`). Entity name
  `fb_uploader_<upload id>` (**R**); a story video uses `story_<id>` (**S**).
- Headers on every rupload POST (**R**): `Accept: */*`, `Offset`, `X-ASBD-ID`,
  `X-Entity-Length` (whole file), `X-Entity-Name`, `X-Entity-Type` (photos only, `image/jpeg`),
  `X-IG-App-ID`, `X-IG-Max-Touch-Points`, `X-Instagram-AJAX` (build), `X-Instagram-Rupload-Params`,
  `X-Web-Session-ID`. No CSRF token, no www-claim (`omitHeaders`). Cookies go along.
- Photo params (**R**, key order kept): `{"media_type":1,"upload_id":"…","upload_media_height":H,
  "upload_media_width":W,"provenance_metadata":"{\"origin\":[\"EXTERNAL\"]}"}`. A video's cover is
  the same with `media_type` 2 and the **video's** size, same entity name as the video (**R**).
- Reel video params (**R**): `client-passthrough "1"`, `is_clips_video "1"`, `for_album false`,
  `is_sidecar "0"`, `media_type 2`, `upload_id`, `upload_media_duration_ms`, height, width,
  `video_format ""` (the web app wraps the file in a typeless `File`), `video_transform null`,
  `provenance_metadata`.
- Reel video transfer (**R** for one piece, **S** for the loop): `GET rupload_igvideo/<entity>`
  → `{"offset":N}`, then POST 10,000,000 bytes from `Offset: N`; repeat until done. Network
  failures retry 10× at 30 s. Response `{"media_id":…,"status":"ok"}`.
- Photo uploads retry a 429/500 after 2, 4 … 64 s (`polarisWithExponentialBackoff`, **S**).
- Story video (**S** only — the web app's story picker refuses videos): params with
  `is_unified_video "0"`, `for_album true`, `video_format "video/mp4"`; one POST, no offset GET;
  cover (frame at 1 s) as a `media_type 2` photo under the same `story_<id>` entity.

## Publishing

| What | Request | Body |
|---|---|---|
| Photo post (**R**) | `POST /api/v1/media/configure/`, REST headers | form: `archive_only=false`, `caption`, `clips_share_preview_to_feed=1`, `disable_comments=0/1`, `disable_oa_reuse=false`, `like_and_view_counts_disabled=0/1`, `media_share_flow=creation_flow`, `source_type=library`, `upload_id`, `video_subtitles_enabled=0`, `fb_dtsg`, `jazoest` |
| Carousel (**R**) | `POST /api/v1/media/configure_sidecar/`, REST headers | JSON, in order: `archive_only` (bool), `caption`, `children_metadata` `[{upload_id}]`, `client_sidecar_id` (ms), `disable_comments` ("0"/"1"), `like_and_view_counts_disabled` (0/1 number), `media_share_flow`, `source_type`, `jazoest`, `fb_dtsg` |
| Reel (**R**) | `POST /api/v1/media/configure_to_clips/` via `cometAsyncFetch` | form: page fields (`__a`, `__comet_req`, `__crn=comet.igweb.PolarisFeedRoute`, `__req`, `__rev`, `__s`, `__spin_*`, `dpr`, `fb_dtsg`, `jazoest`, `lsd`, no `av`), `qpl_active_flow_ids=379199405`, the photo-post fields, and `signed_body=SIGNATURE.<the same fields as JSON>`. Headers: `X-FB-LSD`, `X-IG-D: www`, `X-FB-Entry-Nonce`, `X-FB-QPL-Active-Flows`, plus CSRF, app id, www-claim, AJAX, web session id (no `X-Requested-With`). |
| Photo story (**R**, phone mode) | `POST /api/v1/media/configure_to_story/` with the phone app id (1217981644879628), 5 touch points, iPhone browser | form: `caption=""`, `configure_mode=1`, `share_to_facebook=""`, `share_to_fb_destination_id=""`, `share_to_fb_destination_type=USER`, `upload_id`, tokens |
| Video story (**S**) | same endpoint and headers | form: `configure_mode=1`, `upload_id`, tokens |

- Reel publish answers `for (;;);{"payload":{"statusCode":202}}` while the video is processed
  (**R**: first attempt 202, second ~9 s later returned the media). Rule
  (`polarisConfigureToClipsRetry`, **S**): 202 → ask again after min(3 s·2ⁿ, 64 s), at most 20
  times; a 5xx → after min(1 s·2ⁿ, 8 s), at most 10 times.
- The web app uploads a photo unchanged if it wasn't cropped or filtered, else the canvas as
  JPEG (`toBlob("image/jpeg")`, 0.92). Matte always re-encodes: crop, at most 1080 wide, JPEG
  0.92; videos re-encoded H.264/AAC MP4 at most 1080 wide (the web app uploads the file as is).
- Limits (`PolarisCreationConstants`/`PolarisMediaConstants`): files 5 KB–1 GB, video 1 s–1200 s
  (reels), up to 20 carousel items, photo aspect 3:4…1.91:1, caption 2,200 characters.

## Scheduling (professional accounts, Manager mode)

Recorded 2026-11-13 on a professional account: scheduling a photo, the scheduled list, cancelling.
Instagram holds the post and publishes it itself (Matte needn't be running).

| What | Request | Body |
|---|---|---|
| Scheduled photo (**R**) | `POST /api/v1/media/configure/` (as a photo post) | the photo-post form plus `async_publish=1`, `content_scheduling_metadata={"scheduled_publish_time":"<unix s>"}` (a JSON string, the time as a string), `publish_mode=scheduled` |
| List (**R**) | GraphQL `PolarisScheduledContentCalendarQuery` (doc 28886777017638780), variables `{}` | `data.viewer.xdt_user.all_scheduled_ig_content[]`: `id` (the scheduled item), `scheduled_publish_time`, `caption_text`, `carousel_children`, `media{id, product_type, image_versions2}` |
| Cancel (**R**) | GraphQL `PolarisScheduledContentMutationsDeleteMutation` (doc 26836322409389162) | `input: {actor_id, client_mutation_id, scheduled_content_id}` → `xig_delete_scheduled_ig_content.deleted_id` |

- The web app sends both GraphQL requests to `/api/graphql`; Matte's `/graphql/query` works for them too.
- The configure response has the media `is_in_profile_grid: false`, `integrity_review_decision: pending`.
- Carousel and reel scheduling aren't recorded yet: Matte refuses them (only a single photo can be scheduled).
- Window offered in Matte: 15 minutes to 75 days ahead, on 5-minute marks (`IGClient.scheduleWindow`).

## Your posts

- Caption (**R**): `POST /api/v1/media/<pk>/edit_media/`, JSON `{"caption_text":…,
  "coauthor_invites":"{\"added\":[],\"in\":[],\"removed\":[]}","usertags":"{\"added\":[],\"in\":[],\"removed\":[]}",
  "jazoest":…,"fb_dtsg":…}`. The web app sends `usertags` only when tags changed; Matte sends the
  empty one only for posts without tags.
- Delete post or reel (**R**): `POST /api/v1/web/create/<pk>/delete/` via `cometAsyncFetch`,
  form = page fields only, `__crn=comet.igweb.PolarisProfilePostsTabRoute`; headers `X-ASBD-ID`,
  `X-FB-LSD`, `X-IG-D`, `X-FB-Entry-Nonce` (no CSRF/app id). Answer `payload.did_delete`.
- Turn commenting on (**R**): `PolarisPostFastOptionToggleCommentingLegacyEnableMutation`
  (doc 28230802399856833), `input {actor_id, client_mutation_id, media_id}`, route
  `PolarisProfilePostsTabRoute`. Turning it **off** was never recorded and its mutation isn't in
  any script Matte has seen; Matte uses `…LegacyDisableMutation` only if its doc id turns up.
- Delete story (**R**): `usePolarisStoriesV3DeleteMediaMutation` (doc 27648950741394648),
  variables `{"mediaId":"<pk>"}`, route `PolarisStoriesV3Route`.
- Seen but not used: `PolarisCreationEditRootQuery` (the edit dialog reads the post first),
  `PolarisPostOptionToggleProfileGridVisibilityRemoveMutation` (hide from grid),
  `useIGCreateNoncesMutation` (one-tap login nonces, unrelated to posting).

## Story editor (Matte's own)

Instagram edits nothing server-side: a story is one finished photo or video. instagram.com's
web story flow takes a photo as is (phone mode only) and has no editor. Matte's editor
(`Instagram/StoryEditor/`) flattens everything on its 9:16 canvas and uploads the result
through the unchanged story path above (`CreateModel.shareFinishedStory` → `uploadPhoto`, or
`uploadStoryVideo` + cover, then `configure_to_story`). Only the file differs:

- Photo: 1080×1920 JPEG at the create flow's quality (0.92). The background is decoded only as
  large as the canvas shows it.
- Video: 1080×1920 H.264 MP4, AAC sound unless muted (muted = no audio track), the trimmed part
  only (1 s to 60 s, `CreateMedia.maxStorySeconds`), cover = the frame at 1 s (as before).
  Frames are drawn by a Core Image video composition with the same recipe as the photo
  (gradient, placed and filtered picture, overlay). `AVVideoCompositionCoreAnimationTool` is
  ignored by Core Image compositions (tried), so the overlay is composited in that pass.
- Around a picture that isn't 9:16: a top-to-bottom gradient of its dominant colours, as
  Instagram fills it. Filters are colour-only, so the screen-size preview matches the export.
- Dry run (`-IGProbeCreate`, "story editor photo/video"): the same requests, headers, rupload
  params and form fields as "story photo/video", with 1080×1920 sizes.

## Post or reel to your story (Matte)

**Update 2026-11-13:** instagram.com's `configure_to_story` accepts these fields but drops the
sticker (Matte's stories came back with `story_feed_media: null`; the ones shared from the phone
have it). So this one publish goes to the phone app's endpoint instead
(`API/Endpoints+PhoneStory.swift`, from instagrapi `login_by_sessionid` + `photo_configure_to_story`):
`POST https://i.instagram.com/api/v1/media/configure_to_story/`, `signed_body=SIGNATURE.<json>`,
`Authorization: Bearer IGT:2:<base64 {ds_user_id, sessionid, should_use_header_over_cookies}>`, Android
UA 449.0.0.52.84, app id 567067343352427, device ids derived once from the account id. Ephemeral
URLSession (its cookies never reach the web session); any failure falls back to the web publish
with a toast, and never signs out. The upload is unchanged (rupload, web).


instagram.com can't do this (only the phone app), so nothing could be recorded. Written from
instagrapi's `photo_configure_to_story` (`medias`), **unverified until the user tries it**:
the photo story form above plus `reshared_media_id=<pk>` and
`tap_models=[{"x","y","z":0,"width","height","rotation":0.0,"type":"feed_media","media_id","media_owner_id",
"product_type":"feed","is_sticker":true,"tap_state":0,"tap_state_str_id":"feed_post_sticker_square"}]`
(x/y = the sticker's centre, width/height = its size, all as fractions of the story).
The card (author + picture, `StoryEditor/StoryReshare.swift`) is the editor's picture, so moving or
zooming it moves the tap area with it (`StoryEditorModel.placedReshare`). Entry: "Add to story" in
the Send to… sheet. Debug: `-IGAddToStory YES [-IGStoryShare YES -IGDryRunWrites <dir>]`.

Background sharing: Share in the sheet or the story editor closes it and hands the work to an
`UploadJob` (`Create/Uploads.swift`), shown as a ring in the window's bottom-right corner.
