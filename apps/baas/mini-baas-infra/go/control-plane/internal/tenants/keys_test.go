package tenants

import (
	"strings"
	"testing"
)

func TestGenerateKey_FormatAndUniqueness(t *testing.T) {
	prefixA, fullA, hashA, err := generateKey()
	if err != nil {
		t.Fatalf("generateKey: %v", err)
	}
	prefixB, fullB, hashB, err := generateKey()
	if err != nil {
		t.Fatalf("generateKey: %v", err)
	}
	if !strings.HasPrefix(fullA, "mbk_") {
		t.Errorf("expected mbk_ prefix, got %q", fullA)
	}
	if !strings.Contains(fullA, prefixA) {
		t.Errorf("full key %q must contain prefix %q", fullA, prefixA)
	}
	if prefixA == prefixB {
		t.Error("two generated keys must not share a prefix")
	}
	if hashA == hashB {
		t.Error("two generated keys must produce distinct hashes")
	}
	if fullA == fullB {
		t.Error("two generated keys must not collide")
	}
}

func TestParseKey_Roundtrip(t *testing.T) {
	prefix, full, _, err := generateKey()
	if err != nil {
		t.Fatalf("generateKey: %v", err)
	}
	gotPrefix, gotPayload, err := parseKey(full)
	if err != nil {
		t.Fatalf("parseKey: %v", err)
	}
	if gotPrefix != prefix {
		t.Errorf("prefix mismatch: got %q want %q", gotPrefix, prefix)
	}
	if gotPayload == "" {
		t.Error("payload must not be empty")
	}
}

func TestParseKey_Malformed(t *testing.T) {
	cases := []string{
		"",
		"mbk_short_payload",
		"mbk_toolongprefix0_payload",
		"notmbk_aaaaaaaaaaaa_payload",
		"mbk_aaaaaaaaaaaa",
	}
	for _, c := range cases {
		if _, _, err := parseKey(c); err == nil {
			t.Errorf("expected error for %q", c)
		}
	}
}

func TestVerifyKeyHash_MatchesAndRejects(t *testing.T) {
	prefix, full, hash, err := generateKey()
	if err != nil {
		t.Fatalf("generateKey: %v", err)
	}
	_, payload, err := parseKey(full)
	if err != nil {
		t.Fatalf("parseKey: %v", err)
	}
	if !verifyKeyHash(payload, prefix, hash) {
		t.Error("verifyKeyHash must accept the right payload+prefix")
	}
	if verifyKeyHash(payload+"x", prefix, hash) {
		t.Error("verifyKeyHash must reject a tampered payload")
	}
	if verifyKeyHash(payload, "wrongprefix0", hash) {
		t.Error("verifyKeyHash must reject a wrong prefix (salt)")
	}
}
