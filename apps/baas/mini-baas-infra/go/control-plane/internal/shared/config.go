// Package shared holds cross-service plumbing for the Go control plane:
// config loading, structured logging, the Postgres pool, and HTTP middleware.
package shared

import (
	"fmt"
	"os"
)

// weakServiceToken is the compose default-of-last-resort. A service must NOT
// boot with it (or an empty token): the internal service-token guard would then
// trust a publicly-known value, defeating control-plane auth. The real fallback
// is JWT_SECRET (a strong secret), which is accepted.
const weakServiceToken = "dev-service-token-change-me"

// Config is the common runtime configuration for a control-plane service.
type Config struct {
	Host         string
	Port         string
	DatabaseURL  string
	ServiceToken string
	ProductMode  string
}

// LoadConfig reads <PREFIX>_HOST / <PREFIX>_PORT and shared DATABASE_URL.
// Example prefix: "ADAPTER_REGISTRY".
func LoadConfig(prefix string) (Config, error) {
	cfg := Config{
		Host:         envDefault(prefix+"_HOST", "0.0.0.0"),
		Port:         envDefault(prefix+"_PORT", "3021"),
		DatabaseURL:  os.Getenv("DATABASE_URL"),
		ServiceToken: os.Getenv("INTERNAL_SERVICE_TOKEN"),
		ProductMode:  envDefault(prefix+"_PRODUCT_MODE", "shadow"),
	}
	if cfg.DatabaseURL == "" {
		return Config{}, fmt.Errorf("DATABASE_URL is required")
	}
	if cfg.ServiceToken == "" || cfg.ServiceToken == weakServiceToken {
		return Config{}, fmt.Errorf(
			"INTERNAL_SERVICE_TOKEN must be set to a strong value (refusing empty or the placeholder %q); "+
				"the live stack derives it from JWT_SECRET — set JWT_SECRET or ADAPTER_REGISTRY_SERVICE_TOKEN",
			weakServiceToken)
	}
	return cfg, nil
}

// ListenAddr returns host:port for http.Server.
func (c Config) ListenAddr() string {
	return c.Host + ":" + c.Port
}

func envDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
