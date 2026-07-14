BINARY_NAME = netafuri
INSTALL_PATH = /usr/local/bin

.PHONY: build run release install uninstall clean

build:
	swift build

run:
	swift run $(BINARY_NAME)

run-sudo:
	swift build
	sudo .build/debug/$(BINARY_NAME)

release:
	swift build -c release

install: release
	sudo cp .build/release/$(BINARY_NAME) $(INSTALL_PATH)/$(BINARY_NAME)
	@echo "installed to $(INSTALL_PATH)/$(BINARY_NAME)"

uninstall:
	sudo rm -f $(INSTALL_PATH)/$(BINARY_NAME)
	@echo "removed $(INSTALL_PATH)/$(BINARY_NAME)"

clean:
	swift package clean
	rm -rf .build
