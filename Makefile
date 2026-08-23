BUILD_DIR      := build
DRIVER_BUNDLE  := $(BUILD_DIR)/Kurarin.driver
DRIVER_BINARY  := $(DRIVER_BUNDLE)/Contents/MacOS/Kurarin

APP_BUNDLE     := $(BUILD_DIR)/Kurarin.app
APP_BINARY     := $(APP_BUNDLE)/Contents/MacOS/Kurarin

ARCHS          := -arch arm64 -arch x86_64
CFLAGS         := -O2 -Wall -Wextra -fmodules $(ARCHS) -mmacosx-version-min=14.2
FRAMEWORKS     := -framework CoreAudio -framework CoreFoundation

.PHONY: all driver app test clean install-driver uninstall-driver

# Signs with a real identity when the machine has one, and ad-hoc otherwise.
#
# This is not about distribution — nothing here is notarised — it is about
# macOS's privacy grants. TCC identifies an application by its signature, and an
# ad-hoc one changes with every build, so screen recording has to be granted
# again after each rebuild and the permission silently stops applying. Any
# stable identity fixes that; which one does not matter. A clone on a machine
# with no certificate falls back to ad-hoc and works exactly as before, minus
# the sticky permission.
# The certificate's fingerprint rather than its name, which contains spaces
# and brackets and would need quoting through two levels of shell.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -oE '[0-9A-F]{40}' | head -1)
CODESIGN_AS   := $(if $(SIGN_IDENTITY),$(SIGN_IDENTITY),-)

# Clears the extended attributes off a bundle and signs it, retrying because
# clearing them is not final.
#
# codesign refuses to sign anything carrying Finder metadata, and a build
# directory inside iCloud Drive gets that metadata put back within
# milliseconds of it being removed — often between the clear and the signature.
# A quarantine flag is worse than a failed signature: coreaudiod skips a
# quarantined plug-in during its scan, logs nothing, and the device simply
# never appears. So both are cleared, and the pair is attempted until it takes.
# (xattr has no -r flag, hence find.)
# $(2) is the identity: the app wants a stable one so its privacy grants
# survive a rebuild, the driver deliberately stays ad-hoc — it needs no
# permissions, and how a bundle loaded inside coreaudiod is signed is not
# something to change without a reason.
define sign_bundle
	@attempt=1; \
	while [ $$attempt -le 8 ]; do \
		find $(1) -exec xattr -c {} + 2>/dev/null; \
		if codesign --force --sign "$(2)" --timestamp=none $(1) 2>/dev/null; then \
			echo "signed $(1)"; \
			exit 0; \
		fi; \
		attempt=$$((attempt + 1)); \
	done; \
	echo "error: could not sign $(1); Finder metadata kept coming back" >&2; \
	exit 1
endef

all: driver app

# --- virtual audio driver -------------------------------------------------

driver: $(DRIVER_BINARY)

$(DRIVER_BINARY): Driver/KurarinDriver.c Driver/Info.plist
	@mkdir -p $(DRIVER_BUNDLE)/Contents/MacOS
	cp Driver/Info.plist $(DRIVER_BUNDLE)/Contents/Info.plist
	clang $(CFLAGS) -bundle $(FRAMEWORKS) -o $@ Driver/KurarinDriver.c
	$(call sign_bundle,$(DRIVER_BUNDLE),-)

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
	$(call sign_bundle,$(APP_BUNDLE),$(CODESIGN_AS))

# --- checks ---------------------------------------------------------------

test:
	swift test
	$(MAKE) test-realtime

# The real-time safety checks only mean anything with the optimiser on: a debug
# build allocates and frees a block per loop iteration for bookkeeping that
# release removes, so every unit would look like it allocates once per sample.
# They skip themselves rather than fail if run the other way.
test-realtime:
	swift test -c release --filter '.*AllocationTests'

# --- installation ---------------------------------------------------------

install-driver: driver
	./scripts/install-driver.sh

uninstall-driver:
	./scripts/uninstall-driver.sh

clean:
	rm -rf $(BUILD_DIR) .build
