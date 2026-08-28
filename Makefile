.PHONY: registry registry-check test test-fast test-full

registry:
	./bin/build-registry.sh

registry-check:
	./bin/build-registry.sh --check

# Routine developer loop: build/artifact correctness plus essential smoke
# coverage. Use this for skill-content edits (commands-src/, _shared/).
test: test-fast

test-fast:
	./bin/build-registry.sh --check
	./tests/run.sh --fast

# Everything: the full integration and lifecycle suite. Required for changes to
# bin/, tests/, bin/targets/, or anything touching lifecycle, Git update,
# sync/bootstrap, or target adapters.
test-full:
	./bin/build-registry.sh --check
	./tests/run.sh --full
