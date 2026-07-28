.PHONY: setup-dev validate-base

setup-dev:
	python3 -m venv .venv
	.venv/bin/python -m pip install -r requirements-dev.txt

validate-base:
	bash scripts/validate-base.sh
