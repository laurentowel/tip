.PHONY: server server-debug docker clean test test-rust test-emacs

CARGO ?= cargo
DOCKER ?= docker
DOCKER_IMAGE ?= tip-server-typst:latest

server:
	cd tip-server && $(CARGO) build --release

server-debug:
	cd tip-server && $(CARGO) build

docker:
	cd tip-server && $(DOCKER) build -t $(DOCKER_IMAGE) .

test-rust:
	cd tip-server && $(CARGO) test

test-emacs:
	emacs --batch -l test-tip.el

test: test-rust test-emacs

clean:
	cd tip-server && $(CARGO) clean
