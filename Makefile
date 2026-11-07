# Noddle build. A stable signing identity keeps macOS permissions across rebuilds:
#   make install SIGN_ID="Developer ID Application: Your Name (TEAMID)"
# With no identity it signs ad hoc, and Accessibility must be re-granted after each rebuild.
SIGN_ID ?= -

.PHONY: all test app install run

all: app

test:
	swift test

build/AppIcon.icns: Sources/NoddleCore/Figure.swift Sources/FigureSheet/main.swift
	mkdir -p build/AppIcon.iconset
	swift run -c release FigureSheet --icon build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns

app: build/AppIcon.icns
	swift build -c release --product Noddle
	mkdir -p build/Noddle.app/Contents/MacOS build/Noddle.app/Contents/Resources
	cp -f "$$(swift build -c release --product Noddle --show-bin-path)/Noddle" build/Noddle.app/Contents/MacOS/Noddle
	cp -f Resources/Info.plist build/Noddle.app/Contents/Info.plist
	cp -f build/AppIcon.icns build/Noddle.app/Contents/Resources/AppIcon.icns
	codesign --force --options runtime --entitlements Resources/Noddle.entitlements --sign "$(SIGN_ID)" build/Noddle.app

install: app
	ditto build/Noddle.app /Applications/Noddle.app
	open /Applications/Noddle.app

run: app
	open build/Noddle.app
