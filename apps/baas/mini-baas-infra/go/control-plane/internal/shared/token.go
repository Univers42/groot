package shared

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// SecureCompare reports whether the presented token equals the expected token,
// in constant time (Phase B / fix: the previous `==`/`!=` checks on the
// internal service token leaked length + prefix via timing). An empty `want`
// always returns false — an unset service token must never authorize a caller.
func SecureCompare(got, want string) bool {
	if want == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(got), []byte(want)) == 1
}

// ServiceAuthHMAC reports whether SERVICE_TOKEN_MODE=hmac is active (audit O1).
// In hmac mode the shared token never transits the wire: callers send a
// per-request signature instead, and plain X-Service-Token is REJECTED.
func ServiceAuthHMAC() bool {
	return strings.EqualFold(strings.TrimSpace(os.Getenv("SERVICE_TOKEN_MODE")), "hmac")
}

// ComputeServiceSignature returns the v1 X-Service-Auth header value:
//
//	v1.<unix-ts>.<hex hmac-sha256(token, "<ts>\n<METHOD>\n<PATH>\n<sha256hex(body)>")>
//
// The signature binds time, method, path, and body, so an intercepted header
// cannot be replayed against another endpoint or with another payload. PATH is
// the URL path only — internal base URLs are origin-only and these routes take
// no query strings.
func ComputeServiceSignature(token, method, path string, body []byte, ts int64) string {
	bodySum := sha256.Sum256(body)
	msg := fmt.Sprintf("%d\n%s\n%s\n%s", ts, strings.ToUpper(method), path, hex.EncodeToString(bodySum[:]))
	mac := hmac.New(sha256.New, []byte(token))
	mac.Write([]byte(msg))
	return fmt.Sprintf("v1.%d.%s", ts, hex.EncodeToString(mac.Sum(nil)))
}

// VerifyServiceRequest authenticates an internal service-to-service request.
// static mode (default): constant-time X-Service-Token compare — exactly the
// pre-existing behavior. hmac mode: requires a valid X-Service-Auth signature
// within ±SERVICE_AUTH_SKEW_SECS (default 120). Reads and RESTORES r.Body so
// handlers can still decode it.
func VerifyServiceRequest(r *http.Request, expected string) bool {
	if expected == "" {
		return false
	}
	if !ServiceAuthHMAC() {
		return SecureCompare(r.Header.Get("X-Service-Token"), expected)
	}
	hdr := r.Header.Get("X-Service-Auth")
	parts := strings.Split(hdr, ".")
	if len(parts) != 3 || parts[0] != "v1" {
		return false
	}
	ts, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil {
		return false
	}
	skew := int64(120)
	if v := os.Getenv("SERVICE_AUTH_SKEW_SECS"); v != "" {
		if n, perr := strconv.ParseInt(v, 10, 64); perr == nil && n > 0 {
			skew = n
		}
	}
	now := time.Now().Unix()
	if ts < now-skew || ts > now+skew {
		return false
	}
	var body []byte
	if r.Body != nil {
		body, _ = io.ReadAll(r.Body)
		_ = r.Body.Close()
		r.Body = io.NopCloser(bytes.NewReader(body))
	}
	want := ComputeServiceSignature(expected, r.Method, r.URL.Path, body, ts)
	return subtle.ConstantTimeCompare([]byte(hdr), []byte(want)) == 1
}
