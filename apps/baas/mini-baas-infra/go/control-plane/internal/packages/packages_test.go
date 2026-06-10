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
		"essential":  "essential", // direct package key
		"pro":        "pro",        // direct (also a legacy plan value)
		"max":        "max",        // direct
		"free":       "essential",  // legacy alias
		"enterprise": "max",        // legacy alias
		"":           "essential",  // empty → default
		"bogus":      "essential",  // unknown → default
	}
	for plan, wantName := range cases {
		name, _ := m.For(plan)
		if name != wantName {
			t.Errorf("For(%q) = %q, want %q", plan, name, wantName)
		}
	}
}

func TestEssentialNarrowsButProDoesNot(t *testing.T) {
	m, _ := Load()
	_, ess := m.For("essential")
	if ess.Capabilities["aggregate"] {
		t.Error("essential must NOT include aggregate")
	}
	if !ess.AllowsEngine("postgresql") || ess.AllowsEngine("mysql") {
		t.Error("essential allows postgresql, not mysql")
	}
	ov := ess.CapabilityOverrides()
	if ov["aggregate"] != false {
		t.Errorf("essential override aggregate=%v, want false", ov["aggregate"])
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
