package main

import (
	"context"
	"encoding/json"
	"log"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/service/sqs"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
)

// Evento que será enviado para a fila
type EvaluationEvent struct {
	UserID    string    `json:"user_id"`
	FlagName  string    `json:"flag_name"`
	Result    bool      `json:"result"`
	Timestamp time.Time `json:"timestamp"`
}

// sendEvaluationEvent envia um evento para a fila SQS
func (a *App) sendEvaluationEvent(ctx context.Context, userID, flagName string, result bool) {
	if a.SqsSvc == nil || a.SqsQueueURL == "" {
		log.Printf("[SQS_DISABLED] Evento: User '%s', Flag '%s', Result '%t'", userID, flagName, result)
		return
	}

	ctx, span := otel.Tracer(instrumentationName).Start(
		ctx,
		"SQS SendMessage",
		trace.WithSpanKind(trace.SpanKindProducer),
		trace.WithAttributes(
			attribute.String("messaging.system", "aws_sqs"),
			attribute.String("messaging.destination.name", "analytics-queue"),
			attribute.String("messaging.operation", "publish"),
		),
	)
	defer span.End()

	event := EvaluationEvent{
		UserID:    userID,
		FlagName:  flagName,
		Result:    result,
		Timestamp: time.Now().UTC(),
	}

	body, err := json.Marshal(event)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "erro ao serializar evento")
		log.Printf("Erro ao serializar evento SQS: %v", err)
		return
	}

	carrier := propagation.MapCarrier{}
	otel.GetTextMapPropagator().Inject(ctx, carrier)

	messageAttributes := make(map[string]*sqs.MessageAttributeValue, len(carrier))
	for key, value := range carrier {
		messageAttributes[key] = &sqs.MessageAttributeValue{
			DataType:    aws.String("String"),
			StringValue: aws.String(value),
		}
	}

	_, err = a.SqsSvc.SendMessageWithContext(ctx, &sqs.SendMessageInput{
		MessageBody:       aws.String(string(body)),
		MessageAttributes: messageAttributes,
		QueueUrl:          aws.String(a.SqsQueueURL),
	})
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "erro ao enviar evento para SQS")
		log.Printf("Erro ao enviar mensagem para SQS: %v", err)
		return
	}

	span.SetStatus(codes.Ok, "evento enviado")
	log.Printf("Evento de avaliação enviado para SQS (Flag: %s)", flagName)
}
