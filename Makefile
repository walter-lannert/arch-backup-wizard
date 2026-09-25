.PHONY: all check test

all: check test

check:
	shellcheck -x wizard.sh lib/*.sh templates/*.sh tests/*.sh tests/*.bash
	@if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then git diff --check; fi

test:
	@for t in tests/test_*.sh; do \
		echo "Running $$t..."; \
		bash "$$t" || exit 1; \
	done
