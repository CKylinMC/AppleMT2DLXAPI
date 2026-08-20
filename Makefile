APP = AppleMTDeepLX
SCHEME = $(APP)
DERIVED = .build-derived

.PHONY: all generate build run release clean

all: generate build

## 生成 Xcode 工程（需要 xcodegen：brew install xcodegen）
generate:
	xcodegen generate

## Debug 构建
build: generate
	xcodebuild -project $(APP).xcodeproj -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) build

## Release 构建
release: generate
	xcodebuild -project $(APP).xcodeproj -scheme $(SCHEME) -configuration Release -derivedDataPath $(DERIVED) build

## 构建并直接运行（必须在本机运行，Translation 不支持模拟器）
run: build
	open $(DERIVED)/Build/Products/Debug/$(APP).app

clean:
	rm -rf $(DERIVED) $(APP).xcodeproj
