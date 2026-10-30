.PHONY: project build run clean

APP := build/Build/Products/Debug/RMD.app

project:
	xcodegen generate --quiet

build: project
	xcodebuild -project RMD.xcodeproj -scheme RMD -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build -quiet build

run: build
	pkill -x RMD || true
	open $(APP)

clean:
	rm -rf build RMD.xcodeproj
