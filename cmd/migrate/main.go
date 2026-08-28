package main 

import (
	"context"
	"fmt"
	"os"
	"sluice/internal/config"
	"sluice/internal/store"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintln(os.Stderr, "config error:", err)
		os.Exit(1)
	}

	ctx, cancle := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancle()

	pool, err := pgxpool.New(ctx, cfg.DatabaseURL)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Failed to connect to the DB ", err)
		os.Exit(1)
	}
	defer pool.Close()

	if err:= store.Migrate(ctx,pool); err != nil{
		fmt.Fprintln(os.Stderr, "migration failed", err)
		os.Exit(1)
	}
	fmt.Println("migration applied")	
}
