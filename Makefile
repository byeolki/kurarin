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
	# A quarantined plug-in is not merely refused, it is never looked at:
	# coreaudiod skips it during its scan and says nothing about why. The
	# attribute arrives on its own — a build directory inside iCloud Drive is
	# enough — so it is cleared here as well as at install time. xattr has no
	# -r, hence find.
	find $(DRIVER_BUNDLE) -exec xattr -c {} + && \
		codesign --force --sign - --timestamp=none $(DRIVER_BUNDLE)

# --- application ----------------------------------------------------------

app: $(APP_BINARY)

# Built for both architectures to match the driver, which clang makes universal
# in one pass. An Intel Mac loading a universal driver into coreaudiod but
# unable to run the app that feeds it would be a strange thing to ship.
$(APP_BINARY): $(shell find Sources -name '*.swift' 2>/dev/null) Resources/App-Info.plist
	swift build -c release --product KurarinApp --arch arm64 --arch x86_64
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	cp Resources/App-Info.plist $(APP_BUNDLE)/Contents/Info.plist
	cp .build/apple/Products/Release/KurarinApp $@
	# Finder tags a new .app bundle with metadata that codesign refuses to
	# sign over, and it can reappear between commands, so the clear and the
	# signing happen in one shell invocation. This xattr has no -r flag.
	find $(APP_BUNDLE) -exec xattr -c {} + && \
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
