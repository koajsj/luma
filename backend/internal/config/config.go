package config

import (
	"errors"
	"net/netip"
	"os"
	"strconv"
)

type Config struct {
	Addr, DatabaseURL, RedisURL, S3Endpoint, S3Bucket, S3AccessKey, S3SecretKey, PublicBaseURL, MigrationsDir, LocalStorageDir string
	TLSCert, TLSKey                                                                                                            string
	UserIDHMACSecret                                                                                                           string
	TrustedProxyIP                                                                                                             netip.Addr
	S3Secure, AllowInsecureLocal                                                                                               bool
}

func get(k, fallback string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return fallback
}
func Load() (Config, error) {
	c := Config{Addr: get("LUMA_ADDR", ":8080"), DatabaseURL: os.Getenv("DATABASE_URL"), RedisURL: get("REDIS_URL", "redis://localhost:6379/0"), S3Endpoint: os.Getenv("S3_ENDPOINT"), S3Bucket: get("S3_BUCKET", "luma-ciphertext"), S3AccessKey: os.Getenv("S3_ACCESS_KEY"), S3SecretKey: os.Getenv("S3_SECRET_KEY"), PublicBaseURL: os.Getenv("PUBLIC_BASE_URL"), MigrationsDir: get("MIGRATIONS_DIR", "migrations"), LocalStorageDir: os.Getenv("LOCAL_STORAGE_DIR"), TLSCert: os.Getenv("TLS_CERT_FILE"), TLSKey: os.Getenv("TLS_KEY_FILE")}
	c.UserIDHMACSecret = os.Getenv("LUMA_USERID_HMAC_SECRET")
	if raw := os.Getenv("LUMA_TRUSTED_PROXY_IP"); raw != "" {
		var err error
		c.TrustedProxyIP, err = netip.ParseAddr(raw)
		if err != nil || c.TrustedProxyIP.IsUnspecified() {
			return c, errors.New("invalid LUMA_TRUSTED_PROXY_IP")
		}
	}
	b, _ := strconv.ParseBool(get("S3_SECURE", "true"))
	c.S3Secure = b
	c.AllowInsecureLocal, _ = strconv.ParseBool(os.Getenv("LUMA_ALLOW_INSECURE_LOCAL"))
	if c.TLSCert == "" && !c.AllowInsecureLocal {
		return c, errors.New("TLS required; set LUMA_ALLOW_INSECURE_LOCAL=true only for local development")
	}
	if c.DatabaseURL == "" {
		return c, errors.New("DATABASE_URL required")
	}
	if (c.TLSCert == "") != (c.TLSKey == "") {
		return c, errors.New("TLS cert and key must both be set")
	}
	return c, nil
}
