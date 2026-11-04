# Groovy Camera — Product Spec

Nov 4, 2026 · @Aaron Harmon

## 1. Summary

Groovy Camera is a single-user iOS camera app for photographing LPs (used and new) for listings. Its only job is to get good, consistent photos of each record into one place quickly: every shot is square, color-correct against a white background, centered and squared to the frame, named after the album, and uploaded to Cloudflare, without typing or editing.

**Goals**

1. **Listing-ready on capture.** Square, white-balanced, cropped to the sleeve and compressed the moment the shutter fires.
2. **Zero-touch naming.** The app reads the album name off the record and files the photos under it.
3. **Consistent look.** Every photo of every record matches.
4. **Fast.** A sealed record (two photos) in under 15 seconds; a used LP (four photos) in under 30.

**Scope:** LPs and double LPs (with triple sets covered by the optional extra sides). Everything runs on the phone except storage.

## 2. The session

One session = one record. Each session has a fixed, short shot list:

| # | Shot | Required |
| --- | --- | --- |
| 01 | Sleeve front | Yes |
| 02 | Sleeve back | Yes |
| 03 | Side A (disc) | Optional |
| 04 | Side B (disc) | Optional |
| 05 | Side C (disc) | Optional |
| 06 | Side D (disc) | Optional |
| 07 | Side E (disc) | Optional |
| 08 | Side F (disc) | Optional |
| 09 | Gatefold | Optional |

Only the sleeve front and back are required, so new or sealed records are two photos and done. Disc shots are of the disc on its own, out of the sleeve.

**Flow**

1. Open the app; a new session is already waiting.
2. Shoot **sleeve front**. The app reads the album name in the background.
3. Shoot **sleeve back**.
4. **New/sealed record:** tap **Done**. **Used record:** keep going with **Side A** and **Side B**; the viewfinder always shows the next slot ("03 · Side A").
5. For a double LP, after Side B the app offers **Side C** and **Side D** (then E/F). Skip with one tap.
6. Tap **Gatefold** if the sleeve opens out (see §6).
7. Tap **Done** (available once 01 and 02 are shot). The session closes and a new session opens. A short toast shows the record's final name, and tapping it fixes the name. Uploads start in the background when the toast ends.

Any slot can be retaken by tapping its thumbnail. **Extra photos** (inserts, damage, anything else) can be added by hand with a **+ Extra** button; they're numbered 10, 11, 12…

**Discard session.** Once a session has a photo, **Discard session** (with a confirmation) deletes its photos from the phone and opens a new session. Nothing has been uploaded at that point, so there's nothing to remove from storage.

## 3. Framing: 1:1, guidelines and squaring

**1:1 output.** The viewfinder is square and shows the framing, including the white background; the thumbnail shows the final crop. The app captures at full sensor resolution and crops to square, leaving room to straighten. Output: **2400 × 2400 JPEG, sRGB** (~1 MB each).

**Guidelines**

- **Sleeve target:** a square outline showing where the sleeve edges should sit, with some white background visible around it (the app needs that background to find the edges and set white balance; it's cropped off afterwards).
- **Disc circle** and **center dot** for disc shots, so the spindle hole lands dead center.
- **Center crosshair** on every shot.

**Squaring assist**

- **Edge detection:** the app finds the sleeve (or disc) against the white background and draws its outline live. Amber when rotated or off-center, green when lined up.
- **Level:** a bubble level shows when the phone is flat over the table, which prevents keystoning. Green within ±1.5°.
- **Auto-capture (on by default):** when the outline is green, complete and inside the guide, the white margin around it is clear (so no hand is in the frame), the phone is level and the image is still for a full half second, the shutter fires. It re-arms only after the outline is lost, meaning the record was moved.
- **Autocrop to the sleeve edge:** after capture, the app straightens the sleeve and crops exactly to its edges, so the sleeve fills the whole square with no background. If the edges can't be found, it falls back to a center crop of the guide area.
- **Disc shots:** cropped to a square just around the disc's edge, disc centered.

Flash is off (glare on vinyl and shrink wrap). Volume buttons work as the shutter.

## 4. Automatic white balance

You shoot on a white background under warm light. The app uses that background as its reference, so there is nothing to calibrate.

**How it works**

1. **Live:** the app continuously samples the white background around the sleeve or disc, works out the color shift that would make it pure white, and sets the camera's white balance to match. The preview looks neutral before you press the shutter.
2. **Lock on first shot:** the app sets exposure from the background, placing it at roughly 90–95% brightness and never at clipping. Once the session's first photo is taken, white balance, exposure and focus are locked for the rest of the session, so all photos of a record match exactly.
3. **Per-photo correction:** after each capture, and before cropping to the sleeve, the app checks the white background in the full frame and corrects any remaining tint, so a slight drift in light doesn't show.

**Edge cases**

- If the sleeve fills almost the whole frame and there's too little white to sample, the app uses the session's locked value.
- A white or very pale sleeve on the white background: edge detection may struggle; the app falls back to the center crop and still uses the margin for color.
- Mixed light (window + lamp) can leave uneven color across the frame; one light source gives the best results.

## 5. Automatic album naming (on device)

The app reads the album name off the record itself. Everything happens on the phone; no external services.

**How it reads the name**

1. **Sleeve front:** on-device text recognition reads all the text on the cover.
2. **Sleeve back:** spines and back covers almost always print artist and title, so the back confirms the front or supplies the name when the cover is just artwork.
3. **Side A label** (when shot): used as a further check.
4. Apple's on-device language model turns the recognized text into a clean "Artist — Title".

**What the user sees**

- The name appears in a chip at the top of the viewfinder as soon as it's read, usually right after the sleeve front.
- If it's wrong, tap the chip to edit it. Otherwise, nothing to do.
- If nothing readable is found by the end of the session, it's saved as `untitled-2026-11-04-1` and can be renamed later from the Library.

**Naming**

- Folder: `artist-title`, lowercase, e.g. `miles-davis-kind-of-blue`. If the same name already exists, `-2`, `-3` is added.
- Files: `01-sleeve-front.jpg`, `02-sleeve-back.jpg`, `03-side-a.jpg`, `04-side-b.jpg`, `05-side-c.jpg` … `09-gatefold.jpg`, `10-extra.jpg`.
- Full path: `records/miles-davis-kind-of-blue/03-side-a.jpg`.

## 6. Gatefold mode

An open gatefold is about twice as wide as it is tall, so it gets its own frame and its own output size.

- Tap **Gatefold** during a session to shoot slot 09.
- The viewfinder switches to a **2:1 frame** with two side-by-side square guides and a dashed **spine line** down the middle.
- Edge detection looks for the 2:1 spread; the level and auto-capture work the same as in normal mode.
- Same white balance and exposure as the rest of the session, corrected against the white background. Focus is set once for the spread, then the session's locked focus returns.
- Shot on the main camera, not the ultra-wide, to avoid distortion. A hint to step back or raise the phone so the whole spread fits with some background around it.
- **Output:** autocropped to the edges of the spread, one 2:1 JPEG, 3200 × 1600, saved as `09-gatefold.jpg`.

## 7. Cloudflare storage

Photos go to a **Cloudflare R2** bucket, one folder per record. A custom domain on the bucket gives each photo a stable link for pasting into listings.

```
records/
  miles-davis-kind-of-blue/
    01-sleeve-front.jpg
    02-sleeve-back.jpg
    03-side-a.jpg
    04-side-b.jpg
```

**Upload**

- The app talks directly to R2, with no server in between. It holds an R2 API token limited to this one bucket with object read/write only, stored in the iPhone's Keychain (available after first unlock, this device only). It signs its own upload URLs, valid for up to 7 days, and renames a folder by copying each photo and deleting the old one.
- Photos are saved on the phone first, and uploads start in the background after **Done**. They continue when the app is closed or offline, except that iOS cancels them if the app is force-quit, in which case they resume on next launch. Failed uploads retry automatically.
- Every photo is stored with `Content-Type: image/jpeg` and a one-day `Cache-Control`, so it displays rather than downloads.
- Local copies are cleared after a confirmed upload (or kept for N days, set in Settings).

## 8. Screens

**Camera (home).** Opens straight into the viewfinder.

- Top: album name chip, current slot ("04 · Side B").
- Center: square (or 2:1) viewfinder with guides, live outline and level.
- Bottom: shutter, thumbnail strip of this session's slots (tap to retake), **Gatefold**, **+ Extra**, **Done**.
- **Discard session**, once the session has a photo.

**Library.** Records newest first, with front-cover thumbnail, name and upload status. Tap one to see thumbnails of its photos, rename it or add extras. Full-size photos are pulled from R2 on a laptop with existing tools, not through the app.

**Settings.** R2 account ID, bucket name and token credentials; auto-capture on/off; keep local copies for N days.

## 9. Technical notes

| Area | Approach |
| --- | --- |
| App | SwiftUI |
| Camera | AVFoundation; white balance and exposure set from the sampled white background, locked with focus per session |
| Squaring | Vision rectangle detection for sleeves, contour detection and circle fit for discs; Core Image straighten and crop |
| Level | Core Motion |
| Naming | Vision text recognition; Apple's on-device Foundation Models |
| Correction | Core Image neutral-white adjustment from the white background, before cropping |
| Local store | SwiftData for sessions and the upload queue |
| Upload | Background URLSession → R2 (S3-compatible API, signed on the phone) |

**Device requirement:** an iPhone with Apple Intelligence (iPhone 15 Pro or newer), on iOS 27. Older phones and earlier iOS versions aren't supported.

Personal app, not on the App Store: installed from Xcode or TestFlight. A paid Apple Developer account avoids having to reinstall every 7 days.

## 10. Plan

**Not in v1:** listing creation, pricing, grading, online album lookup, 7″s, CDs, box sets, editing tools, folder links or galleries, full-size viewing in the Library, deleting finished records.

**Milestones**

0. **Device spike:** project setup, camera tests on the real stand and light, sample photos.
1. **Camera core:** session shot list, Discard session, square capture, guides, level, auto white balance, exposure and focus lock, local save.
2. **Naming:** text recognition on the sleeve front and back, name chip, rename.
3. **Cloudflare:** R2 bucket, direct background uploads, Library.
4. **Squaring polish:** live outline, straightening, auto-capture.
5. **Gatefold mode.**
