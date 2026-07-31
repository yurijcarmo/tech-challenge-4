package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strings"
)

const (
	failureInjectionHeader = "X-ToggleMaster-Failure-Test"
	failureInjectionToken  = "phase-4-demo"
)

func failureInjectionHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	if !strings.EqualFold(os.Getenv("ENABLE_FAILURE_INJECTION"), "true") {
		http.NotFound(w, r)
		return
	}

	if r.Header.Get(failureInjectionHeader) != failureInjectionToken {
		http.Error(w, "failure injection header is required", http.StatusForbidden)
		return
	}

	log.Printf(
		`{"event":"failure_injection_triggered","service":"auth-service","path":"%s"}`,
		r.URL.Path,
	)

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusInternalServerError)
	_ = json.NewEncoder(w).Encode(map[string]string{
		"error":   "intentional_failure",
		"purpose": "observability_and_self_healing_demo",
	})
}
