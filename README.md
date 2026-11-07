# Groovy Camera

An iOS camera app for photographing LPs for listings. Every shot comes out square, color-correct, cropped to the sleeve, filed by date and time and uploaded to Cloudflare R2, with no typing or editing.

**Status: early development.** The app is currently a test screen for checking the camera on a real stand. See `groovy-camera-spec.md` for the product and `plan.md` for the build plan. MIT licensed.

## Build

You need Xcode 27 or newer, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and an iPhone on iOS 26 or newer.

```sh
cp Local.example.xcconfig Local.xcconfig   # then add your team ID and bundle ID prefix
xcodegen generate
open GroovyCamera.xcodeproj
```

Run the tests, which don't need a phone:

```sh
xcodebuild test -project GroovyCamera.xcodeproj -scheme GroovyCamera \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Test photos

The app saves full-resolution originals so the image pipeline can be re-run on real photos. To copy them to `Fixtures/originals` on your Mac:

```sh
xcrun devicectl list devices
scripts/pull-originals.sh "<your device>"
```

Please don't commit these. Cover art is copyrighted, so that folder is git-ignored.
