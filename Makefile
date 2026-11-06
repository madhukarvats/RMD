.PHONY: project build run test extension clean

APP := build/Build/Products/Debug/RMD.app

project:
	xcodegen generate --quiet

build: project
	xcodebuild -project RMD.xcodeproj -scheme RMD -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build -quiet build

run: build
	pkill -x RMD || true
	while pgrep -qx RMD; do sleep 0.2; done
	for i in 1 2 3 4 5; do open $(APP) && exit 0; sleep 1; done; exit 1  # open fails (-600) for a moment after the old copy quits

# Plain test programs compiled with the app's own source files (no Xcode test target needed).
test:
	mkdir -p build/tests
	swiftc -O -swift-version 6 RMD/Transcription/TranscriptCleanup.swift RMD/Transcription/EchoFilter.swift RMD/Transcription/Words.swift RMD/Storage/TranscriptLine.swift tests/cleanup/main.swift -o build/tests/cleanup
	swiftc -O -swift-version 6 RMD/Audio/SpeechSegmenter.swift RMD/Audio/MicCapture.swift RMD/Audio/AudioDevices.swift tests/segmenter/main.swift -o build/tests/segmenter
	build/tests/cleanup
	build/tests/segmenter

# Claude Desktop extension (MCP bundle) for Settings → Extensions → Install extension.
extension: build
	rm -f build/RMD.mcpb
	cd extension && zip -qX ../build/RMD.mcpb manifest.json rmd-mcp

clean:
	rm -rf build RMD.xcodeproj
