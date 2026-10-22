APP_NAME    := DotClean
BUNDLE_ID   := com.jocala.dotclean
VERSION     := 1.0
BUILD       := build
APP         := $(BUILD)/$(APP_NAME).app
CONFIG      := release
ARCHS       := --arch arm64 --arch x86_64
SCRATCH     := .build-universal
SIGN_ID     := Developer ID Application: jeff elkins (9Q77WK7W3R)
NOTARY      := notary-jeff

SWIFT_BUILD = swift build -c $(CONFIG) $(ARCHS) --scratch-path $(SCRATCH)

.PHONY: all build bin icon app sign notarize test clean install verify run package

all: app

build:
	$(SWIFT_BUILD)

icon:
	swift icon/make-icon.swift icon/dotclean-icon-1024.png 1024
	swift icon/make-icon.swift web/images/dotclean-icon-512.png 512
	@set -e; rm -rf icon/AppIcon.iconset; mkdir -p icon/AppIcon.iconset; \
	for pair in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
	            "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
	            "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do \
	  set -- $$pair; sips -z $$1 $$1 icon/dotclean-icon-1024.png --out "icon/AppIcon.iconset/$$2.png" >/dev/null; \
	done; \
	iconutil -c icns icon/AppIcon.iconset -o icon/AppIcon.icns; \
	echo "icons rebuilt"

app: build
	@set -e; \
	BIN=$$($(SWIFT_BUILD) --show-bin-path); \
	rm -rf "$(APP)"; \
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"; \
	cp "$$BIN/DotClean" "$(APP)/Contents/MacOS/$(APP_NAME)"; \
	cp "$$BIN/bclean" "$(APP)/Contents/MacOS/bclean"; \
	cp icon/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"; \
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"; \
	printf 'APPL????' > "$(APP)/Contents/PkgInfo"; \
	plutil -lint "$(APP)/Contents/Info.plist" >/dev/null; \
	lipo -info "$(APP)/Contents/MacOS/$(APP_NAME)"; \
	echo "built $(APP)"

test:
	swift test

sign:
	@test -d "$(APP)" || (echo "run 'make app' first" && exit 1)
	codesign --force --deep --options runtime --timestamp \
		--sign "$(SIGN_ID)" "$(APP)"
	codesign -dvvv "$(APP)" 2>&1 | grep -E "Authority|TeamIdentifier|flags=" || true
	codesign -v "$(APP)" && echo SIG-OK

notarize: sign
	@set -e; \
	rm -f /tmp/$(APP_NAME)-submit.zip; \
	ditto -c -k --keepParent "$(APP)" /tmp/$(APP_NAME)-submit.zip; \
	xcrun notarytool submit /tmp/$(APP_NAME)-submit.zip \
		--keychain-profile "$(NOTARY)" --wait; \
	xcrun stapler staple "$(APP)"; \
	spctl -a -vv "$(APP)"

package: notarize
	./package-dotclean.sh

install: notarize
	rm -rf "/Applications/$(APP_NAME).app"
	ditto "$(APP)" "/Applications/$(APP_NAME).app"
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
		-f "/Applications/$(APP_NAME).app"

verify:
	@codesign -dvvv "/Applications/$(APP_NAME).app" 2>&1 | grep -E "Authority|TeamIdentifier|flags=|Timestamp"
	@codesign -v --strict "/Applications/$(APP_NAME).app" && echo "SIGNATURE-OK"
	@xcrun stapler validate "/Applications/$(APP_NAME).app"
	@spctl -a -vv "/Applications/$(APP_NAME).app"

run: app
	"$(APP)/Contents/MacOS/$(APP_NAME)"

clean:
	swift package clean
	rm -rf "$(BUILD)" "$(SCRATCH)"
