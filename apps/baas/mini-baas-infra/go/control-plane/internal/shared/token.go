package shared

import "crypto/subtle"

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
