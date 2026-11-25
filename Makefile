.PHONY: test app cert run ios uitest selftest clean verify release-check

test:
	swift test
	python3 -I tools/stt-eval/test_check.py

app:
	scripts/build-app.sh

cert:
	scripts/make-cert.sh

run: app
	open build/Susu.app

# SusuCore must keep building for iOS (spec 2.3).
ios:
	xcodebuild -quiet -scheme SusuCore -destination 'generic/platform=iOS Simulator' build

# XCUITest walk of build/Susu.app (needs UI automation permission once).
uitest: app
	xcodegen --spec Tests/UITests/project.yml --quiet
	xcodebuild test -quiet -project Tests/UITests/SusuUITests.xcodeproj -scheme SusuUITests -destination 'platform=macOS'

# Dev check: build, tests, bundle. Steps that were not run are listed as NOT_RUN.
verify:
	scripts/verify.sh

# Release gate: fails unless every mandatory step passed for this exact commit.
release-check:
	scripts/verify.sh --release

selftest:
	tools/e2e/selftest

clean:
	rm -rf .build build
