package packages

import "testing"

func TestLoadEmbedded(t *testing.T) {
	m, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	for _, want := range []string{"essential", "pro", "max"} {
		if _, ok := m.Packages[want]; !ok {
			t.Errorf("manifest missing package %q", want)
		}
	}
}

func TestForResolvesPlansAndAliases(t *testing.T) {
	m, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	cases := map[string]string{
		"nano":       "nano",      // v2 first-class package
		"basic":      "basic",     // direct package key
		"essential":  "essential", // direct package key
		"pro":        "pro",       // direct (also a legacy plan value)
		"max":        "max",       // direct
		"free":       "nano",      // v2 alias (was essential — pointed free at the $13/mo tier)
		"enterprise": "max",       // legacy alias
		"":           "essential", // empty → default
		"bogus":      "essential", // unknown → default
	}
	for plan, wantName := range cases {
		name, _ := m.For(plan)
		if name != wantName {
			t.Errorf("For(%q) = %q, want %q", plan, name, wantName)
		}
	}
}

func TestTierCapabilityLadder(t *testing.T) {
	m, _ := Load()
	// v2: basic is CRUD-only; essential differentiates by gaining aggregate
	// (a real capability, not just a higher rate — the v1 weakness was that
	// basic and essential were identical). pro adds batch + transactions +
	// multi-engine.
	_, basic := m.For("basic")
	if basic.Capabilities["aggregate"] || basic.Capabilities["batch"] {
		t.Error("basic is CRUD-only: no aggregate, no batch")
	}

	_, ess := m.For("essential")
	if !ess.Capabilities["aggregate"] {
		t.Error("essential MUST include aggregate (its differentiation from basic)")
	}
	if ess.Capabilities["batch"] || ess.Capabilities["transactions"] {
		t.Error("essential stops below pro: no batch/transactions")
	}
	if !ess.AllowsEngine("postgresql") || ess.AllowsEngine("mysql") {
		t.Error("essential allows postgresql, not mysql")
	}
	ov := ess.CapabilityOverrides()
	if ov["aggregate"] != true {
		t.Errorf("essential override aggregate=%v, want true", ov["aggregate"])
	}
	if ov["rps"] == nil || ov["burst"] == nil {
		t.Error("override must carry rps/burst for the token bucket")
	}

	_, pro := m.For("pro")
	if !pro.Capabilities["aggregate"] || !pro.Capabilities["transactions"] {
		t.Error("pro must include aggregate + transactions")
	}
	if !pro.AllowsEngine("mysql") || !pro.AllowsEngine("mongodb") {
		t.Error("pro must allow mysql + mongodb")
	}
}

func TestNanoTierExistsAsFreeShape(t *testing.T) {
	m, _ := Load()
	// v2 adds nano as a first-class package and maps free→nano (was free→
	// essential, which pointed the free plan at the ~$13/mo tier).
	_, nano := m.For("nano")
	if !nano.AllowsEngine("sqlite") || nano.AllowsEngine("postgresql") {
		t.Error("nano is the single-binary sqlite shape")
	}
	_, freed := m.For("free")
	if freed.Label != nano.Label {
		t.Errorf("free must resolve to nano, got %q", freed.Label)
	}
}

func TestMaxAllowsEverything(t *testing.T) {
	m, _ := Load()
	_, max := m.For("max")
	for _, eng := range []string{"postgresql", "mysql", "mariadb", "mongodb", "redis", "cockroachdb", "mssql", "http"} {
		if !max.AllowsEngine(eng) {
			t.Errorf("max must allow engine %q", eng)
		}
	}
	if max.PoolPolicy.MaxMounts < 50 {
		t.Errorf("max max_mounts = %d, want >= 50", max.PoolPolicy.MaxMounts)
	}
}
