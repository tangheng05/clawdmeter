APP := build/Clawdmeter.app
BUILD := swift build -c release --arch arm64 --arch x86_64
BIN = $(shell $(BUILD) --show-bin-path)

.PHONY: app install release test clean

app:
	$(BUILD)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Helpers $(APP)/Contents/Resources
	cp $(BIN)/ClawdmeterApp $(APP)/Contents/MacOS/
	cp $(BIN)/clawdmeter $(APP)/Contents/Helpers/
	cp Resources/Info.plist $(APP)/Contents/
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/
	codesign --force --sign - $(APP)/Contents/Helpers/clawdmeter
	codesign --force --sign - $(APP)

install: app
	-pkill -x ClawdmeterApp
	rm -rf /Applications/Clawdmeter.app
	cp -R $(APP) /Applications/
	open /Applications/Clawdmeter.app

release: app
	cd build && rm -f Clawdmeter.zip && ditto -c -k --keepParent Clawdmeter.app Clawdmeter.zip

test:
	swift test

clean:
	rm -rf .build build
