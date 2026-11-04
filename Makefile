.PHONY: core xray daemon test test-network
core:
	GOBIN=$(CURDIR)/bin go install -ldflags "-X github.com/sagernet/sing-box/constant.Version=1.12.12" -tags with_utls,with_quic,with_clash_api github.com/sagernet/sing-box/cmd/sing-box@v1.12.12
daemon:
	cd daemon && go build -o ../bin/velumd .
test:
	cd daemon && go test -race -v ./... && go vet ./...

test-network: daemon
	python3 scripts/test-linux-network.py

xray:
	python3 scripts/fetch-xray.py
