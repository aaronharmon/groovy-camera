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
- **The phone sits on an overhead stand or arm.** Auto-capture is the main way to shoot, so it **defaults to on**, and the volume button or on-screen shutter is the backup. Capture needs a clear sound and haptic so you know it fired without looking at the screen.
- **Discard session is added.** The camera screen gets a **Discard session** action, shown once the session has a photo and protected by a confirmation. It deletes that session's photos from the phone, stops any processing and naming still running, clears the white balance and exposure lock, and opens a new session. Uploads start only at Done (D2), so there's nothing to remove from R2. *This is an addition to spec §2 and §8.* It only covers the open session: the Library still has no delete, so anything already finished stays in R2 until you remove it there.
- **Done shows the final name.** After Done, a short toast shows the record's final name, once naming has finished. Tapping it fixes the name. Uploads for that record start when the toast ends, a few seconds after Done, so a fix made here is a local change with no R2 copy and delete. The toast doesn't block the next record, and it never holds uploads if the app is closed or the toast can't be shown.
- **Setup is ready:** paid Apple Developer account, domain on Cloudflare, R2 enabled, iPhone 17 Pro on iOS 27. The app targets **iOS 27 only**.

### Approved defaults

| # | Spec gap | Default |
| --- | --- | --- |
| D1 | §3 says the viewfinder "shows exactly what will be saved", but autocrop removes the visible background. | The viewfinder shows the framing. The thumbnail shows the final crop. |
| D2 | §2 says uploads "continue" after Done, but the folder name can change until then. | Uploads **start at Done**, once the name is final and its toast has ended. That means retakes never overwrite a live URL or leave a stale cached copy. |
| D3 | The spec locks white balance but doesn't mention exposure. A black sleeve and a white sleeve would meter differently, which breaks the "consistent look" goal. | Set exposure so the white background sits at roughly **90–95% brightness**, never at clipping, so pale sleeves keep their edge and the neutral correction has something to measure. Lock **exposure and focus** with white balance on the first shot. Also turn off as much per-shot processing as the API allows. Neutral correction fixes color only, so the white corners of disc shots stay at that brightness rather than pure white. M0 will show whether that looks right. |
| D4 | Vision rectangle detection (§9) can't find discs. | Find the disc by contour detection plus a circle fit. A dark disc on white should be an easy case. |
| D5 | R2 has no rename, and renaming changes the URLs of links already pasted into listings. | Kept simple, since renames after upload should be rare. The app copies each photo to the new name, then deletes the old one, with a pending flag so it finishes if interrupted. It runs only while the app is open. Rename is unavailable while that record still has uploads in progress. The rename screen warns that old links will stop working. |
| D6 | A phone lying flat reports no useful orientation, so photos could be saved rotated. | The app is portrait-locked and ignores device orientation. "Up" on the record is the top of the phone. A square sleeve is straightened by the smallest rotation, so it won't flip 90°. |
| D7 | Force-quitting an app makes iOS cancel its background uploads, which the spec's "app closed" wording doesn't allow for. | Uploads survive the app being suspended or closed by the system, and offline periods. After a force-quit they resume on next launch. |
| D8 | The app is killed mid-session. | Reopening resumes that session if it has any photos. |
| D9 | The Library needs images after local copies are cleared. | Keep a small thumbnail of every photo on the phone permanently, and show only those in the Library. The app never loads images from the domain or needs to know it. |
| D10 | On a stand, auto-capture could fire repeatedly on the same sleeve. | It re-arms only after the outline is lost, meaning the sleeve was moved. It fires only when the outline is complete and inside the guide, the white margin around it is clear, the phone is level, and all of that holds with no movement for the full 0.5 s. Anything failing restarts the timer. The clear-margin check is what catches a hand: any hand reaching the sleeve has to cross the white margin, even if the outline still looks complete. |
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

1. Capture at full resolution and stream the original straight to disk, with a small sidecar file holding the session's locked values. A thumbnail placeholder appears and the next slot is ready.
2. A background queue takes **one shot at a time** and finds the sleeve, disc or spread in the full frame.
3. It samples the white background outside the detected shape and applies a neutral correction to the whole frame. If there's too little white, it uses the session's locked value.
4. It straightens and crops. If detection failed, it center-crops the guide area.
5. It resizes and exports an sRGB JPEG (2400 × 2400, or 3200 × 1600 for gatefold), written atomically, and makes the thumbnail. It then deletes the original, unless **Keep originals** is on.
6. Slots 01, 02 and 03 also go to the naming step.

**Memory, heat and crashes**

- The queue's state is saved, so any shot not yet processed picks up again after a crash or relaunch. Done is never held up, and a record's uploads simply wait for its processing to finish.
- Only one 48 MP image is ever decoded at a time, and its memory is released before the next begins.
- If the phone gets hot (thermal state serious or above), auto-capture pauses and the app says why. Manual capture still works, and the queue keeps running.

**Keep originals:** a debug setting, on by default during M0–M1 and off by default after that. It lets the pipeline be re-run on real originals as the detection and color logic change. Discard session removes originals too.

### White balance, exposure and focus

The preview's color comes from a feedback loop:

- Sample the guide's outer ring at about 5–10 Hz (or outside the detected outline, from M4).
- Compute the remaining color cast and nudge the device gains toward neutral, with damping, within the camera's allowed range.
- Stop updating at the first shot. A retake keeps the session's lock.

Exposure follows the same sample to hold the background at 90–95%, and locks with focus on the first shot. **Gatefold is the exception to the focus lock:** the arm is raised for a spread (§5, risk 2), which would throw locked focus off. The gatefold shot focuses once and locks, then the session's locked focus returns. Color and exposure stay as locked.

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
- **Settings:** R2 account ID, bucket name, access key ID and secret access key, alongside the spec's auto-capture and local copy settings and the debug Keep originals setting. These replace the Worker URL and token. None of them are built into the app or committed to the repo.

## 4. Milestones

Each milestone ends with something you can try on the phone. Simulator builds and unit tests can run without you, but anything marked **on device** needs you and a record.

### M0: Skeleton and device spike

- Project from XcodeGen, signing, install on the phone, permissions, a minimal square preview and shutter.
- A throwaway test screen for risks 1–3 in §5: the color feedback loop, exposure placement, full-resolution capture time, and lens and stand height.
- Keep originals, plus a way to copy them to the Mac (`devicectl`). Originals could total around 1 GB and they're cover art, so they stay out of git. Tests skip them when they aren't present.
- **On device:** shoot 10–15 real records on your real table and light. They become the test fixtures, including a black sleeve, a white sleeve, shrink wrap, a gatefold and discs, plus a few shots with a hand in the frame for the auto-capture check.
- **Done when:** the white background reads neutral and unclipped at 90–95% in the saved photo, and capture is fast enough for the targets.

### M1: Camera core

- Session state machine and full shot list, including skip, retake, extras numbering, Done requiring slots 01 and 02, resume after a kill, and Discard session.
- Square viewfinder, sleeve target, disc circle and center dot, crosshair, Core Motion level (±1.5°), volume-button shutter, flash off.
- White balance and exposure loop, white balance, exposure and focus lock on first shot, per-photo correction, one-at-a-time processing queue, JPEG export, local save.
- Until M4, the output is the fallback center crop of the guide area.
- **Tests:** slot sequencing and numbering; discard leaves no files behind and resets the lock; the queue resumes after a simulated crash; neutral correction measured on the fixtures.
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

- Live outline (amber/green), rectangle and disc detection, perspective straightening, crop to the edge, auto-capture with the D10 rules.
- Fallbacks for pale sleeves and low-contrast edges.
- **Tests:** detection and crop on fixtures, measuring how far the corners are off and how often the fallback is used; the auto-capture rules against the hand-in-frame shots.
- **Done when (on device):** the sleeve fills the frame with no visible background on the normal fixtures, the outline stays steady, auto-capture never fires with a hand in the frame, and a sealed record takes under 15 seconds.

### M5: Gatefold

- 2:1 viewfinder, two square guides, spine line, step-back hint, gatefold focus, spread detection, 3200 × 1600 export as slot 09.
- **Done when (on device):** an open gatefold is captured and cropped at the right size and matches the session's color.

## 5. Risks

1. **The color feedback loop may be jittery or settle off-neutral.** Live preview colors already include the current gains, so it has to converge rather than compute the answer once. M0 tests this. The fallback is a brief settle-and-hold, with the per-photo correction doing more of the work.
2. **Lens choice and distance.** My rough estimate, to be confirmed in M0:
   - The main 24 mm lens frames a sleeve plus margin at about 35–40 cm, which is close enough that small tilts show up as keystoning.
   - The 2× mode is flatter, but it's a 12 MP crop. With the sleeve at about 80% of the frame, that's only around 2,400 px across, with nothing to spare for the output size.
   - The 4× telephoto would have to sit too far away.
   - **Leaning toward:** the main lens at full 48 MP, with straightening correcting small tilts. A stand makes the 35–40 cm height easy to hold steady.
   - **Gatefolds use the main lens** (decided: the ultra-wide is ruled out because of its distortion). A spread needs roughly 55 cm, so the arm goes up and back down for each one, and the app's hint says so.
3. **Automatic processing can undo consistency.** iPhone photo processing may adjust tone from shot to shot, even with locked exposure and white balance. If lowering the processing priority doesn't fix this, switching to RAW capture is the backup, at some cost in speed and pipeline complexity.
4. **Pale sleeves, glare on shrink wrap and worn corners** will all challenge edge detection. The spec's center-crop fallback covers failures, but M4's real test is how often it's needed. A false positive that crops too tightly is worse than a fallback, so detection should be conservative.
5. **Name quality.** Artwork-only covers, stylized fonts and non-English pressings will fail sometimes. The back cover and the validation step reduce this, and the chip and Library rename handle the rest. Note that the shot list has no spine photo, so §5's "spines" only helps where a back cover repeats that text.
6. **File size.** 2400 × 2400 at about 1 MB is a target. Busy artwork may run larger at acceptable quality, so I'll favor visible quality over hitting 1 MB exactly unless you'd rather have a hard cap.

7. **R2 compatibility and the key on the phone.** R2 supports only part of the S3 API, so the signing tests alone won't prove uploads work. M3 tests each operation against your real bucket early, before the queue is built on top. See §2 for the accepted tradeoff on the key.

## 6. What I need from you along the way

- Unlocking the phone and trusting the developer profile at first install.
- 10–15 sample records shot on your stand during M0.
- During M3: the bucket, custom domain and token from the checklist. Enter the token directly in the app's Settings, and please don't paste the secret into this chat.

## 7. Out of scope (from spec §10)

Listing creation, pricing, grading, online album lookup, 7″s, CDs, box sets and editing tools.
