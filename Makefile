.PHONY: app run core test install release clean

app:            ## Build build/Squish.app (release)
	./scripts/build-app.sh release

run: app        ## Build and launch
	open build/Squish.app

core:           ## Build only the Rust engine
	MACOSX_DEPLOYMENT_TARGET=26.0 cargo build --release --manifest-path core/Cargo.toml

test:           ## Run engine tests
	cargo test --release --manifest-path core/Cargo.toml

install: app    ## Copy to /Applications (enables Services + Launch at Login)
	rm -rf /Applications/Squish.app && cp -R build/Squish.app /Applications/
	/System/Library/CoreServices/pbs -update

release: app    ## Developer ID sign, notarize and pack → build/Squish.dmg
	./scripts/release.sh

clean:
	rm -rf build App/.build core/target
