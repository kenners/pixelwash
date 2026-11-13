# Pixelwash build. Run `make help` for the targets.
CONFIG       ?= release
ENTITLEMENTS := Resources/pixelwash.entitlements
IMAGE_TAG    := pixelwash-sandbox:latest
IMAGE_TAR    := build/pixelwash-sandbox.tar
PREFIX       ?= $(HOME)/.local
SIGN         := codesign --force --sign - --entitlements $(ENTITLEMENTS)

.PHONY: help build test integration-test image setup app install

help:
	@echo "make image             build the sandbox image (needs: container system start)"
	@echo "make build             build and sign build/pixelwash"
	@echo "make setup             install kernel, init image and sandbox image for this user"
	@echo "make app               build build/Pixelwash.app"
	@echo "make install           copy pixelwash to $(PREFIX)/bin and the app to /Applications"
	@echo "make test              run unit tests"
	@echo "make integration-test  also run real conversions in the sandbox (after make setup)"

build:
	swift build -c $(CONFIG)
	mkdir -p build
	cp "$$(swift build -c $(CONFIG) --show-bin-path)/pixelwash" build/pixelwash
	$(SIGN) build/pixelwash

test:
	swift test

# Real conversions through the signed command-line tool (after `make setup`).
integration-test: build
	scripts/integration-test.sh

image:
	mkdir -p build
	container build -t $(IMAGE_TAG) -f image/Containerfile image
	container image save -o $(IMAGE_TAR) $(IMAGE_TAG)

setup: build
	build/pixelwash setup --image $(IMAGE_TAR)

app: build
	scripts/make-app.sh "$$(swift build -c $(CONFIG) --show-bin-path)/PixelwashApp" build/Pixelwash.app

install: app
	mkdir -p "$(PREFIX)/bin"
	cp build/pixelwash "$(PREFIX)/bin/pixelwash"
	ditto build/Pixelwash.app /Applications/Pixelwash.app
