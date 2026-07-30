package main

import (
	"context"
	"errors"
	"net/http"
	"os"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.30.0"
)

const instrumentationName = "togglemaster/auth-service"

type Telemetry struct {
	tracerProvider  *sdktrace.TracerProvider
	meterProvider   *sdkmetric.MeterProvider
	requestCounter  metric.Int64Counter
	requestDuration metric.Float64Histogram
	serviceName     string
}

func setupTelemetry(ctx context.Context, defaultServiceName string) (*Telemetry, error) {
	serviceName := os.Getenv("OTEL_SERVICE_NAME")
	if serviceName == "" {
		serviceName = defaultServiceName
	}

	res, err := resource.Merge(
		resource.Default(),
		resource.NewWithAttributes(
			semconv.SchemaURL,
			semconv.ServiceName(serviceName),
		),
	)
	if err != nil {
		return nil, err
	}

	traceExporter, err := otlptracegrpc.New(ctx, otlptracegrpc.WithInsecure())
	if err != nil {
		return nil, err
	}

	tracerProvider := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(traceExporter),
		sdktrace.WithResource(res),
		sdktrace.WithSampler(sdktrace.ParentBased(sdktrace.AlwaysSample())),
	)

	metricExporter, err := otlpmetricgrpc.New(ctx, otlpmetricgrpc.WithInsecure())
	if err != nil {
		_ = tracerProvider.Shutdown(context.Background())
		return nil, err
	}

	meterProvider := sdkmetric.NewMeterProvider(
		sdkmetric.WithResource(res),
		sdkmetric.WithReader(
			sdkmetric.NewPeriodicReader(metricExporter, sdkmetric.WithInterval(15*time.Second)),
		),
	)

	otel.SetTracerProvider(tracerProvider)
	otel.SetMeterProvider(meterProvider)
	otel.SetTextMapPropagator(
		propagation.NewCompositeTextMapPropagator(
			propagation.TraceContext{},
			propagation.Baggage{},
		),
	)

	meter := meterProvider.Meter(instrumentationName)
	requestCounter, err := meter.Int64Counter(
		"togglemaster_http_server_requests",
		metric.WithDescription("Total de requisições HTTP recebidas pelo serviço"),
		metric.WithUnit("{request}"),
	)
	if err != nil {
		_ = meterProvider.Shutdown(context.Background())
		_ = tracerProvider.Shutdown(context.Background())
		return nil, err
	}

	requestDuration, err := meter.Float64Histogram(
		"togglemaster_http_server_request_duration",
		metric.WithDescription("Duração das requisições HTTP recebidas pelo serviço"),
		metric.WithUnit("s"),
	)
	if err != nil {
		_ = meterProvider.Shutdown(context.Background())
		_ = tracerProvider.Shutdown(context.Background())
		return nil, err
	}

	return &Telemetry{
		tracerProvider:  tracerProvider,
		meterProvider:   meterProvider,
		requestCounter:  requestCounter,
		requestDuration: requestDuration,
		serviceName:     serviceName,
	}, nil
}

func (t *Telemetry) Shutdown(ctx context.Context) error {
	return errors.Join(
		t.meterProvider.Shutdown(ctx),
		t.tracerProvider.Shutdown(ctx),
	)
}

func (t *Telemetry) HTTPHandler(next http.Handler) http.Handler {
	return otelhttp.NewHandler(
		t.metricsMiddleware(next),
		t.serviceName,
		otelhttp.WithSpanNameFormatter(func(_ string, r *http.Request) string {
			return r.Method + " " + r.URL.Path
		}),
	)
}

func (t *Telemetry) metricsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		startedAt := time.Now()
		response := &statusRecorder{ResponseWriter: w, statusCode: http.StatusOK}

		next.ServeHTTP(response, r)

		route := r.URL.Path
		if route == "" {
			route = r.URL.Path
		}

		attrs := []attribute.KeyValue{
			attribute.String("http.request.method", r.Method),
			attribute.String("http.route", route),
			attribute.Int("http.response.status_code", response.statusCode),
		}

		t.requestCounter.Add(r.Context(), 1, metric.WithAttributes(attrs...))
		t.requestDuration.Record(
			r.Context(),
			time.Since(startedAt).Seconds(),
			metric.WithAttributes(attrs...),
		)
	})
}

type statusRecorder struct {
	http.ResponseWriter
	statusCode  int
	wroteHeader bool
}

func (r *statusRecorder) WriteHeader(statusCode int) {
	if r.wroteHeader {
		return
	}

	r.statusCode = statusCode
	r.wroteHeader = true
	r.ResponseWriter.WriteHeader(statusCode)
}

func (r *statusRecorder) Write(body []byte) (int, error) {
	if !r.wroteHeader {
		r.WriteHeader(http.StatusOK)
	}
	return r.ResponseWriter.Write(body)
}
