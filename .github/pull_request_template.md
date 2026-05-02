## Summary

- 

## Verification

- [ ] `swift build`
- [ ] `swift test`
- [ ] Packaged app checked with `ALLOW_ADHOC=1 SIGNING_IDENTITY=- ./scripts/build-release.sh`
- [ ] Clipboard HUD checked manually
- [ ] Append mode checked manually
- [ ] Image / rich clipboard flow checked manually
- [ ] Diagnostics checked for no clipboard contents

## Risk

- [ ] Touches event tap behavior
- [ ] Touches pasteboard read/write behavior
- [ ] Touches storage or migrations
- [ ] Touches sensitive-content handling
- [ ] Touches release signing or packaging
