package compliance

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// buildSnapshot seals n section rows the SAME way Service.Collect does (SealHash
// over section + collected_at + payload), so a test can tamper a stored row and
// assert VerifySnapshot catches it at exactly that section. This mirrors the live
// seal path, which makes the test load-bearing rather than circular.
func buildSnapshot(t *testing.T) []EvidenceRow {
	t.Helper()
	at := time.Date(2026, 6, 15, 12, 0, 0, 0, time.UTC)
	rows := make([]EvidenceRow, 0, len(Sections))
	for i, s := range Sections {
		payload := json.RawMessage(`{"control_type":"` + s + `","n":` + itoa(i) + `}`)
		rows = append(rows, EvidenceRow{
			ID:          "id-" + s,
			SnapshotID:  "snap-1",
			CollectedAt: at,
			Section:     s,
			Payload:     payload,
			Hash:        SealHash(s, at, payload),
		})
	}
	return rows
}

func itoa(i int) string { return string(rune('0' + i%10)) }

func TestVerifySnapshot_Intact(t *testing.T) {
	rows := buildSnapshot(t)
	res := VerifySnapshot("snap-1", rows)
	if !res.Intact {
		t.Fatalf("freshly sealed snapshot must be intact, got broken_section=%s", res.BrokenSection)
	}
	if !res.Complete {
		t.Fatalf("snapshot with all 3 sections must be complete, missing=%v", res.Missing)
	}
	if res.Count != 3 {
		t.Fatalf("expected count=3, got %d", res.Count)
	}
}

// THE load-bearing test: tamper a STORED row's payload (as a DB-level tamperer
// would) WITHOUT recomputing its hash. VerifySnapshot must report INTACT=false
// at exactly that section. A vacuous verifier that always says intact fails this.
func TestVerifySnapshot_TamperedPayload(t *testing.T) {
	rows := buildSnapshot(t)
	rows[1].Payload = json.RawMessage(`{"control_type":"access","tampered":true}`)
	res := VerifySnapshot("snap-1", rows)
	if res.Intact {
		t.Fatal("tampered payload must break the seal — vacuous verify rejected")
	}
	if res.BrokenSection != SectionAccess {
		t.Fatalf("expected break at section=access, got %s", res.BrokenSection)
	}
}

// Tampering the section label (e.g. relabeling a row) must also break the seal.
func TestVerifySnapshot_TamperedSection(t *testing.T) {
	rows := buildSnapshot(t)
	rows[0].Section = SectionChangeMgmt // relabel ci -> change_mgmt, leave stale hash
	res := VerifySnapshot("snap-1", rows)
	if res.Intact {
		t.Fatal("relabeled section must break the seal")
	}
}

// A missing section must be reported incomplete even if the present rows verify.
func TestVerifySnapshot_Incomplete(t *testing.T) {
	rows := buildSnapshot(t)[:2] // drop change_mgmt
	res := VerifySnapshot("snap-1", rows)
	if !res.Intact {
		t.Fatalf("present rows still seal intact, got broken=%s", res.BrokenSection)
	}
	if res.Complete {
		t.Fatal("a snapshot missing change_mgmt must be incomplete")
	}
	if len(res.Missing) != 1 || res.Missing[0] != SectionChangeMgmt {
		t.Fatalf("expected missing=[change_mgmt], got %v", res.Missing)
	}
}

// Key order in a payload must not change the seal (canonicalJSON), but a real
// value change must.
func TestSealHash_PayloadKeyOrderStable(t *testing.T) {
	at := time.Date(2026, 6, 15, 12, 0, 0, 0, time.UTC)
	h1 := SealHash("ci", at, []byte(`{"x":1,"y":2}`))
	h2 := SealHash("ci", at, []byte(`{"y":2,"x":1}`))
	if h1 != h2 {
		t.Fatalf("key order must not change the seal: %s != %s", h1, h2)
	}
	if h1 == SealHash("ci", at, []byte(`{"x":1,"y":3}`)) {
		t.Fatal("a payload value change must change the seal")
	}
}

// Microsecond truncation: a nanosecond-precision time and its µs-floor must seal
// identically (postgres timestamptz round-trips at µs).
func TestSealHash_MicrosecondStable(t *testing.T) {
	ns := time.Date(2026, 6, 15, 12, 0, 0, 123456789, time.UTC)
	us := ns.Truncate(time.Microsecond)
	if SealHash("ci", ns, []byte(`{}`)) != SealHash("ci", us, []byte(`{}`)) {
		t.Fatal("ns and its µs-floor must seal identically (pgx floors ns->µs)")
	}
}

// ── collector reality test: a gate WITHOUT a PASS marker is recorded passing:false ──

// fakeRows is a tiny in-memory pgxRows for the access-review query.
type fakeRows struct {
	data [][]any
	i    int
}

func (f *fakeRows) Next() bool { f.i++; return f.i <= len(f.data) }
func (f *fakeRows) Err() error { return nil }
func (f *fakeRows) Close()     {}
func (f *fakeRows) Scan(dest ...any) error {
	row := f.data[f.i-1]
	for j := range dest {
		*(dest[j].(*string)) = row[j].(string)
	}
	return nil
}

type fakeAccessDB struct{ rows [][]any }

func (d fakeAccessDB) AdminQuery(_ context.Context, _ string, _ ...any) (pgxRows, error) {
	return &fakeRows{data: d.rows}, nil
}

// THE collector reality test: seed a gates dir with one PASSING gate (has the
// =PASS marker) and one FAILING gate (a stub without the marker). The CI section
// must record gates_passing=1, all_passing=false, and the failing gate as
// passing:false — proving the collector reflects REALITY, not a green stub.
func TestCollector_CISection_ReflectsFailingControl(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "m200-good.sh"),
		"#!/usr/bin/env bash\n"+`log_event GATE --gate "m200=PASS" --outcome pass`+"\n")
	// A stub gate: no PASS marker -> must be recorded passing:false.
	writeFile(t, filepath.Join(dir, "m201-stub.sh"),
		"#!/usr/bin/env bash\necho 'not implemented'\nexit 0\n")

	c := &Collector{db: fakeAccessDB{}, gatesDir: dir, now: func() time.Time { return time.Unix(0, 0).UTC() }}
	raw, err := c.collectCI()
	if err != nil {
		t.Fatalf("collectCI: %v", err)
	}
	var ci struct {
		GatesTotal   int  `json:"gates_total"`
		GatesPassing int  `json:"gates_passing"`
		AllPassing   bool `json:"all_passing"`
		Gates        []struct {
			Gate    string `json:"gate"`
			Passing bool   `json:"passing"`
		} `json:"gates"`
	}
	if err := json.Unmarshal(raw, &ci); err != nil {
		t.Fatalf("unmarshal ci payload: %v", err)
	}
	if ci.GatesTotal != 2 {
		t.Fatalf("expected 2 gates, got %d", ci.GatesTotal)
	}
	if ci.GatesPassing != 1 {
		t.Fatalf("expected exactly 1 passing gate (the stub must be failing), got %d", ci.GatesPassing)
	}
	if ci.AllPassing {
		t.Fatal("all_passing must be false when a stub gate lacks its PASS marker — collector must not report vacuous green")
	}
	for _, g := range ci.Gates {
		if g.Gate == "m201" && g.Passing {
			t.Fatal("the stub gate m201 must be recorded passing:false (reality), not green")
		}
		if g.Gate == "m200" && !g.Passing {
			t.Fatal("the real gate m200 (with =PASS marker) must be recorded passing:true")
		}
	}
}

// The change-mgmt section must reflect the actual commit trail it is given, and
// be honest ("trail_available":false) when no trail file is configured.
func TestCollector_ChangeMgmt_ReflectsTrail(t *testing.T) {
	// no trail configured -> honest empty, not fabricated green.
	c := &Collector{gitLogPath: ""}
	raw, err := c.collectChangeMgmt()
	if err != nil {
		t.Fatalf("collectChangeMgmt empty: %v", err)
	}
	if got := jsonField(t, raw, "trail_available"); got != false {
		t.Fatalf("no trail file must report trail_available=false, got %v", got)
	}

	// with a trail file -> the commits + authors are recorded.
	dir := t.TempDir()
	logp := filepath.Join(dir, "gitlog.txt")
	writeFile(t, logp, "abc123|Alice|feat: add thing\ndef456|Bob|fix: bug\n")
	c2 := &Collector{gitLogPath: logp}
	raw2, err := c2.collectChangeMgmt()
	if err != nil {
		t.Fatalf("collectChangeMgmt with trail: %v", err)
	}
	if got := jsonField(t, raw2, "trail_available"); got != true {
		t.Fatalf("a 2-commit trail must report trail_available=true, got %v", got)
	}
	if got := jsonField(t, raw2, "commits_total"); got != float64(2) {
		t.Fatalf("expected commits_total=2, got %v", got)
	}
}

// The access section must surface evidence_is_service_only=false when the
// access review observes authenticated holding SELECT on compliance_evidence —
// i.e. it reflects a REAL misconfiguration, not a hardcoded pass.
func TestCollector_Access_DetectsAuthenticatedLeak(t *testing.T) {
	// Good posture: authenticated has no grant on compliance_evidence.
	good := &Collector{db: fakeAccessDB{rows: [][]any{{"service_role", "compliance_evidence", "SELECT"}}}}
	raw, err := good.collectAccess(context.Background())
	if err != nil {
		t.Fatalf("collectAccess good: %v", err)
	}
	if got := jsonField(t, raw, "evidence_is_service_only"); got != true {
		t.Fatalf("service-only posture must report evidence_is_service_only=true, got %v", got)
	}
	// Bad posture: authenticated CAN read compliance_evidence -> must be flagged.
	bad := &Collector{db: fakeAccessDB{rows: [][]any{{"authenticated", "compliance_evidence", "SELECT"}}}}
	raw2, err := bad.collectAccess(context.Background())
	if err != nil {
		t.Fatalf("collectAccess bad: %v", err)
	}
	if got := jsonField(t, raw2, "evidence_is_service_only"); got != false {
		t.Fatalf("a real authenticated-can-read leak must report evidence_is_service_only=false, got %v", got)
	}
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func jsonField(t *testing.T, raw json.RawMessage, key string) any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	return m[key]
}
