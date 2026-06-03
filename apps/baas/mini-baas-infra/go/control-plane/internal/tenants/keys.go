package tenants

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base32"
	"errors"
	"strings"

	"golang.org/x/crypto/argon2"
)

// API key format: mbk_<prefix>_<payload>
//   prefix : 12 chars base32 (no padding, lowercase). Searchable.
//   payload: 32 chars base32. Hashed; never stored in cleartext.
//
// Total user-visible key length: 4 + 12 + 1 + 32 = 49 chars.

const (
	keyHeader    = "mbk_"
	prefixLen    = 12
	payloadBytes = 20 // 20 raw bytes -> 32 base32 chars
)

var b32 = base32.StdEncoding.WithPadding(base32.NoPadding)

// generateKey returns a (prefix, fullKey) pair plus an argon2id hash of the
// payload portion. The payload is what gets hashed — the prefix is in
// cleartext so we can look it up cheaply.
func generateKey() (prefix, fullKey, hash string, err error) {
	pBytes := make([]byte, (prefixLen*5+7)/8) // ~8 bytes -> 12 base32 chars
	if _, err = rand.Read(pBytes); err != nil {
		return "", "", "", err
	}
	prefix = strings.ToLower(b32.EncodeToString(pBytes))[:prefixLen]

	payload := make([]byte, payloadBytes)
	if _, err = rand.Read(payload); err != nil {
		return "", "", "", err
	}
	payloadStr := strings.ToLower(b32.EncodeToString(payload))

	fullKey = keyHeader + prefix + "_" + payloadStr
	hash = hashPayload(payloadStr, prefix)
	return prefix, fullKey, hash, nil
}

// parseKey splits a "mbk_<prefix>_<payload>" key. Returns errInvalidFormat on
// any structural problem; the caller must not leak whether the prefix or the
// payload was the wrong shape (timing-sensitive).
func parseKey(full string) (prefix, payload string, err error) {
	if !strings.HasPrefix(full, keyHeader) {
		return "", "", errInvalidFormat
	}
	rest := full[len(keyHeader):]
	parts := strings.SplitN(rest, "_", 2)
	if len(parts) != 2 || len(parts[0]) != prefixLen {
		return "", "", errInvalidFormat
	}
	if len(parts[1]) < 16 || len(parts[1]) > 64 {
		return "", "", errInvalidFormat
	}
	return parts[0], parts[1], nil
}

// hashPayload runs argon2id over (payload || prefix). The prefix doubles as
// the salt so the same payload string yields different hashes per key, but
// we don't need to store a separate salt column.
func hashPayload(payload, prefix string) string {
	const (
		timeCost   = 1
		memoryCost = 32 * 1024 // 32 MiB
		threads    = 2
		outputLen  = 32
	)
	salt := []byte("mbk-v1-" + prefix)
	sum := argon2.IDKey([]byte(payload), salt, timeCost, memoryCost, threads, outputLen)
	return "argon2id$v=1$m=32768,t=1,p=2$" + b32.EncodeToString(salt) + "$" + b32.EncodeToString(sum)
}

// verifyKeyHash returns true iff the payload+prefix recompute to the stored
// hash. Uses constant-time compare on the inner bytes.
func verifyKeyHash(payload, prefix, storedHash string) bool {
	expected := hashPayload(payload, prefix)
	if len(expected) != len(storedHash) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(expected), []byte(storedHash)) == 1
}

var errInvalidFormat = errors.New("api key has invalid format")
