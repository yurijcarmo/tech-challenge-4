.PHONY: setup-dev validate-base validate-observability validate-otel-collector validate-go-telemetry validate-python-telemetry validate-apm validate-grafana-dashboard validate-alert-rules validate-incident-chatops validate-self-healing validate-incident-demo validate notification-fire notification-resolve notification-demo incident-demo telemetry-demo telemetry-application telemetry-synthetic

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

validate-alert-rules:
	bash scripts/validate-alert-rules.sh

validate-incident-chatops:
	bash scripts/validate-incident-chatops.sh

validate-self-healing:
	bash scripts/validate-self-healing.sh

validate-incident-demo:
	bash scripts/validate-incident-demo.sh

validate: validate-base validate-observability validate-otel-collector validate-go-telemetry validate-python-telemetry validate-apm validate-grafana-dashboard validate-alert-rules validate-incident-chatops validate-self-healing validate-incident-demo

notification-fire:
	bash scripts/run-notification-test.sh fire

notification-resolve:
	bash scripts/run-notification-test.sh resolve

notification-demo:
	bash scripts/run-notification-test.sh demo

incident-demo:
	bash scripts/run-incident-demo.sh

telemetry-synthetic:
	bash scripts/run-telemetry-demo.sh synthetic

telemetry-application:
	bash scripts/run-telemetry-demo.sh application

telemetry-demo:
	bash scripts/run-telemetry-demo.sh demo
