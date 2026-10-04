.PHONY: build check test clean

build:
	scripts/build.sh

# Compile without warnings, smoke-test the client against the example snapshot,
# and lint the shell script. Needs no root, no signing, no daemon.
check:
	/usr/bin/swiftc -O -warnings-as-errors src/smcfan.swift -o build/smcfan-check
	build/smcfan-check help > /dev/null
	build/smcfan-check status --state examples/state-m4max.json > /dev/null
	build/smcfan-check status --state examples/state-m4max.json --json | /usr/bin/python3 -m json.tool > /dev/null
	bash -n scripts/build.sh
	@command -v shellcheck > /dev/null && shellcheck scripts/build.sh || true
	@echo "check: ok"

# End-to-end: real daemon + client against the in-memory FakeSMC. No root.
test: check
	SMCFAN_BIN=build/smcfan-check /usr/bin/python3 -m unittest discover -s tests -v

clean:
	rm -rf build
