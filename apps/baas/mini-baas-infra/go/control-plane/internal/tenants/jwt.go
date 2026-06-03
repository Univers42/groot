package tenants

import (
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// JWTVerifier validates GoTrue-issued HS256 JWTs and extracts the subject.
//
// We deliberately accept only HS256 to avoid algorithm-confusion attacks
// (downgrading to `none` or coercing RS256/HS256 mix). The shared secret is
// the same one GoTrue uses to sign — usually `GOTRUE_JWT_SECRET` / `JWT_SECRET`.
type JWTVerifier struct {
	secret []byte
	issuer string // optional; if set, `iss` claim must match
}

// NewJWTVerifier builds a verifier with the given shared secret. If issuer
// is non-empty, the JWT's `iss` claim must match it exactly.
func NewJWTVerifier(secret, issuer string) (*JWTVerifier, error) {
	if secret == "" {
		return nil, errors.New("jwt secret is required")
	}
	return &JWTVerifier{secret: []byte(secret), issuer: issuer}, nil
}

// VerifiedIdentity is the subset of GoTrue claims we care about.
type VerifiedIdentity struct {
	UserID string   // sub claim — GoTrue user UUID
	Email  string   // email claim
	Role   string   // role claim (e.g. "authenticated")
	Aud    []string // audience(s)
}

// Verify parses + validates a raw token string. Returns the identity on
// success or a descriptive error on failure.
func (v *JWTVerifier) Verify(raw string) (VerifiedIdentity, error) {
	raw = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(raw), "Bearer"))
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return VerifiedIdentity{}, errors.New("empty token")
	}

	token, err := jwt.Parse(raw, func(t *jwt.Token) (any, error) {
		// Pin to HS256 — anything else is rejected.
		if t.Method.Alg() != jwt.SigningMethodHS256.Alg() {
			return nil, fmt.Errorf("unexpected signing method: %s", t.Method.Alg())
		}
		return v.secret, nil
	}, jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}))

	if err != nil {
		return VerifiedIdentity{}, fmt.Errorf("parse: %w", err)
	}
	if !token.Valid {
		return VerifiedIdentity{}, errors.New("invalid token")
	}

	claims, ok := token.Claims.(jwt.MapClaims)
	if !ok {
		return VerifiedIdentity{}, errors.New("unexpected claims type")
	}

	// exp / nbf are validated by jwt.Parse; double-check exp here so we
	// produce a friendlier error for the most common failure mode.
	if exp, err := claims.GetExpirationTime(); err == nil && exp != nil {
		if time.Now().After(exp.Time) {
			return VerifiedIdentity{}, errors.New("token expired")
		}
	}

	if v.issuer != "" {
		iss, _ := claims.GetIssuer()
		if iss != v.issuer {
			return VerifiedIdentity{}, fmt.Errorf("issuer mismatch: got %q want %q", iss, v.issuer)
		}
	}

	sub, _ := claims.GetSubject()
	if sub == "" {
		return VerifiedIdentity{}, errors.New("missing sub claim")
	}

	email, _ := claims["email"].(string)
	role, _ := claims["role"].(string)
	aud, _ := claims.GetAudience()

	return VerifiedIdentity{
		UserID: sub,
		Email:  email,
		Role:   role,
		Aud:    aud,
	}, nil
}
