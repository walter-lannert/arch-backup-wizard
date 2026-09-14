.PHONY: check

check:
	shellcheck -x wizard.sh lib/*.sh
