package provider

import (
	"context"
	"encoding/json"
	"os"
	"testing"
)

// Wire-type goldens, captured verbatim from the retired
// framework-generated packages at deletion time and stored in
// testdata/wire_goldens.json. Ruby-direct schemas must stay
// wire-identical so states written by any prior provider version
// decode unchanged. The test iterates the generated registry, so a
// new resource cannot ship without a golden; intentional changes are
// recorded via UPDATE_WIRE_GOLDENS=1 go test -run TestWireGoldens
// and reviewed like any golden.
const wireGoldensPath = "testdata/wire_goldens.json"

func TestWireGoldens(t *testing.T) {
	ctx := context.Background()
	got := generatedWireTypes(ctx)

	if os.Getenv("UPDATE_WIRE_GOLDENS") != "" {
		b, err := json.MarshalIndent(got, "", " ")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(wireGoldensPath, append(b, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
		t.Logf("wire goldens updated (%d entries)", len(got))
		return
	}

	raw, err := os.ReadFile(wireGoldensPath)
	if err != nil {
		t.Fatalf("reading wire goldens: %v (UPDATE_WIRE_GOLDENS=1 to seed)", err)
	}
	var want map[string]string
	if err := json.Unmarshal(raw, &want); err != nil {
		t.Fatal(err)
	}
	for name, w := range want {
		g, ok := got[name]
		if !ok {
			t.Errorf("golden %q has no generated schema (resource removed?)", name)
			continue
		}
		if g != w {
			t.Errorf("%s wire type diverged from golden", name)
		}
	}
	for name := range got {
		if _, ok := want[name]; !ok {
			t.Errorf("%s has no wire golden (UPDATE_WIRE_GOLDENS=1 go test -run TestWireGoldens ./internal/provider)", name)
		}
	}
}
