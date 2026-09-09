.PHONY: app install release clean

# build/ holds artifacts. Nothing is run from there — `make install` is what
# updates the copy you use.

# A local development build, signed the way Config/TypeSwitch.xcconfig says.
app:
	./scripts/build-app.sh

# Moves whatever is in build/ to /Applications and starts it: quit, replace,
# launch, in that order.
install:
	./scripts/install.sh

# A signed, notarized, stapled DMG. Runs on this machine, never in CI, so the
# Developer ID certificate stays here.
release:
	./scripts/release.sh

clean:
	rm -rf build
