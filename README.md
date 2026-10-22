# dotclean

Removes macOS metadata (`.DS_Store`, `._` AppleDouble, `Thumbs.db`, `.AppleDouble`
folders, …) from non-Mac volumes — USB sticks, SD cards, SMB/NFS shares — either
live as files appear, or on demand.

Mac-formatted volumes (APFS/HFS) are left alone; the only thing that fixes there
is Finder cosmetics, and `._` can be load-bearing.

## Layout

```
Sources/DotCleanCore/   rules, volume detection, walker, scanner, executor, watcher
Sources/bclean/         headless CLI (ad-hoc cleaning, used as the test harness)
Sources/DotCleanApp/    menu bar app + Finder Services entry
Tests/                  rule, walker and executor tests
Resources/Info.plist    LSUIElement + NSServices
```

## Build

```sh
make            # swift build -c release
make app        # assemble build/DotClean.app
make test       # swift test
make sign       # Developer ID + hardened runtime
make notarize   # notarytool submit + staple (profile: notary-jeff)
make install    # copy to /Applications + lsregister
```

## CLI

```sh
bclean volumes                              # mounted volumes, * = cleanable
bclean rules                                # rule table + scopes
bclean scan  /Volumes/stick --samples 20    # report only
bclean clean /Volumes/stick                 # dry run
bclean clean /Volumes/stick --yes           # actually delete
bclean clean /Volumes/stick --yes --eject   # clean + unmount + detach
bclean sweep [--dry-run]                    # all non-Mac volumes
bclean watch [--seconds N]                  # run the live watcher in the foreground
```

Exit codes: `0` ok, `1` some deletions failed, `2` usage, `3` refused.

`clean` is dry-run unless `--yes`. `--watcher-only` restricts to the rules the
live watcher is allowed to fire. `--mac` overrides the Mac-format refusal.

## Rule scopes

Some names are safe to delete the moment they appear; others are live,
system-owned directories that churn Finder if removed while mounted. Those are
ad-hoc only:

| Live watcher | Ad-hoc only |
|---|---|
| `._*`, `.DS_Store`, `.apdisk`, `.VolumeIcon.icns`, `Thumbs.db`, `desktop.ini`, `.AppleDouble/`, `__MACOSX/` | `.fseventsd/`, `.Spotlight-V100/`, `.TemporaryItems/`, `.Trashes/`, `$Recycle.bin/`, `System Volume Information/` |

`._Foo.ttf` / `.eps` / `.ps` / `.otf` / `.ai` / `.indd` are never deleted — for
those formats the `._` companion can hold the actual glyph or resource data.

## Two things worth knowing before changing the core

**`FileManager.enumerator` cannot be used.** macOS treats `._*` as an AppleDouble
companion of the file it shadows and filters those names out of enumeration
entirely — through both `enumerator(atPath:)` and
`enumerator(at:includingPropertiesForKeys:)`. A directory containing `thing.txt`
and `._thing.txt` enumerates as just `["thing.txt"]`. The headline rule of this
tool would silently match nothing. `Sources/DotCleanCore/Walker.swift` walks with
`opendir`/`readdir` instead, and `WalksTests.testFoundationEnumeratorHidesAppleDouble`
locks the behaviour in.

**FSEvents is lossy.** Under heavy I/O the kernel emits `MustScanSubDirs` /
`UserDropped` / `KernelDropped` instead of individual events. The watcher treats
those as "re-scan this subtree" rather than ignoring them, and a pathological
batch falls back to a subtree scan. A watcher that reports healthy while missing
everything is worse than no watcher.

## Safety

- Every deletion re-verifies the parent's device id, refuses mount points, and
  never follows symlinks.
- Roots under `/`, `/System`, `/usr`, `/Library`, `/var`, `$HOME` itself are
  refused by `PathGuard`.
- All deletions are appended to `~/Library/Logs/DotClean/dotclean.log`.
- A per-path fight-loop guard stops deleting something an app recreates
  immediately.

## Log

```
~/Library/Logs/DotClean/dotclean.log
```

Format: `timestamp ACTION rule path`, actions `DEL`, `FAIL`, `WATCH`, `SWEEP`,
`RECOVER`, `DRY`, `SUPPRESS`, `APP`.
