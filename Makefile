APP = AppleMTDeepLX
SCHEME = $(APP)
DERIVED = .build-derived

.PHONY: all generate build run release clean bump

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

## 版本管理：推荐 ./bump（支持全部参数）；make bump 仅支持无 -- 前缀参数
##   ./bump [patch|minor|major|X.Y.Z] [--beta] [--dump] [--no-commit] [--no-tag] [--help]
bump:
	@bash scripts/bump.sh $(filter-out bump,$(MAKECMDGOALS))

# 兜底规则：吞掉 bump 透传的参数（如 minor / --beta），避免 make 报未知目标
%: ; @:
