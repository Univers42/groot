package shared

import "testing"

// TestLoadConfigRejectsWeakServiceToken pins fix #4: startup must refuse an
// empty or placeholder INTERNAL_SERVICE_TOKEN, but accept a real (JWT_SECRET-
// derived) secret.
func TestLoadConfigRejectsWeakServiceToken(t *testing.T) {
	const prefix = "TESTSVC"
	t.Setenv("DATABASE_URL", "postgres://u:p@db/x")

	cases := []struct {
		name    string
		token   string
		wantErr bool
	}{
		{"empty rejected", "", true},
		{"placeholder rejected", weakServiceToken, true},
		{"strong accepted", "a-real-jwt-derived-secret", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Setenv("INTERNAL_SERVICE_TOKEN", c.token)
			_, err := LoadConfig(prefix)
			if (err != nil) != c.wantErr {
				t.Fatalf("LoadConfig token=%q err=%v, wantErr=%v", c.token, err, c.wantErr)
			}
		})
	}
}

// TestLoadConfigRequiresDatabaseURL keeps the existing DATABASE_URL guard green.
func TestLoadConfigRequiresDatabaseURL(t *testing.T) {
	t.Setenv("DATABASE_URL", "")
	t.Setenv("INTERNAL_SERVICE_TOKEN", "strong")
	if _, err := LoadConfig("TESTSVC"); err == nil {
		t.Error("LoadConfig must require DATABASE_URL")
	}
}

func TestRedactDSN(t *testing.T) {
	cases := map[string]bool{ // input -> should contain redaction marker
		"connect failed: postgres://user:secret@db:5432/app":      true,
		"redis://:topsecret@cache:6379 unreachable":               true,
		"adapter-registry 400: validation_error (no dsn here)":    false,
		"mongodb+srv://u:p@cluster0.mongodb.net/test auth failed": true,
	}
	for in, wantRedacted := range cases {
		out := RedactDSN(in)
		if wantRedacted {
			if out == in {
				t.Errorf("RedactDSN(%q) left a DSN unredacted: %q", in, out)
			}
			if !contains(out, "[redacted-dsn]") {
				t.Errorf("RedactDSN(%q) = %q, want redaction marker", in, out)
			}
			if contains(out, "secret") || contains(out, "topsecret") {
				t.Errorf("RedactDSN(%q) leaked a credential: %q", in, out)
			}
		} else if out != in {
			t.Errorf("RedactDSN(%q) changed a non-DSN message: %q", in, out)
		}
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
