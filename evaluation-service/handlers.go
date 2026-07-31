package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"time"
)

type EvaluationResponse struct {
	FlagName string `json:"flag_name"`
	UserID   string `json:"user_id"`
	Result   bool   `json:"result"`
}

func (a *App) healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

func (a *App) evaluationHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	// 1. Parsear os query parameters
	userID := r.URL.Query().Get("user_id")
	flagName := r.URL.Query().Get("flag_name")

	if userID == "" || flagName == "" {
		http.Error(w, `{"error": "user_id e flag_name são obrigatórios"}`, http.StatusBadRequest)
		return
	}

	// 2. Obter a decisão (lógica de cache/serviço está em evaluator.go)
	authHeader := r.Header.Get("Authorization")
	if authHeader == "" {
		http.Error(
			w,
			`{"error": "Authorization header obrigatório"}`,
			http.StatusUnauthorized,
		)
		return
	}

	result, err := a.getDecision(userID, flagName, authHeader)
	if err != nil {
		// Se o erro for "não encontrado", retornamos 'false' (comportamento seguro)
		if _, ok := err.(*NotFoundError); ok {
			result = false
		} else {
			// Outros erros (serviços offline, etc)
			log.Printf("Erro ao avaliar flag '%s': %v", flagName, err)
			http.Error(w, `{"error": "Erro interno ao avaliar a flag"}`, http.StatusBadGateway)
			return
		}
	}

	// 3. Enviar evento para SQS (assincronamente)
	// Isso não bloqueia a resposta para o cliente.
	eventCtx := context.WithoutCancel(r.Context())
	go func() {
		ctx, cancel := context.WithTimeout(eventCtx, 10*time.Second)
		defer cancel()
		a.sendEvaluationEvent(ctx, userID, flagName, result)
	}()

	// 4. Retornar a resposta
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(EvaluationResponse{
		FlagName: flagName,
		UserID:   userID,
		Result:   result,
	})
}
