APP := build/Clawdmeter.app

.PHONY: app install test clean

app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Helpers
	cp .build/release/ClawdmeterApp $(APP)/Contents/MacOS/
	cp .build/release/clawdmeter $(APP)/Contents/Helpers/
	cp Resources/Info.plist $(APP)/Contents/
	codesign --force --sign - $(APP)/Contents/Helpers/clawdmeter
	codesign --force --sign - $(APP)

install: app
	-pkill -x ClawdmeterApp
	rm -rf /Applications/Clawdmeter.app
	cp -R $(APP) /Applications/
	open /Applications/Clawdmeter.app

test:
	swift test

clean:
	rm -rf .build build
