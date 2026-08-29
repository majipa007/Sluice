package api

import (
	"context"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type Handler struct{
	pool *pgxpool.Pool 
}

func Healthz(w http.ResponseWriter, r *http.Request){
	w.WriteHeader(http.StatusOK)
}

func (h *Handler) Readyz(w http.ResponseWriter, r *http.Request){
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()

	if err := h.pool.Ping(ctx); err != nil{
		w.WriteHeader(http.StatusServiceUnavailable)
		w.Write([]byte(`{"postgres":"down"}`))
		return
	}
	w.WriteHeader(http.StatusOK)
}
