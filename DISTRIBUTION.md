# cmd — Distribution Guide

This document covers everything needed to go from a local ad-hoc build to a
fully signed, notarised, auto-updating release on the Mac App Store or direct
distribution.

---

## Quick Paths

### Local test build

Use this only on your own Mac. It is ad-hoc signed and not appropriate for
friends or public distribution.

```bash
ALLOW_ADHOC=1 SIGNING_IDENTITY=- ./scripts/build-release.sh
./scripts/build-dmg.sh
```

### Free local sharing build

Use this when you do not have the $99/year Apple Developer Program yet. It
creates an ad-hoc signed DMG. This is not a seamless public release, but it is
the most honest free path for trusted friends.

```bash
ALLOW_ADHOC=1 SIGNING_IDENTITY=- ./scripts/build-release.sh
./scripts/build-dmg.sh
```

Your friends may need to right-click the app and choose Open, then approve it in
System Settings -> Privacy & Security.

### Professional release for friends

Use this after installing a Developer ID Application certificate and setting up
notarytool credentials.

```bash
NOTARY_PROFILE=cmdNotary ./scripts/package-release.sh
```

That command builds the app, signs it with hardened runtime, notarises and
staples the app, builds the DMG, signs the DMG, notarises and staples the DMG,
verifies the disk image, and writes a release manifest in `build/`.

If you do not want to use a keychain notary profile, pass credentials directly:

```bash
APPLE_ID=you@example.com \
TEAM_ID=XXXXXXXXXX \
APP_PASSWORD=xxxx-xxxx-xxxx-xxxx \
./scripts/package-release.sh
```

Do not send friends a build created with `SIGNING_IDENTITY=-`; Gatekeeper will
treat it like an unsigned app.

---

## Section 1: One-time setup (Developer account)

### 1.1 Enroll in the Apple Developer Program

1. Go to [developer.apple.com](https://developer.apple.com) and sign in with
   your Apple ID.
2. Enroll in the **Apple Developer Program** ($99/year). This grants access to
   distribution certificates, notarisation, and the Mac App Store.
3. Wait for enrollment approval (usually instant for individuals, up to 48 h
   for organisations).

### 1.2 Create a Developer ID Application certificate

1. Open **Xcode → Settings → Accounts**.
2. Select your Apple ID and click **Manage Certificates…**.
3. Click **+** and choose **Developer ID Application**.
4. Xcode creates the certificate and installs it in your login Keychain
   automatically.

### 1.3 Find your signing identity name

Run the following to confirm the exact identity string:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

The output looks like:

```
  1) XXXXXXXXXXXX "Developer ID Application: Your Name (TEAMID)"
```

Use that full quoted string as the value of `SIGNING_IDENTITY` in
`build-release.sh`:

```bash
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ./scripts/build-release.sh
```

If there is only one Developer ID Application certificate installed,
`scripts/package-release.sh` and `scripts/build-release.sh` can discover it
automatically.

### 1.4 Store notarisation credentials

The recommended setup is a keychain profile, so release commands do not expose
Apple credentials in shell history:

```bash
xcrun notarytool store-credentials cmdNotary
```

When prompted, enter your Apple ID, Team ID, and app-specific password. Future
releases can then use:

```bash
NOTARY_PROFILE=cmdNotary ./scripts/package-release.sh
```

---

## Section 2: Auto-updates

Auto-updates are intentionally not part of the current beta. The app bundle does
not include updater framework metadata or placeholder update URLs. Add an
updater only after the Developer ID and notarisation path is working reliably.

---

## Section 3: Releasing a new version

Follow these steps in order for every release.

1. **Bump the version** in `Sources/ClipLog/Info.plist`:

   ```xml
   <key>CFBundleShortVersionString</key>
   <string>1.1.0</string>
   <key>CFBundleVersion</key>
   <string>2</string>
   ```

   `CFBundleVersion` must be a monotonically increasing integer.
   `CFBundleShortVersionString` is the human-readable version shown to users.

2. **Package the professional release**:

   ```bash
   NOTARY_PROFILE=cmdNotary ./scripts/package-release.sh
   ```

   This produces:
   - `build/CMD.app`
   - `build/CMD-X.Y.Z.dmg`
   - `build/CMD-X.Y.Z-release-manifest.txt`

Manual release steps are still available if you need to debug one stage:

3. **Build and sign** the app bundle:

   ```bash
   SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
     ./scripts/build-release.sh
   ```

4. **Notarise** the app:

   ```bash
   TARGET_PATH="build/CMD.app" \
   NOTARY_PROFILE=cmdNotary \
     ./scripts/notarise.sh
   ```

5. **Build and sign the DMG**:

   ```bash
   SIGN_DMG=1 \
   SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
   ./scripts/build-dmg.sh
   ```

   This produces `build/CMD-X.Y.Z.dmg`.

6. **Notarise the DMG**:

   ```bash
   TARGET_PATH="build/CMD-X.Y.Z.dmg" \
   NOTARY_PROFILE=cmdNotary \
   ./scripts/notarise.sh
   ```

7. **Upload** the DMG to your release host or send it directly to trusted beta
   testers.
