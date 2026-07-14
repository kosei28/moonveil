BINARY_NAME = moonveil
APP_NAME = Moonveil.app
APP_DIR = $(APP_NAME)/Contents/MacOS
INSTALL_PATH = /Applications

.PHONY: build run release app install uninstall clean

build:
	swift build

run:
	swift run $(BINARY_NAME)

release:
	swift build -c release

app: release
	mkdir -p $(APP_DIR)
	cp .build/release/$(BINARY_NAME) $(APP_DIR)/$(BINARY_NAME)
	/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $(BINARY_NAME)" $(APP_NAME)/Contents/Info.plist 2>/dev/null || true
	/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.moonveil.app" $(APP_NAME)/Contents/Info.plist 2>/dev/null || true
	/usr/libexec/PlistBuddy -c "Add :CFBundleName string Moonveil" $(APP_NAME)/Contents/Info.plist 2>/dev/null || true
	/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" $(APP_NAME)/Contents/Info.plist 2>/dev/null || true

install: app
	cp -r $(APP_NAME) $(INSTALL_PATH)/$(APP_NAME)
	@echo "installed to $(INSTALL_PATH)/$(APP_NAME)"

uninstall:
	rm -rf $(INSTALL_PATH)/$(APP_NAME)
	sudo rm -f /etc/sudoers.d/moonveil
	@echo "removed $(INSTALL_PATH)/$(APP_NAME)"

clean:
	swift package clean
	rm -rf .build $(APP_NAME)
