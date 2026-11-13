# Groovy Camera

An iOS camera app for photographing LPs for listings. Every shot comes out square, color-correct, cropped to the sleeve, filed by date and time and uploaded to Cloudflare R2, with no typing or editing.

**Status: early development.** The camera, shot list and local saving work. Uploading to R2 is being built. See `groovy-camera-spec.md` for the product and `plan.md` for the build plan. MIT licensed.

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

## Keeping this repo clean

This repo is public, so a check runs on every commit and push to stop private details getting in. Turn it on once per clone:

```sh
git config core.hooksPath .githooks
git config user.email "<id>+<username>@users.noreply.github.com"   # GitHub → Settings → Emails
```

It blocks the signing values in `Local.xcconfig`, photos, R2 endpoints and keys, home paths, device IDs and commits made with a computer's local email address. To block your own private strings too, such as your R2 account ID, bucket name and photo domain, list them one per line in a file named `Local.secrets` (git-ignored). Public example values that trip the check go in `.secret-scan-allow`. Run it by hand with `scripts/check-secrets.sh staged`.

In GitHub's settings, **Keep my email addresses private** and **Block command line pushes that expose my email** add a second line of defense, and the repo's secret scanning with push protection a third.

## Cloudflare setup

Photos upload straight from the phone to your own Cloudflare R2 bucket. You need a Cloudflare account with R2 turned on and a domain on Cloudflare. Nothing about your account goes in the code: you type it into the app's Settings, and it's kept only in the phone's Keychain.

1. **Create a bucket.** In the Cloudflare dashboard, go to **R2 Object Storage** → **Create bucket**. Any name works. The app only writes photos under `records/` in it, plus one spreadsheet, `photos.csv`, at the top.
2. **Give it a public domain.** Open the bucket → **Settings** → **Custom Domains** → **Connect Domain**, and pick a subdomain of your domain, such as `photos.<your domain>`. Each photo is then at `https://photos.<your domain>/records/<folder>/<file>.jpg`, ready to paste into a listing. Leave the `r2.dev` public URL off.
3. **Make a token for the app.** Go to **R2 Object Storage** → **Manage API tokens** → **Create API token**. Set **Permissions** to **Object Read & Write**, and under **Specify bucket(s)** choose **Apply to specific buckets only** and pick your bucket. Create it.
4. **Copy what Cloudflare shows once:** the **Access Key ID** and **Secret Access Key**. The **Account ID** is in the endpoint shown with them (`https://<account ID>.r2.cloudflarestorage.com`) and on the R2 overview page.
5. **Enter them on the phone.** Open the app, tap the gear, fill in Account ID, Bucket, Access key ID and Secret access key, and tap **Check connection**, which uploads and deletes a small file under `records/` to prove the token works. The keys are long, so copy each one on your Mac and paste it on the phone: Universal Clipboard carries it across when both are signed into the same Apple Account with Handoff on.
6. **Turn on the spreadsheet.** In Settings, enter the bucket's custom domain under **Photo domain**. After each upload the app updates `photos.csv` at the top of the bucket, beside `records/`, listing every photo's link, one row per photo with the record's date and time on its first row. **Open spreadsheet** in Settings opens it, and **Clear spreadsheet** starts it afresh without deleting any photos. You can also paste its link into Google Sheets with `=IMPORTDATA("<link>")`.

Don't paste the secret anywhere else, including chats, issues or commits.

**Revoking or rotating the token.** Under **Manage API tokens**, delete the token to cut the app off at once. To rotate, create a new token as in step 3, enter it in the app's Settings and check the connection, then delete the old token. Uploads signed with the old token fail once it's deleted, and the app signs them again with the new one.

**What the token can do.** Object Read & Write on one bucket includes deleting objects in it. That's the accepted tradeoff for having no server: someone holding the unlocked phone could read, overwrite or delete that bucket's photos, but nothing else in your account.

## Test photos

The app saves full-resolution originals so the image pipeline can be re-run on real photos. To copy them to `Fixtures/originals` on your Mac:

```sh
xcrun devicectl list devices
scripts/pull-originals.sh "<your device>"
```

Please don't commit these. Cover art is copyrighted, so that folder is git-ignored.
