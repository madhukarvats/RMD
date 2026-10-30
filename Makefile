.PHONY: project build run extension clean

APP := build/Build/Products/Debug/RMD.app

project:
	xcodegen generate --quiet

build: project
	xcodebuild -project RMD.xcodeproj -scheme RMD -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build -quiet build

run: build
	pkill -x RMD || true
	while pgrep -qx RMD; do sleep 0.2; done  # open fails (-600) while the old copy is still quitting
	open $(APP)

# Claude Desktop extension (MCP bundle) for Settings → Extensions → Install extension.
extension: build
	rm -f build/RMD.mcpb
	cd extension && zip -qX ../build/RMD.mcpb manifest.json rmd-mcp

clean:
	rm -rf build RMD.xcodeproj
