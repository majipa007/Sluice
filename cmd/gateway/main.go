package main 

import (
	"fmt"
	"net/http"
	"sluice/internal/api"
	"sluice/internal/config"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
)

func main() {
	cfg, err :=config.Load()
	h := &api.Handler{}
	if err!=nil{
		fmt.Printf("err: %s", err)
	}
	r := chi.NewRouter()
	r.Use(middleware.Logger)
	r.Get("/", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("Hello World"))
	})
	r.Get("/health", api.Healthz)
	r.Get("/ready", h.Readyz)
	http.ListenAndServe(cfg.HttpAddr, r)
}
