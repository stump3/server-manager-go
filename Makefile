BINARY     := server-manager
BUILD_DIR  := dist
CMD_PATH   := ./cmd/server-manager

VERSION    := $(shell git describe --tags --always --dirty 2>/dev/null || date +v%Y%m%d)
LDFLAGS    := -X main.version=$(VERSION) -s -w

.PHONY: all build build-linux build-linux-arm64 tidy lint vet \
        test test-unit test-contract test-integration test-e2e \
        clean install

all: build

## build: compile for current OS/arch
build:
	@mkdir -p $(BUILD_DIR)
	go build -ldflags "$(LDFLAGS)" -o $(BUILD_DIR)/$(BINARY) $(CMD_PATH)
	@echo "Built: $(BUILD_DIR)/$(BINARY)"

## build-linux: static Linux amd64 binary (no CGO, for deployment)
build-linux:
	@mkdir -p $(BUILD_DIR)
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
		go build -ldflags "$(LDFLAGS)" -o $(BUILD_DIR)/$(BINARY)-linux-amd64 $(CMD_PATH)
	@echo "Built: $(BUILD_DIR)/$(BINARY)-linux-amd64"

## build-linux-arm64: static Linux arm64 binary
build-linux-arm64:
	@mkdir -p $(BUILD_DIR)
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
		go build -ldflags "$(LDFLAGS)" -o $(BUILD_DIR)/$(BINARY)-linux-arm64 $(CMD_PATH)

## tidy: tidy and verify go.mod / go.sum
tidy:
	go mod tidy
	go mod verify

## lint: run golangci-lint
lint:
	golangci-lint run ./...

## vet: run go vet on all packages
vet:
	go vet ./...

## test: unit + contract tests (no build tags required)
test: vet
	go test -race -count=1 ./...

## test-unit: short unit tests only
test-unit:
	go test -race -count=1 -short ./...

## test-contract: port contract tests for Runner and FS
test-contract:
	go test -race -count=1 -run Contract ./test/contracts/... \
	    ./internal/infra/runner/... ./internal/infra/fs/...

## test-integration: requires real system (Linux, bash, no Docker needed)
test-integration:
	go test -tags integration -race -count=1 -v ./test/integration/...

## test-e2e: requires SM_E2E_HOST set to a real Linux server
## Usage: SM_E2E_HOST=1.2.3.4 SM_E2E_KEY=~/.ssh/id_ed25519 make test-e2e
test-e2e:
	go test -tags e2e -race -count=1 -v -timeout=15m ./test/e2e/...

## install: build static binary and install to /usr/local/bin
install: build-linux
	install -m 0755 $(BUILD_DIR)/$(BINARY)-linux-amd64 /usr/local/bin/$(BINARY)
	@echo "Installed: /usr/local/bin/$(BINARY)"

## clean: remove build artifacts
clean:
	rm -rf $(BUILD_DIR)
