.PHONY: app release clean

# A local development build, signed the way Config/TypeSwitch.xcconfig says.
app:
	./scripts/build-app.sh

# A signed, notarized, stapled DMG. Runs on this machine, never in CI, so the
# Developer ID certificate stays here.
release:
	./scripts/release.sh

clean:
	rm -rf build
