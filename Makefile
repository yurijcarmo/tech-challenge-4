.PHONY: setup-dev validate-base validate-observability validate-otel-collector validate-go-telemetry validate-python-telemetry validate-apm validate-grafana-dashboard validate

setup-dev:
	python3 -m venv .venv
	.venv/bin/python -m pip install -r requirements-dev.txt

validate-base:
	bash scripts/validate-base.sh

validate-observability:
	bash scripts/validate-observability.sh

validate-otel-collector:
	bash scripts/validate-otel-collector.sh

validate-go-telemetry:
	bash scripts/validate-go-telemetry.sh

validate-python-telemetry:
	bash scripts/validate-python-telemetry.sh

validate-apm:
	bash scripts/validate-apm.sh

validate-grafana-dashboard:
	bash scripts/validate-grafana-dashboard.sh

validate: validate-base validate-observability validate-otel-collector validate-go-telemetry validate-python-telemetry validate-apm validate-grafana-dashboard
