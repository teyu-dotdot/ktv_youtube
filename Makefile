.PHONY: app project test build clean server help

PROJECT := App/KTVYouTube.xcodeproj

help:
	@echo "make app      generate the Xcode project and open it"
	@echo "make project  generate the Xcode project only"
	@echo "make test     run the KaraokeKit test suite"
	@echo "make build    build KaraokeKit"
	@echo "make server   run the reference resolver service"
	@echo "make clean    remove generated project and build artifacts"

project:
	@command -v xcodegen >/dev/null || { echo "XcodeGen not found. Install with: brew install xcodegen"; exit 1; }
	cd App && xcodegen generate

app: project
	open $(PROJECT)

test:
	swift test

build:
	swift build

server:
	cd server && python3 resolver.py

clean:
	rm -rf $(PROJECT) .build
