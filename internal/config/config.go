// Package config reads environment variables into a typed struct, applies
// defaults, and validates the cross-field invariants that must hold before the
// process is allowed to start. Hand-written rather than viper/envconfig because
// the interesting checks compare one setting against another, which a generic
// loader cannot express. Defaults mirror the table in README.MD.
package config

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"time"
)

// ErrMissingDatabaseURL is returned when DATABASE_URL is unset or empty.
// A sentinel so callers can react with errors.Is rather than matching on text.
var ErrMissingDatabaseURL = errors.New("DATABASE_URL is not set")

type Config struct {
	PrefetchCount      int
	MaxAttempts        int
	LeaseTTL           time.Duration
	LeaseRenewInterval time.Duration
	ReaperInterval     time.Duration
	JobDeadlineDefault time.Duration
	ConsumerTimeout    time.Duration
	ShedQueueDepth     int
	ShutdownGrace      time.Duration
	DatabaseURL        string
}

// Load reads the environment, falls back to defaults, and validates. Any error
// it returns is a reason not to boot.
func Load() (*Config, error) {
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		return nil, ErrMissingDatabaseURL
	}

	c := &Config{DatabaseURL: databaseURL}

	var err error
	if c.PrefetchCount, err = envInt("PREFETCH_COUNT", 1); err != nil {
		return nil, err
	}
	if c.MaxAttempts, err = envInt("MAX_ATTEMPTS", 3); err != nil {
		return nil, err
	}
	if c.ShedQueueDepth, err = envInt("SHED_QUEUE_DEPTH", 1000); err != nil {
		return nil, err
	}
	if c.LeaseTTL, err = envDuration("LEASE_TTL", 30*time.Second); err != nil {
		return nil, err
	}
	if c.LeaseRenewInterval, err = envDuration("LEASE_RENEW_INTERVAL", 10*time.Second); err != nil {
		return nil, err
	}
	if c.ReaperInterval, err = envDuration("REAPER_INTERVAL", 10*time.Second); err != nil {
		return nil, err
	}
	if c.JobDeadlineDefault, err = envDuration("JOB_DEADLINE_DEFAULT", 5*time.Minute); err != nil {
		return nil, err
	}
	if c.ConsumerTimeout, err = envDuration("CONSUMER_TIMEOUT", 15*time.Minute); err != nil {
		return nil, err
	}
	if c.ShutdownGrace, err = envDuration("SHUTDOWN_GRACE", 90*time.Second); err != nil {
		return nil, err
	}

	if err := c.Validate(); err != nil {
		return nil, err
	}
	return c, nil
}

// Validate enforces the three boot invariants. Separated from Load so tests can
// build a Config directly without touching the environment.
func (c *Config) Validate() error {
	if c.LeaseRenewInterval >= c.LeaseTTL/2 {
		return fmt.Errorf("LEASE_RENEW_INTERVAL (%s) must be < LEASE_TTL/2 (%s): "+
			"a single missed renewal would expire a live lease",
			c.LeaseRenewInterval, c.LeaseTTL/2)
	}
	if c.ConsumerTimeout <= c.JobDeadlineDefault {
		return fmt.Errorf("CONSUMER_TIMEOUT (%s) must exceed JOB_DEADLINE_DEFAULT (%s): "+
			"the broker would kill the channel mid-job",
			c.ConsumerTimeout, c.JobDeadlineDefault)
	}
	if c.ShutdownGrace <= c.JobDeadlineDefault {
		return fmt.Errorf("SHUTDOWN_GRACE (%s) must exceed JOB_DEADLINE_DEFAULT (%s): "+
			"in-flight jobs would be killed instead of drained",
			c.ShutdownGrace, c.JobDeadlineDefault)
	}
	return nil
}

// envDuration returns def when key is unset, the parsed value when it is valid,
// and an error when it is set to something unparseable.
func envDuration(key string, def time.Duration) (time.Duration, error) {
	v := os.Getenv(key)
	if v == "" {
		return def, nil
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return 0, fmt.Errorf("%s: %w", key, err)
	}
	return d, nil
}

// envInt is envDuration for integers.
func envInt(key string, def int) (int, error) {
	v := os.Getenv(key)
	if v == "" {
		return def, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return 0, fmt.Errorf("%s: %w", key, err)
	}
	return n, nil
}
