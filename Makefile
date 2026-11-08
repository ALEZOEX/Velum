.PHONY: core xray daemon daemon-windows test test-windows test-network
core:
	GOBIN=$(CURDIR)/bin go install -ldflags "-X github.com/sagernet/sing-box/constant.Version=1.12.12" -tags with_utls,with_quic,with_clash_api github.com/sagernet/sing-box/cmd/sing-box@v1.12.12
daemon:
	cd daemon && go build -o ../bin/velumd .
daemon-windows:
	cd daemon && CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -ldflags "-s -w" -o ../bin/velumd.exe .
test:
	cd daemon && go test -race -v ./... && go vet ./...
test-windows:
	cd daemon && GOOS=windows GOARCH=amd64 go vet ./...

test-network: daemon
	python3 scripts/test-linux-network.py

xray:
	python3 scripts/fetch-xray.py
