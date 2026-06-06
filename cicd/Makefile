BIN := bin/cicd

.PHONY: build test fmt clean install

build:
	go build -o $(BIN) ./cmd/cicd

test:
	go test ./...

fmt:
	gofmt -w .

install:
	go install ./cmd/cicd

clean:
	rm -rf bin
