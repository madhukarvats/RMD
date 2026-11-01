.PHONY: project build run test extension clean

APP := build/Build/Products/Debug/RMD.app

project:
	xcodegen generate --quiet

build: project
	xcodebuild -project RMD.xcodeproj -scheme RMD -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build -quiet build

run: build
	pkill -x RMD || true
	while pgrep -qx RMD; do sleep 0.2; done  # open fails (-600) while the old copy is still quitting
	open $(APP)

# Plain test programs compiled with the app's own source files (no Xcode test target needed).
test:
	mkdir -p build/tests
	swiftc -O -swift-version 6 RMD/Transcription/TranscriptCleanup.swift tests/cleanup/main.swift -o build/tests/cleanup
	swiftc -O -swift-version 6 RMD/Audio/SpeechSegmenter.swift RMD/Audio/MicCapture.swift tests/segmenter/main.swift -o build/tests/segmenter
	build/tests/cleanup
	build/tests/segmenter

# Claude Desktop extension (MCP bundle) for Settings → Extensions → Install extension.
extension: build
	rm -f build/RMD.mcpb
	cd extension && zip -qX ../build/RMD.mcpb manifest.json rmd-mcp

clean:
	rm -rf build RMD.xcodeproj
