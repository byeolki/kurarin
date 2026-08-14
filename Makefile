BUILD_DIR      := build
DRIVER_BUNDLE  := $(BUILD_DIR)/Kurarin.driver
DRIVER_BINARY  := $(DRIVER_BUNDLE)/Contents/MacOS/Kurarin

APP_BUNDLE     := $(BUILD_DIR)/Kurarin.app
APP_BINARY     := $(APP_BUNDLE)/Contents/MacOS/Kurarin

ARCHS          := -arch arm64 -arch x86_64
CFLAGS         := -O2 -Wall -Wextra -fmodules $(ARCHS) -mmacosx-version-min=14.2
FRAMEWORKS     := -framework CoreAudio -framework CoreFoundation

.PHONY: all driver app test clean install-driver uninstall-driver

all: driver app

# --- virtual audio driver -------------------------------------------------

driver: $(DRIVER_BINARY)

$(DRIVER_BINARY): Driver/KurarinDriver.c Driver/Info.plist
	@mkdir -p $(DRIVER_BUNDLE)/Contents/MacOS
	cp Driver/Info.plist $(DRIVER_BUNDLE)/Contents/Info.plist
	clang $(CFLAGS) -bundle $(FRAMEWORKS) -o $@ Driver/KurarinDriver.c
	codesign --force --sign - --timestamp=none $(DRIVER_BUNDLE)

# --- application ----------------------------------------------------------

app: $(APP_BINARY)

$(APP_BINARY): $(shell find Sources -name '*.swift' 2>/dev/null) Resources/App-Info.plist
	swift build -c release --product KurarinApp
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	cp Resources/App-Info.plist $(APP_BUNDLE)/Contents/Info.plist
	cp .build/release/KurarinApp $@
	@if [ -d .build/release/Kurarin_KurarinPresets.bundle ]; then \
		cp -R .build/release/Kurarin_KurarinPresets.bundle $(APP_BUNDLE)/Contents/Resources/; \
	fi
	codesign --force --sign - --timestamp=none $(APP_BUNDLE)

# --- checks ---------------------------------------------------------------

test:
	swift test

# --- installation ---------------------------------------------------------

install-driver: driver
	./scripts/install-driver.sh

uninstall-driver:
	./scripts/uninstall-driver.sh

clean:
	rm -rf $(BUILD_DIR) .build
