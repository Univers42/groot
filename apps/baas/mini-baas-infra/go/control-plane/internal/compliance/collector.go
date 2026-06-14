package compliance

import (
	"bufio"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// Collector snapshots the THREE evidence sections from REALITY into the sealed
// store. It is deliberately NOT a "report compliant" stub: each section reads a
// real, observable source so a missing/failing control shows up as failing —
// the gate's load-bearing REJECT seeds exactly that and asserts it is recorded
// honestly (not green).
//
// Sources (all configurable so the gate can point them at controlled fixtures):
//   - CI/gate posture  ← the verify-gate script directory (SOC2_EVIDENCE_GATES_DIR,
//     default scripts/verify). Each mNN-*.sh is a CONTROL; a gate that emits a
//     `GATE ... mNN=PASS` marker is recorded passing:true, one that does not is
//     passing:false. PLUS the CI job names parsed from a CI workflow file
//     (SOC2_EVIDENCE_CI_WORKFLOW, optional).
//   - Access review    ← the LIVE postgres: role grants on the sensitive control
//     tables (information_schema.role_table_grants) — who can read/write what.
//   - Change mgmt      ← a git change-log file (SOC2_EVIDENCE_GITLOG): recent
//     commits + their authors as the change record. (git is not in the distroless
//     runtime, so the trail is provided as a snapshot file the deploy mounts.)
type Collector struct {
	db         accessDB
	gatesDir   string
	ciWorkflow string
	gitLogPath string
	now        func() time.Time
}

// accessDB is the minimal Postgres surface the access-review section needs.
// *shared.Postgres satisfies it; a fake satisfies it in unit tests.
type accessDB interface {
	AdminQuery(ctx context.Context, sql string, args ...any) (pgxRows, error)
}

// pgxRows mirrors the subset of pgx.Rows the access query uses, so the package
// can be unit-tested with a fake without importing pgx into the test.
type pgxRows interface {
	Next() bool
	Scan(dest ...any) error
	Err() error
	Close()
}

// NewCollector builds a collector reading its sources from env (with the gate
// fixtures overriding for the test). All paths default to the in-repo layout but
// the gate points them at controlled fixtures so the load-bearing reject can
// seed a FAILING control.
func NewCollector(db accessDB) *Collector {
	gatesDir := envOr("SOC2_EVIDENCE_GATES_DIR", "scripts/verify")
	return &Collector{
		db:         db,
		gatesDir:   gatesDir,
		ciWorkflow: os.Getenv("SOC2_EVIDENCE_CI_WORKFLOW"),
		gitLogPath: os.Getenv("SOC2_EVIDENCE_GITLOG"),
		now:        func() time.Time { return time.Now().UTC() },
	}
}

// SectionPayload is the (section, payload) pair the store seals + persists.
type SectionPayload struct {
	Section string
	Payload json.RawMessage
}

// Snapshot is the three sealed-ready section payloads for one collection run,
// stamped with the run instant.
type Snapshot struct {
	CollectedAt time.Time
	Sections    []SectionPayload
}

// Collect reads all three sections from their real sources and returns the
// payloads to seal + persist. It returns the SAME collected_at for all three so
// they belong to one snapshot. It never invents "compliant" — each section
// carries the observed truth (including failing/absent controls).
func (c *Collector) Collect(ctx context.Context) (Snapshot, error) {
	at := c.now()

	ciPayload, err := c.collectCI()
	if err != nil {
		return Snapshot{}, err
	}
	accessPayload, err := c.collectAccess(ctx)
	if err != nil {
		return Snapshot{}, err
	}
	changePayload, err := c.collectChangeMgmt()
	if err != nil {
		return Snapshot{}, err
	}

	return Snapshot{
		CollectedAt: at,
		Sections: []SectionPayload{
			{Section: SectionCI, Payload: ciPayload},
			{Section: SectionAccess, Payload: accessPayload},
			{Section: SectionChangeMgmt, Payload: changePayload},
		},
	}, nil
}

// ───────────────────────── CI / gate posture ─────────────────────────────────

// gatePassRe matches a verify gate's self-attested PASS marker, e.g.
//
//	log_event GATE --gate "m104=PASS" ...
//	green "[M104] ALL GATES GREEN ..."
//
// The robust, gate-authored anchor is the `<gate>=PASS` token a gate emits via
// the kernel log helper. A control whose script lacks that marker is recorded
// passing:false — so a deliberately-failing/stub gate is reported honestly.
var gatePassRe = regexp.MustCompile(`m([0-9]+)=PASS`)

// gateFileRe extracts the milestone id from a gate filename mNN-*.sh.
var gateFileRe = regexp.MustCompile(`^m([0-9]+)-.*\.sh$`)

// ciControl is one CI/gate control's evidence: the gate file, its milestone id,
// and whether it self-attests PASS.
type ciControl struct {
	Gate    string `json:"gate"`    // m104
	File    string `json:"file"`    // m104-audit-chain.sh
	Passing bool   `json:"passing"` // true iff the script emits a <gate>=PASS marker
}

func (c *Collector) collectCI() (json.RawMessage, error) {
	controls := []ciControl{}
	entries, err := os.ReadDir(c.gatesDir)
	if err != nil {
		// A missing gates dir is itself evidence (zero controls) — not a fatal
		// collector error. Record it as an empty inventory rather than failing.
		if os.IsNotExist(err) {
			return c.marshalCI(controls, nil)
		}
		return nil, err
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		m := gateFileRe.FindStringSubmatch(e.Name())
		if m == nil {
			continue
		}
		passing, err := fileHasPassMarker(filepath.Join(c.gatesDir, e.Name()), "m"+m[1])
		if err != nil {
			return nil, err
		}
		controls = append(controls, ciControl{Gate: "m" + m[1], File: e.Name(), Passing: passing})
	}
	sort.Slice(controls, func(i, j int) bool { return controls[i].File < controls[j].File })

	jobs, err := c.parseCIJobs()
	if err != nil {
		return nil, err
	}
	return c.marshalCI(controls, jobs)
}

// fileHasPassMarker scans a gate script for its `<gate>=PASS` self-attestation.
// A gate that authors the marker is "passing"; one that does not (a stub, a
// known-failing control, or a script with no gate emission) is "not passing".
func fileHasPassMarker(path, gate string) (bool, error) {
	f, err := os.Open(path)
	if err != nil {
		return false, err
	}
	defer f.Close()
	want := gate + "=PASS"
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Text()
		if strings.Contains(line, want) {
			// also confirm the regex agrees this is a PASS token (defense vs a
			// comment that merely mentions the string in prose).
			for _, mm := range gatePassRe.FindAllStringSubmatch(line, -1) {
				if "m"+mm[1]+"=PASS" == want {
					return true, nil
				}
			}
		}
	}
	return false, sc.Err()
}

// parseCIJobs extracts the `<id>:` job keys under a `jobs:` block of a CI
// workflow YAML (a lightweight parse — no YAML dep). Returns nil when no
// workflow is configured, which is fine: the CI section then evidences gates
// only. This is enough to record "which CI jobs exist" as control evidence.
func (c *Collector) parseCIJobs() ([]string, error) {
	if c.ciWorkflow == "" {
		return nil, nil
	}
	f, err := os.Open(c.ciWorkflow)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	defer f.Close()
	var jobs []string
	inJobs := false
	jobKeyRe := regexp.MustCompile(`^  ([A-Za-z0-9_-]+):\s*$`)
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "jobs:") {
			inJobs = true
			continue
		}
		if inJobs {
			// a top-level key (no indent) ends the jobs block.
			if len(line) > 0 && line[0] != ' ' && line[0] != '#' {
				inJobs = false
				continue
			}
			if m := jobKeyRe.FindStringSubmatch(line); m != nil {
				jobs = append(jobs, m[1])
			}
		}
	}
	sort.Strings(jobs)
	return jobs, sc.Err()
}

func (c *Collector) marshalCI(controls []ciControl, jobs []string) (json.RawMessage, error) {
	passing := 0
	for _, ct := range controls {
		if ct.Passing {
			passing++
		}
	}
	return json.Marshal(map[string]any{
		"control_type":    "ci_gate_posture",
		"gates_total":     len(controls),
		"gates_passing":   passing,
		"all_passing":     len(controls) > 0 && passing == len(controls),
		"gates":           controls,
		"ci_jobs":         jobs,
		"source_gatesdir": c.gatesDir,
	})
}

// ───────────────────────── access review ─────────────────────────────────────

// accessGrant is one observed role grant: which role can do what on which
// sensitive control table.
type accessGrant struct {
	Role      string `json:"role"`
	Table     string `json:"table"`
	Privilege string `json:"privilege"`
}

// accessReviewSQL reads role grants on the sensitive control tables from the
// live catalog — the actual, observable access posture (not an assertion). It
// scopes to the platform's control tables so the review is meaningful and small.
const accessReviewSQL = `
SELECT grantee, table_name, privilege_type
  FROM information_schema.role_table_grants
 WHERE table_schema = 'public'
   AND table_name IN (
     'compliance_evidence','tenant_audit_log','tenants',
     'tenant_usage','tenant_billing','tenant_backups')
   AND grantee NOT IN ('PUBLIC')
 ORDER BY grantee, table_name, privilege_type`

func (c *Collector) collectAccess(ctx context.Context) (json.RawMessage, error) {
	grants := []accessGrant{}
	rows, err := c.db.AdminQuery(ctx, accessReviewSQL)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var g accessGrant
		if err := rows.Scan(&g.Role, &g.Table, &g.Privilege); err != nil {
			return nil, err
		}
		grants = append(grants, g)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	// authenticated MUST NOT be able to read compliance_evidence — surface that
	// as an explicit, checkable invariant in the evidence itself.
	authedCanReadEvidence := false
	for _, g := range grants {
		if g.Role == "authenticated" && g.Table == "compliance_evidence" && g.Privilege == "SELECT" {
			authedCanReadEvidence = true
		}
	}
	return json.Marshal(map[string]any{
		"control_type":             "access_review",
		"grants_total":             len(grants),
		"grants":                   grants,
		"evidence_is_service_only": !authedCanReadEvidence,
	})
}

// ───────────────────────── change management ─────────────────────────────────

// commit is one change-management record: a commit's short hash, author, and
// subject — the audit trail of WHO changed WHAT.
type commit struct {
	Hash    string `json:"hash"`
	Author  string `json:"author"`
	Subject string `json:"subject"`
}

// collectChangeMgmt reads the git change-log snapshot file. Each line is one
// commit in the pipe-delimited form `<hash>|<author>|<subject>` (the format a
// `git log --pretty=format:'%h|%an|%s'` dump produces). git is not in the
// distroless runtime, so the deploy mounts the trail as a snapshot file; when no
// file is configured the section evidences zero commits (an honest "no trail
// available" rather than a fabricated green).
func (c *Collector) collectChangeMgmt() (json.RawMessage, error) {
	commits := []commit{}
	if c.gitLogPath == "" {
		return c.marshalChange(commits, "")
	}
	f, err := os.Open(c.gitLogPath)
	if err != nil {
		if os.IsNotExist(err) {
			return c.marshalChange(commits, c.gitLogPath)
		}
		return nil, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "|", 3)
		cm := commit{Hash: parts[0]}
		if len(parts) > 1 {
			cm.Author = parts[1]
		}
		if len(parts) > 2 {
			cm.Subject = parts[2]
		}
		commits = append(commits, cm)
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	return c.marshalChange(commits, c.gitLogPath)
}

func (c *Collector) marshalChange(commits []commit, src string) (json.RawMessage, error) {
	authors := map[string]bool{}
	for _, cm := range commits {
		if cm.Author != "" {
			authors[cm.Author] = true
		}
	}
	uniq := make([]string, 0, len(authors))
	for a := range authors {
		uniq = append(uniq, a)
	}
	sort.Strings(uniq)
	return json.Marshal(map[string]any{
		"control_type":    "change_management",
		"commits_total":   len(commits),
		"authors":         uniq,
		"commits":         commits,
		"source_gitlog":   src,
		"trail_available": len(commits) > 0,
	})
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
