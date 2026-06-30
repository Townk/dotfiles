.PHONY: test lint

test: lint
	shellspec

# Guard the single-source theme: no raw hex outside .chezmoidata/theme.yaml.
lint:
	@bash tests/lint-theme.sh
