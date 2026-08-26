package store

import (
	"context"
	"sluice/migrations"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
)


func Migrate(ctx context.Context, pool *pgxpool.Pool) error {
	goose.SetBaseFS(migrations.FS)

	if err:= goose.SetDialect("postgres"); err !=nil{
		return err
	}

	db:= stdlib.OpenDBFromPool(pool)
	defer db.Close()

	return goose.UpContext(ctx, db , "migrations")
}
