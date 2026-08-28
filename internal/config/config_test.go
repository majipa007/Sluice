package config

import (
	"testing"
	"time"
)

func TestValidate(t *testing.T) {
	base := func() Config {
		return Config{
			LeaseTTL:           30 * time.Second,
			LeaseRenewInterval: 10 * time.Second,
			JobDeadlineDefault: 5 * time.Minute,
			ConsumerTimeout:    15 * time.Minute,
			ShutdownGrace:      6 * time.Minute,
		}
	}

	tests := []struct {
		name    string
		mutate  func(c *Config)
		wantErr bool
	}{
		{
			name:    "valid defaults",
			mutate:  func(c *Config) {},
			wantErr: false,
		},
		{
			name: "renew internal too close to lease ttl",
			mutate: func(c *Config) {
				c.LeaseRenewInterval = c.LeaseTTL / 2
			},
			wantErr: true,
		},
		{
			name: "consumer timeout does not exceed job deadline",
			mutate: func(c *Config) {
				c.ConsumerTimeout = c.JobDeadlineDefault
			},
			wantErr: true,
		},
		{
			name: "shutdown grace does not exceed job deadline",
			mutate: func(c *Config) {
				c.ShutdownGrace = c.JobDeadlineDefault
			},
			wantErr: true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			c := base()
			tc.mutate(&c)
			err := c.Validate()
			if (err != nil) != tc.wantErr {
				t.Errorf("Validate() error = %v, wantErr %v", err, tc.wantErr)
			}
		})
	}
}
