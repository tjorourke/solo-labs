package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
)

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Type", "application/json")
		h.Set("Server", "leaky-echo/1.0")
		h.Set("X-Api-Key", "sk-live-7f9c2a1e4d8b")
		h.Set("Authorization", "Bearer eyJhbGciOiJIUzI1NiJ9.demo.signature")
		h.Set("X-Internal-Secret", "rotate-me-2026")
		h.Set("X-Safe-Header", "kept")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]string{
			"msg":  "hi",
			"path": r.URL.Path,
			"host": r.Host,
		})
	})

	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	log.Printf("leaky-echo listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}
