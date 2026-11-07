# open-dmcn-apple. DMCNKit (the Swift package at the root) builds and tests anywhere Swift runs,
# Linux included; the app (App/OpenDMCN.xcodeproj) needs macOS with Xcode.

SWIFT ?= swift
TOOLS := .build/tools
PROTOC_GEN_SWIFT := $(TOOLS)/protoc-gen-swift
IOS_DESTINATION ?= generic/platform=iOS Simulator

.PHONY: bootstrap build test proto proto-sync proto-sync-check notices notices-check \
        go-fixture app format format-check icons clean

bootstrap: ## Resolve packages and build the pinned protoc-gen-swift
	$(SWIFT) package resolve
	$(MAKE) $(PROTOC_GEN_SWIFT)

build: ## Build DMCNKit
	$(SWIFT) build

test: proto-sync-check notices-check format-check ## Mirror, notices and format checks, then every test
	$(SWIFT) test

# protoc-gen-swift is built from the swift-protobuf checkout Package.resolved pins, so the
# generated code and the runtime it links against are always the same version.
$(PROTOC_GEN_SWIFT): Package.resolved
	$(SWIFT) package resolve
	$(SWIFT) build -c release --package-path .build/checkouts/swift-protobuf \
		--scratch-path $(TOOLS)/swift-protobuf-build --product protoc-gen-swift
	mkdir -p $(TOOLS)
	cp $(TOOLS)/swift-protobuf-build/release/protoc-gen-swift $@

proto: $(PROTOC_GEN_SWIFT) ## Regenerate Sources/DMCNKit/Proto from proto/ (requires buf)
	rm -f Sources/DMCNKit/Proto/*.pb.swift
	buf generate

proto-sync: ## Copy the pinned open-dmcn schema into proto/, then regenerate
	dev/open-dmcn.sh sync
	$(MAKE) proto

proto-sync-check: ## Fail unless proto/ is byte-identical to the pinned open-dmcn schema
	dev/open-dmcn.sh check

icons: ## Regenerate the icon set from the web client's Icon.tsx
	dev/generate-icons.py
	$(SWIFT) format --in-place --configuration .swift-format App/Shared/DesignSystem/Icon.swift

notices: ## Regenerate App/Resources/ThirdPartyNotices.txt from Package.resolved
	dev/third-party-notices.sh

notices-check:
	dev/third-party-notices.sh --check

go-fixture: ## Re-seal the Go fixture with the pinned open-dmcn (requires go)
	dev/go-fixture.sh

# Generated code is excluded: it is rewritten by `make proto`, never by hand.
SWIFT_SOURCES = Package.swift $(shell find Sources App Tests -name '*.swift' -not -path '*/Proto/*')

format: ## Reformat every hand-written Swift file
	$(SWIFT) format --in-place $(SWIFT_SOURCES)

format-check: ## Fail if a hand-written Swift file isn't formatted
	$(SWIFT) format lint --strict $(SWIFT_SOURCES)

app: ## Build the iOS app for the simulator (requires Xcode)
	xcodebuild -project App/OpenDMCN.xcodeproj -scheme OpenDMCN \
		-destination '$(IOS_DESTINATION)' CODE_SIGNING_ALLOWED=NO build

clean:
	rm -rf .build
