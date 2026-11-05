# Groovy Camera

An iOS camera app for photographing LPs for listings. Every shot comes out square, color-correct, cropped to the sleeve, named after the album and uploaded to Cloudflare R2, with no typing or editing.

- `groovy-camera-spec.md` says what the product does.
- `plan.md` says how we're building it, including the decisions behind any change from the original spec, and the milestones.

Read both before starting a milestone. If they disagree, or the code has to differ from them, raise it rather than choosing silently. Once a change is agreed, update both in the same piece of work.

## This repo is public

The repo is public at `aaronharmon/groovy-camera` and MIT licensed (`LICENSE`) so others can remix it. Anything added must be compatible with that license. Assume everything committed, including commit messages and git history, is visible forever. A secret that gets committed has to be revoked, not just deleted.

**Never commit:**

- R2 tokens, account IDs, bucket names or the photo domain. These are entered in the app's Settings and stored only on the phone. Don't put them in code, tests, config, logs or chat, and don't ask for them. Never log them or the signed URLs built from them.
- Real record photos: originals, test photos or screenshots showing them. Cover art is copyrighted and originals are large. They stay in a git-ignored folder, and tests must skip cleanly when they're absent.
- Personal or device details: signing team ID, device IDs, home paths. Team ID and bundle ID prefix go in a git-ignored `Local.xcconfig`, with a committed `Local.example.xcconfig` showing what to set.

Before every commit, read the staged diff with this list in mind. AWS's published example credentials are fine in the signing test vectors, because they're public documentation values.

**Keep it remixable:**

- Someone else's account must work by filling in `Local.xcconfig` and Settings, with no code changes. Don't hardcode anything specific to this owner, stand or bucket.
- Keep the README's setup checklist accurate. It's how a stranger gets from clone to working app, and it covers creating the bucket, custom domain and token, and revoking and rotating the token.
- Comments and docs should make sense to someone without our chat history. Explain why, particularly for camera and color behavior.

## How we work

- **Work one milestone at a time, in the order in `plan.md`.** A milestone finishes when its "done when" criteria are met, not when the code compiles.
- **Stay in scope.** Don't add features, settings or abstractions that aren't in the spec or plan. This project deliberately trims scope: no server, no third-party Swift dependencies, no Library image loading. Suggest additions rather than building them.
- **Ask before changing a decision recorded in `plan.md` §2.** Those were made on purpose.
- **Be honest about what was verified.** Say separately what passed in tests and what still needs checking on the phone. Code that builds and passes tests isn't confirmed to work on a real record.
- **Git:** commit or push only when asked. Use a branch for milestone work, not `main`.
- **Cloudflare:** the owner handles account changes (bucket, domain, tokens). Don't change the account or its data without asking.

## Testing

The simulator has no camera, and the color and detection results that matter come from real photos on a real stand.

- Keep image pipeline, naming, session and upload logic independent of the camera, so they run on saved images.
- Unit tests cover logic: slot sequencing, slugs, signing, queue state and crash recovery. Fixture tests run when the local originals are present, and report measurements such as color error, corner error, fallback rate and naming accuracy rather than only pass or fail.
- Foundation Models results only count when run on the phone.
- If a change needs a device check, say exactly what to shoot and what to look for.

## Commands

The project file is generated from `project.yml` and not committed, so regenerate it after adding or moving files.

```sh
xcodegen generate
xcodebuild test -project GroovyCamera.xcodeproj -scheme GroovyCamera \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Target is iOS 26 or newer, on iPhones with Apple Intelligence.

## Things that are easy to break

These come from decisions in `plan.md`, and the reasons aren't obvious from the code.

- **Never lose a photo.** The original is on disk before anything else happens, and the queue processes one shot at a time and resumes after a crash. A slow queue is acceptable. The shutter never waits on processing.
- **Set white once, then leave it alone.** Set White on the empty table fixes white balance and exposure (white at 90–95%, never clipped) until the user sets it again. Don't add live or per-photo adjustment: the light doesn't change, and reading the image while a record is in frame is what broke dark sleeves. Focus locks on the first shot and holds, because the tripod height is fixed.
- **Rotate and crop only: never warp a record's shape.** No perspective correction and no uneven scaling. Warping to detected corners made a back cover look tilted in 3D. The level keeps the phone flat, which is what prevents keystoning.
- **Uploads start after Done, once the name is final and its toast has ended.** Retakes, discards and name fixes before that never touch R2.
- **R2 paths are worked out at upload time** from a validated slug and a known filename, always under `records/`. Local files are stored by id, so a name change never moves one.
- **Ignore device orientation.** A phone lying flat doesn't report a useful one, so the app is portrait-locked and "up" is the top of the phone.
- **Background uploads must work on a locked phone,** so photo files and the Keychain token must stay accessible after first unlock. The token is this-device-only.
