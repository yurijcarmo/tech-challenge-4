.PHONY: setup-dev validate-base validate-observability validate

setup-dev:
	python3 -m venv .venv
	.venv/bin/python -m pip install -r requirements-dev.txt

validate-base:
	bash scripts/validate-base.sh

validate-observability:
	bash scripts/validate-observability.sh

validate: validate-base validate-observability
