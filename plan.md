# Groovy Camera — Build Plan

Based on `groovy-camera-spec.md` (Nov 4, 2026). Status: **approved with review changes included. Ready to start M0.**

## 1. Approach

- Native SwiftUI app with no third-party Swift dependencies, as the spec's §9 lays out. **The app is the whole product:** it talks directly to R2, with no Worker or other server to deploy.
- Build in the spec's milestone order, with one addition: a **Milestone 0 device spike**, because the riskiest assumptions are about camera behavior and can't be tested in the simulator.
- Keep the image pipeline, naming and upload logic independent of the camera, so they can be tested on saved photos instead of a phone over a table.

**Environment checked on this Mac:** Xcode 27.2 (iOS 27.2 SDK), XcodeGen, an Apple Development signing identity, and a paired iPhone 17 Pro.

## 2. Decisions and changes from the spec

These are places where the spec conflicts with itself or with how the platform works, or where you've chosen something different.

### Decided

- **No Worker: the app uploads directly to R2.** The app holds an R2 API token limited to this one bucket, with object read/write only and no admin rights. You enter it in Settings, and it's stored in the Keychain as available after first unlock, this device only, so it never syncs or transfers to another phone. It signs its own upload URLs on the phone and hands them to iOS as background uploads, which go out when a connection returns. *This replaces the Worker and token in spec §7, §8 and §9.* The accepted tradeoff is a key on the phone. Object read/write still includes delete, which rename needs, so a compromised phone could read, overwrite or delete anything in that bucket, but nothing else. The README checklist covers revoking and rotating it.
- **No folder link and no gallery.** The goal is simple: photos land in R2, and you pull them down to your laptop or build a CSV there. *This removes "copy its folder link" from spec §8.* The Library is only for checking and fixing records on the phone, and it shows **thumbnails only**.
- **Laptop access isn't part of this build.** Downloads and CSVs use existing tools (the R2 dashboard, `rclone`, or `wrangler`). Photo URLs follow a fixed pattern, `https://<domain>/records/<folder>/<file>`, so a CSV can be built from a file listing.
- **The phone sits on a tripod at a fixed height of roughly 30 cm.** It can't be raised, so the main lens can't fit a sleeve plus margin. We're **trying the ultra-wide** with Apple's distortion correction on, replacing the earlier main-camera decision. You line records up with guides and press the shutter, with a level for setup. **No auto-capture and no live outline.**
- **12 MP capture, 2048 × 2048 output,** the size eBay and Shopify want. Gatefold stays 4096 × 2048 for now.
- **White is set once.** You tap **Set White** on the empty table, and the app locks white balance and exposure (white at 90–95%) and keeps them across launches until you set them again. Nothing adjusts live or per photo. *This replaces the live sampling, lock on first shot and per-photo correction in the original spec §4.* The first device test showed why: the sleeve fills so much of the frame that the "white margin" was often the record itself, so dark sleeves blew out and cream sleeves turned the background blue.
- **Discard session is added.** The camera screen gets a **Discard session** action, shown once the session has a photo and protected by a confirmation. It deletes that session's photos from the phone, stops any processing and naming still running, and opens a new session. Set White isn't affected. Uploads start only at Done (D2), so there's nothing to remove from R2. *This is an addition to spec §2 and §8.* It only covers the open session: the Library still has no delete, so anything already finished stays in R2 until you remove it there.
- **Done shows the final name.** After Done, a short toast shows the record's final name, once naming has finished. Tapping it fixes the name. Uploads for that record start when the toast ends, a few seconds after Done, so a fix made here is a local change with no R2 copy and delete. The toast doesn't block the next record, and it never holds uploads if the app is closed or the toast can't be shown.
- **Setup is ready:** paid Apple Developer account, domain on Cloudflare, R2 enabled, iPhone 17 Pro (currently on iOS 26.6). The app targets **iOS 26 or newer**, which includes Apple's on-device language model.

### Approved defaults

| # | Spec gap | Default |
| --- | --- | --- |
| D1 | §3 says the viewfinder "shows exactly what will be saved", but autocrop removes the visible background. | The viewfinder shows the framing. The thumbnail shows the final crop. |
| D2 | §2 says uploads "continue" after Done, but the folder name can change until then. | Uploads **start at Done**, once the name is final and its toast has ended. That means retakes never overwrite a live URL or leave a stale cached copy. |
| D3 | The spec locks white balance but doesn't mention exposure. A black sleeve and a white sleeve would meter differently, which breaks the "consistent look" goal. | Set White also sets exposure, so the white table sits at roughly **90–95% brightness**, never at clipping, and pale sleeves keep their edge. **Focus** locks on the first shot. Also turn off as much per-shot processing as the API allows. The white corners of disc shots stay at that brightness rather than pure white. M0 will show whether that looks right. |
| D4 | Vision rectangle detection (§9) can't find discs. | Find the disc by contour detection plus a circle fit. A dark disc on white should be an easy case. |
| D5 | R2 has no rename, and renaming changes the URLs of links already pasted into listings. | Kept simple, since renames after upload should be rare. The app copies each photo to the new name, then deletes the old one, with a pending flag so it finishes if interrupted. It runs only while the app is open. Rename is unavailable while that record still has uploads in progress. The rename screen warns that old links will stop working. |
| D6 | A phone lying flat reports no useful orientation, so photos could be saved rotated. | The app is portrait-locked and ignores device orientation. "Up" on the record is the top of the phone. A square sleeve is straightened by the smallest rotation, so it won't flip 90°. |
| D7 | Force-quitting an app makes iOS cancel its background uploads, which the spec's "app closed" wording doesn't allow for. | Uploads survive the app being suspended or closed by the system, and offline periods. After a force-quit they resume on next launch. |
| D8 | The app is killed mid-session. | Reopening resumes that session if it has any photos. |
| D9 | The Library needs images after local copies are cleared. | Keep a small thumbnail of every photo on the phone permanently, and show only those in the Library. The app never loads images from the domain or needs to know it. |
| D11 | The default for "keep local copies for N days" isn't given. | 0 days: clear once the upload is confirmed. |
| D12 | Slug rules for special characters aren't given. | `Björk` → `bjork`, `AC/DC` → `ac-dc`, `&` → `and`. Non-Latin names are transliterated. If the result is empty, the record uses the `untitled-…` form. |
| D13 | Reinstalling the app wipes local records, so a new record could reuse a name and overwrite old photos. | On launch, when online, list existing folder names in the bucket and treat them as taken. |

## 3. Architecture

### Layout

```
project.yml                 XcodeGen definition (the .xcodeproj is generated, not committed)
Local.example.xcconfig      Template for the git-ignored Local.xcconfig (signing team, bundle ID prefix)
GroovyCamera/
  App/                      App entry, navigation, dependency wiring
  Session/                  ShotList, Slot, SessionController (state machine)
  Camera/                   CameraController (AVFoundation), WhiteBalanceLoop,
                            FrameAnalyzer, Level (Core Motion), AutoCapture, Views
  Imaging/                  PhotoPipeline, NeutralCorrection, SleeveDetector,
                            DiscDetector, SpreadDetector, Exporter
  Naming/                   TextReader (Vision), NameExtractor (Foundation Models),
                            NameValidator, Slug
  Upload/                   UploadQueue, BackgroundSession, R2Client, R2Signer, Keychain
  Library/  Settings/       Screens
  Store/                    SwiftData models
GroovyCameraTests/          Unit and fixture tests, Fixtures/ with real photos
```

### Data model (SwiftData)

- **Record:** id, name, folder slug, whether the name was user-edited, created date, state (`open` / `closed`), pending-rename flag.
- **Photo:** id, record, slot number, kind, original path, final path, thumbnail path, processing state, upload state, retry count, ETag, uploaded date.
- Files are stored locally by id, and the R2 path is worked out only at upload time. A name change therefore never moves a file.

### Capture path

The shutter must never wait on processing, or the 15-second and 30-second targets are at risk. A slow queue is fine, but a crash that loses a photo isn't.

1. Capture at full resolution and stream the original straight to disk, with a small sidecar file holding the white, exposure and focus values used. A thumbnail placeholder appears and the next slot is ready.
2. A background queue takes **one shot at a time** and finds the sleeve, disc or spread in the full frame.
3. It straightens and crops. If detection failed, it center-crops the guide area.
4. It resizes and exports an sRGB JPEG (2048 × 2048, or 4096 × 2048 for gatefold), written atomically, and makes the thumbnail. It then deletes the original, unless **Keep originals** is on.
5. Slots 01, 02 and 03 also go to the naming step.

**Memory, heat and crashes**

- The queue's state is saved, so any shot not yet processed picks up again after a crash or relaunch. Done is never held up, and a record's uploads simply wait for its processing to finish.
- Only one 48 MP image is ever decoded at a time, and its memory is released before the next begins.
- If the phone gets hot (thermal state serious or above), the app says so and the queue keeps running.

**Keep originals:** a debug setting, on by default during M0–M1 and off by default after that. It lets the pipeline be re-run on real originals as the detection and color logic change. Discard session removes originals too.

### White balance, exposure and focus

Set White reads the empty table for a few seconds, adjusting gains and exposure until the white is neutral and at 90–95%, then locks them and saves them. If it doesn't settle within about 6 seconds, it locks the closest result and warns you. After that, nothing reads the live image for color or exposure. The shutter prefers 1/15 s, since the phone is on a stand and a longer shutter keeps ISO and noise down.

Focus locks on the first shot and holds, including for gatefolds, since the height never changes.

### Naming

1. Vision text recognition runs on the corrected front cover, then the back, then Side A if shot.
2. Foundation Models receives the text and returns a structured `{artist, title}`.
3. **Validation:** both values must actually appear in the recognized text (fuzzy match). This stops the model filling in a plausible album from its own knowledge.
4. **Fallback:** if the model refuses (safety filters can trigger on album titles) or validation fails, use a simple rule based on the largest and most prominent text. If that fails too, use the `untitled-…` name.
5. A name you've edited is never overwritten by a later read.

Done doesn't wait for naming. Uploads for a record wait until its reads finish or time out, and this resumes after a relaunch.

### Talking to R2

R2 offers an S3-compatible API, so the app needs only a small client and request signing (AWS Signature V4, built with CryptoKit). Public reads go directly through the custom domain.

| Operation | Purpose |
| --- | --- |
| Signed `PUT` | Background upload of a photo. The returned ETag is compared with the local MD5 before the photo is marked uploaded |
| `CopyObject` + `DeleteObject` | Rename (D5) |
| `ListObjectsV2` | Existing folder names (D13) |

- **Headers:** every `PUT` signs in `Content-Type: image/jpeg` and `Cache-Control: public, max-age=86400`, so photos display rather than download. One day rather than "forever" because a renamed record's old URL could later be reused by a new record. A rename's copy keeps these headers, and M3 checks that it does.
- **Signed URL lifetime:** the maximum of 7 days, so a photo can wait out a long offline stretch. If a URL expires or the token was rotated, R2 rejects the upload, iOS wakes the app, and it signs a new URL and queues the photo again. If a freshly signed URL is also rejected, the photo is marked as needing attention in the Library, rather than retrying forever.
- **Paths:** every request is built from a validated slug and a known filename, so the app only ever writes under `records/`.
- **Locked phone:** photo files use a protection class that still allows access while the phone is locked after first unlock, and the Keychain token uses the matching setting. Otherwise uploads and re-signing would fail on a locked phone.
- **Settings:** R2 account ID, bucket name, access key ID and secret access key, alongside the spec's local copy setting and the debug Keep originals setting. These replace the Worker URL and token. None of them are built into the app or committed to the repo.

## 4. Milestones

Each milestone ends with something you can try on the phone. Simulator builds and unit tests can run without you, but anything marked **on device** needs you and a record.

### M0: Skeleton and device spike

- Project from XcodeGen, signing, install on the phone, permissions, a minimal square preview and shutter.
- A minimal test screen (Set White, Shoot, line-up guides, level) with a **temporary debug panel and self-test, removed before M1**, for risks 1–3 in §5. Gatefold testing moves to M5.
- Keep originals, plus a way to copy them to the Mac (`devicectl`). Originals could total around 1 GB and they're cover art, so they stay out of git. Tests skip them when they aren't present.
- **On device:** shoot 10–15 real records on your real table and light. They become the test fixtures, including a black sleeve, a white sleeve, shrink wrap and discs.
- **Done when:** after one Set White, dark and pale sleeves all come out correctly exposed, the white reads neutral and unclipped at 90–95% in the saved photos, photos save at full resolution, and capture is fast enough for the targets.

### M1: Camera core

- Session state machine and full shot list, including skip, retake, extras numbering, Done requiring slots 01 and 02, resume after a kill, and Discard session.
- Square viewfinder, sleeve target, disc circle and center dot, crosshair, Core Motion level (±1.5°), volume-button shutter, flash off.
- Set White, focus lock on first shot, one-at-a-time processing queue, JPEG export, local save.
- Until M4, the output is the fallback center crop of the guide area.
- **Tests:** slot sequencing and numbering; discard leaves no files behind; the queue resumes after a simulated crash; white and exposure measured on the fixtures.
- **Done when (on device):** a used LP takes under 30 seconds, all four photos of a record match in color, and a rapid burst of 48 MP shots loses nothing, with memory and heat checked in Instruments.

### M2: Naming

- Text reading, Foundation Models extraction, validation, fallback, name chip and editing, final-name toast, slugs, `-2` collisions, `untitled-YYYY-MM-DD-N`.
- Keep originals switches to off by default.
- **Tests:** slug and collision rules; extraction accuracy run across all the fixtures, with the score reported.
- **Done when (on device):** the name is right without typing on the large majority of fixtures. I'd aim for 90%, adjusted once we see real results.

### M3: Cloudflare

- You create the R2 bucket, custom domain and bucket-only token, following a short checklist in the README, which also covers revoking and rotating the token.
- R2 signing and client, upload queue, background session, automatic retries and re-signing, ETag confirmation, local cleanup.
- Library screen (newest first, thumbnails, name, status, detail, simple rename, add extras) and Settings.
- **Tests:** signing against AWS's published test vectors; path checks; queue state changes, including an expired URL and a rejected token.
- **Done when (on device):** photos taken in airplane mode, with the app then closed, reach R2 after reconnecting without reopening the app; a rename works; the public photo URLs display in a browser rather than download, including after a rename.

### M4: Squaring polish

- Rectangle and disc detection after capture, perspective straightening and crop to 2048 × 2048 are **already in the test app**, tried on real photos and on copies rotated up to 40°. What's left is more real records, especially pale sleeves and shrink wrap. In M1, the slot says whether to expect a sleeve or a disc, which removes the guesswork at extreme angles.
- Fallbacks for pale sleeves and low-contrast edges.
- **Tests:** detection and crop on fixtures, measuring how far the corners are off and how often the fallback is used.
- **Done when (on device):** the sleeve fills the frame with no visible background on the normal fixtures, and a sealed record takes under 15 seconds.

### M5: Gatefold

- 2:1 viewfinder with the spread along the phone's long side, two square guides, spine line, spread detection, rotation, 4096 × 2048 export as slot 09.
- **Done when (on device):** an open gatefold is captured and cropped at the right size and matches the session's color.

## 5. Risks

1. **Very warm light may exceed the camera's color range.** The first test hit the blue gain limit of 4.0, though a sleeve was skewing that reading. If it still hits the limit on the empty table, the white won't fully neutralize, and the fix would be a slightly less warm bulb or a fixed correction at export.
2. **Ultra-wide sharpness and distortion.** The first test had a sleeve filling about 95% of the main lens's width, which works out to roughly 30 cm above the table. On the ultra-wide, the first real shots have a sleeve at about 59% of the width, or around 1,790 px at 12 MP, so it's enlarged about 15% to reach 2048. Edges stayed straight and the sleeve landed square and centered. **The bigger problem is light:** the camera hit its ISO limit of 3600 and the app's 1/8 s shutter limit, giving heavy noise reduction and a risk of shake. M0 tests more light and the Quality processing setting. The app requests 48 MP and the camera returns 12 MP in every setting tried so far. Forcing 48 MP is only worth pursuing if the upscaled photos look too soft.
3. **Automatic processing can undo consistency.** iPhone photo processing may adjust tone from shot to shot, even with locked exposure and white balance. If lowering the processing priority doesn't fix this, switching to RAW capture is the backup, at some cost in speed and pipeline complexity.
4. **Pale sleeves, glare on shrink wrap and worn corners** will all challenge edge detection. The spec's center-crop fallback covers failures, but M4's real test is how often it's needed. A false positive that crops too tightly is worse than a fallback, so detection should be conservative.
5. **Name quality.** Artwork-only covers, stylized fonts and non-English pressings will fail sometimes. The back cover and the validation step reduce this, and the chip and Library rename handle the rest. Note that the shot list has no spine photo, so §5's "spines" only helps where a back cover repeats that text.
6. **File size.** 2048 × 2048 at about 1 MB is a target. Busy artwork may run larger at acceptable quality, so I'll favor visible quality over hitting 1 MB exactly unless you'd rather have a hard cap.

7. **R2 compatibility and the key on the phone.** R2 supports only part of the S3 API, so the signing tests alone won't prove uploads work. M3 tests each operation against your real bucket early, before the queue is built on top. See §2 for the accepted tradeoff on the key.

## 6. What I need from you along the way

- Unlocking the phone and trusting the developer profile at first install.
- 10–15 sample records shot on your stand during M0.
- During M3: the bucket, custom domain and token from the checklist. Enter the token directly in the app's Settings, and please don't paste the secret into this chat.

## 7. Out of scope (from spec §10)

Listing creation, pricing, grading, online album lookup, 7″s, CDs, box sets and editing tools.
