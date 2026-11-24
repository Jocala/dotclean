# Jocala dotclean (`com.jocala.dotclean`)

Menu-bar app + headless CLI that removes macOS metadata (`.DS_Store`, `._`
AppleDouble, `Thumbs.db`, `desktop.ini`, `.AppleDouble/`, `__MACOSX/`, and the
ad-hoc-only volume directories) from **non-Mac volumes**. SwiftPM, macOS 13+,
GPLv3, `~/source/dotclean`.

Current release: **1.01 (build 2)** — live at
`https://www.jocala.com/dotclean/`, GitHub `Jocala/dotclean` tag `v1.01`.

## Layout

```
Sources/DotCleanCore/   rules, volume/FS info + policy, walker, scanner,
                        executor, watcher, log, disk eject, update fetch
Sources/bclean/         headless CLI (ad-hoc cleaning; also the test harness)
Sources/DotCleanApp/    menu-bar app, About panel, update UI
Tests/DotCleanCoreTests/ 29 tests (rules, walker, executor, update compare,
                        volume policy)
Resources/Info.plist    LSUIElement + NSServices; version lives here
Resources/donatel.png   PayPal button art (copied from catalog's assets)
icon/                   make-icon.swift + AppIcon.icns
web/                    product page + versioned DMG (gitignored: *.dmg)
Makefile                build/assemble/sign/notarize/install
package-dotclean.sh     signed+notarized+stapled DMG
```

Build/packaging artifacts are **not** in the repo: `build/`, `.build*`,
`packages/`, `web/*.dmg`.

## Build and test

```sh
make                 # release build (default: assemble the app)
make test            # version-check + swift test  (29 tests)
make app             # universal .app into build/DotClean.app
make sign            # Developer ID + hardened runtime + timestamp
./package-dotclean.sh   # app notarized+stapled, DMG built, DMG notarized+stapled
```

- `VERSION` in the Makefile is **derived** from `Info.plist`; only the plist
  holds it. `version-check` fails if `bclean`'s `toolVersion` literal drifts.
- Universal by default: `swift build -c release --arch arm64 --arch x86_64
  --scratch-path .build-universal`. The x86_64 deployment-target warning is
  expected, not a failure.
- Signing: `Developer ID Application: jeff elkins (9Q77WK7W3R)`, notary profile
  `notary-jeff` (see the global signing rules). **No entitlements file** — the
  app is hardened-runtime but unsandboxed, links no third-party dylibs, and Qt/
  Rust exemptions do not apply here. Do not add sandbox or library-validation
  entitlements "to be safe".
- `make install` runs `make notarize` first, so it hits Apple's notary service.
  For a quick local swap use `ditto build/DotClean.app /Applications/DotClean.app`
  plus `lsregister -f`.

## Release checklist (proven 2026-11-24 for 1.01)

Order matters — `version.txt` gates every installed copy's update check.

1. Bump `CFBundleShortVersionString` **and** `CFBundleVersion` in
   `Resources/Info.plist`; update `bclean`'s `toolVersion`. `make test`.
2. Update `web/index.html`: heading (`Get dotclean X.XX`), `dotclean vX.XX ·
   universal`, and the `dotclean.X.XX.dmg` link.
3. `./package-dotclean.sh` → `packages/dotclean.X.XX.dmg`.
4. **Stage on debian** (never push release bytes from the Mac directly):

   ```sh
   scp packages/dotclean.X.XX.dmg web/index.html \
       jeff@192.168.1.39:/zstore/source/www/jocala.com/dotclean/
   ssh jeff@192.168.1.39 'printf "X.XX" > /zstore/source/www/jocala.com/dotclean/version.txt'
   ```

   Verify `http://192.168.1.39/www/jocala.com/dotclean/`: page strings, DMG
   `200` with the exact byte count, `version.txt` body.
5. Commit the staging repo (`/zstore/source/www/jocala.com`) with the byte
   sizes in the message — it is a git repo, and `dotclean/version.txt` starts
   untracked on every new product.
6. **Go live** (explicit trigger phrase), in two steps so nobody is pointed at
   an old page:

   ```sh
   ssh jeff@192.168.1.39 'rsync -avz --chmod=F644,D755 --exclude version.txt \
     /zstore/source/www/jocala.com/dotclean/ \
     jeff@jocala.com:/var/www/jocala.com/public_html/dotclean/'
   # verify prod page + DMG, then:
   ssh jeff@192.168.1.39 'rsync -avz --chmod=F644 \
     /zstore/source/www/jocala.com/dotclean/version.txt \
     jeff@jocala.com:/var/www/jocala.com/public_html/dotclean/version.txt'
   ```

   Leave the previous `dotclean.X.XX.dmg` in place.
7. GitHub: commit, `git push origin main`, `git tag -a vX.XX`, push the tag,
   `gh release create vX.XX packages/dotclean.X.XX.dmg --title … --notes …`.

Site-wide procedure (staging tree, prod rsync, root `index.html` rules) is
`~/.config/opencode/jocala-website.md`; product dir is `dotclean/`.

## Update check

- Manual only. **There is no startup check and there must not be one** — the app
  opens no connection until the user picks "Check for Updates…" (menu) or the
  About panel button. Adding a launch-time check was considered and rejected.
- Source of truth: `https://www.jocala.com/dotclean/version.txt` (bare version
  string, **no trailing newline**; servers tolerate either, compare trims).
- Compare rule is **Catalog-exact**: any trimmed difference is "newer",
  including a rollback. Locked in by `UpdatesTests`; do not "fix" it into a
  numeric compare. Consequence: never ship a build whose version differs from
  the published `version.txt` — it will offer the older/newer file as an update.
- `DOTCLEAN_VERSION_URL` overrides the source (http(s) URL or a local file
  path) so newer/equal/offline branches can be exercised without touching the
  live file.
- There is **no** `changelog.txt` for dotclean; the update dialog has no
  Changelog button on purpose. Don't add one without publishing the file.

## Network-share policy (1.01+)

`fstype` is a transport, not an origin: `smbfs` can front an APFS Mac (m1's
home share), where deleting `._`/`.DS_Store` is exactly what this tool exists
to avoid. So:

- `Volume.isMacFormat` → apfs/hfs/hfsx only; those are never cleaned.
- `Volume.allowsAutomaticClean(allowedHosts:)` → local non-Mac always; a
  network volume only when `Volume.networkHost` (parsed from `f_mntfromname`)
  is in `watchNetworkHosts`.
- `VolumeList.targets()` = automatic set (watcher, `sweep`, `sweepNow()`);
  `VolumeList.cleanable()` = every non-Mac volume (app menu, `bclean volumes`,
  explicit `clean <path>`).
- Stored key: `watchNetworkHosts` in domain `com.jocala.dotclean`, read/written
  through **CFPreferences** so the CLI and the app see the same values.

```sh
defaults write com.jocala.dotclean watchNetworkHosts -array 192.168.1.39 192.168.20.10
bclean volumes    # * auto, ~ on request only, unmarked = Mac format
```

## Traps (each one cost real time)

1. **`FileManager.enumerator` cannot see `._*`.** macOS treats them as
   AppleDouble companions and filters them out of enumeration entirely — the
   headline rule would match nothing. `Walker.swift` uses `opendir`/`readdir`;
   `WalksTests.testFoundationEnumeratorHidesAppleDouble` pins the Foundation
   behaviour so a "simplification" back to enumerator fails loudly.
2. **FSEvents is lossy.** `MustScanSubDirs` / `UserDropped` / `KernelDropped`
   mean "re-scan this subtree", never "ignore"; batches over 5,000 candidates
   also fall back to a subtree scan. A watcher that reports healthy while
   missing everything is worse than no watcher.
3. **`UserDefaults(suiteName: "com.jocala.dotclean")` silently fails** when the
   calling process *is* that bundle ("Using your own bundle identifier as a
   suite name does not make sense"), which is exactly what `bclean` does inside
   the app bundle. Use `CFPreferencesCopyAppValue`/`CFPreferencesSetAppValue`
   with an explicit domain.
4. **The menu-bar item has no tooltip, deliberately.** It used to be
   `button.toolTip = "DotClean"` and macOS rendered a dark pill over whatever
   was underneath. Removed in 1.01 at the user's request — don't re-add.
   `button.image.accessibilityDescription` stays for VoiceOver.
5. **`Bundle.main` is only a bundle inside a real `.app`.** A bare binary
   dropped next to an `Info.plist` still reports `Version ?` and no icon, so
   About-panel checks must run from a `.app` wrapper.
6. **There is no Accessibility access for this app.** `System Events` reports
   zero menu bars for the accessory process, so the menu cannot be clicked from
   a script. Verify UI by rendering it: build a throwaway `.app` (harness +
   `Info.plist` with `CFBundleExecutable` set), find the window id via
   `CGWindowListCopyWindowInfo` matching `kCGWindowName`, and
   `screencapture -x -o -l <id>`. `screencapture` works from the terminal here.
7. **Tests must not use `/var/folders`.** `PathGuard` refuses system temp areas
   and the executor tests need a root it will operate on; fixtures live under
   `~/Library/Caches/dotclean-tests-<uuid>`.
8. **`Scanner` builds its own `Volume`** from the path (fsType + source only).
   It is not a substitute for `VolumeList` resolution — policy decisions belong
   in `VolumeList`/`Volume`, never in the scanner.

## Invariants — do not weaken

- `Executor` is the only code that deletes. It re-verifies the parent's device
  id, refuses mount points, refuses to follow symlinks, and deletes files
  before directories (deepest-first).
- `PathGuard` forbids `/`, `$HOME`, and `/System /usr /bin /sbin /private
  /Library /Applications /opt /cores /dev /etc /var`.
- Rule scopes: `.fseventsd`, `.Spotlight-V100`, `.TemporaryItems`, `.Trashes`,
  `$Recycle.bin`, `System Volume Information` are **ad-hoc only** — never in the
  live watcher.
- `._*.ttf|otf|ttc|dfont|eps|ps|ai|indd|qxd` are never deleted (the resource
  fork can hold the actual glyphs).
- Every deletion and refusal is appended to `~/Library/Logs/DotClean/dotclean.log`
  (`DEL FAIL WATCH SWEEP RECOVER DRY SUPPRESS APP DONE`).

## Verification

```sh
make test                                  # 29 tests, includes version-check
make app && make sign | tail -3            # SIG-OK, both arches
codesign -dvvv /Applications/DotClean.app 2>&1 | grep -E 'Authority|TeamIdentifier'
xcrun stapler validate /Applications/DotClean.app && spctl -a -vv /Applications/DotClean.app
curl -sS https://www.jocala.com/dotclean/version.txt          # X.XX
curl -sI https://www.jocala.com/dotclean/dotclean.X.XX.dmg | grep Content-Length
```

Update-check branches without touching production:

```sh
DOTCLEAN_VERSION_URL=/tmp/v.txt ./scratch-check   # file override
```

Environment facts used above: debian `192.168.1.39` (staging + site git),
production `jeff@jocala.com` (Apache, `/var/www/jocala.com/public_html/`),
test vhost `http://192.168.1.39/www/jocala.com/`.
