package provider

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
	"testing"
)

// The two golden families describe one truth from two angles: schema
// goldens carry the full derivation, wire goldens the state-visible
// projection. They are updated by different rituals and could skew
// silently; this test pins their top-level attribute-name sets to
// each other, with declared quirks as the only sanctioned divergence.
// Name-set comparison deliberately avoids re-deriving type rendering.
var goldenNameQuirks = map[string]map[string]string{
	// key -> attribute -> reason. Empty today: even the timeouts wire
	// quirk (empty Object) diverges in TYPE, not in NAME. Promote to
	// testdata JSON if this outgrows a handful.
}

func topLevelWireNames(wire string) []string {
	inner := strings.TrimSuffix(strings.TrimPrefix(wire, "tftypes.Object["), "]")
	names, depth, i := []string{}, 0, 0
	for i < len(inner) {
		switch c := inner[i]; {
		case c == '[':
			depth++
		case c == ']':
			depth--
		case c == '"' && depth == 0:
			j := strings.IndexByte(inner[i+1:], '"')
			names = append(names, inner[i+1:i+1+j])
			i += j + 1
		}
		i++
	}
	sort.Strings(names)
	return names
}

func schemaGoldenNames(entry map[string]any) []string {
	names := []string{}
	for _, a := range entry["attributes"].([]any) {
		names = append(names, a.(map[string]any)["name"].(string))
	}
	if blocks, ok := entry["blocks"].([]any); ok {
		for _, b := range blocks {
			names = append(names, b.(map[string]any)["name"].(string))
		}
	}
	sort.Strings(names)
	return names
}

func TestGoldenConsistency(t *testing.T) {
	var wire map[string]string
	var schema map[string]map[string]any
	for path, into := range map[string]any{
		"testdata/wire_goldens.json": &wire, "testdata/schema_goldens.json": &schema,
	} {
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(raw, into); err != nil {
			t.Fatal(err)
		}
	}
	for wkey, wtype := range wire {
		skey := strings.Replace(strings.Replace(wkey, "resource_", "resources/", 1), "datasource_", "datasources/", 1)
		entry, ok := schema[skey]
		if !ok {
			t.Errorf("%s: wire golden has no schema golden sibling %s", wkey, skey)
			continue
		}
		w, s := topLevelWireNames(wtype), schemaGoldenNames(entry)
		quirked := func(n string) bool { _, ok := goldenNameQuirks[wkey][n]; return ok }
		wi, si := 0, 0
		for wi < len(w) || si < len(s) {
			switch {
			case wi < len(w) && (si == len(s) || w[wi] < s[si]):
				if !quirked(w[wi]) {
					t.Error(fmt.Sprintf("%s: %q in wire golden but not schema golden", wkey, w[wi]))
				}
				wi++
			case si < len(s) && (wi == len(w) || s[si] < w[wi]):
				if !quirked(s[si]) {
					t.Error(fmt.Sprintf("%s: %q in schema golden but not wire golden", wkey, s[si]))
				}
				si++
			default:
				wi++
				si++
			}
		}
	}
	if len(wire) != len(schema) {
		t.Errorf("family sizes differ: %d wire vs %d schema", len(wire), len(schema))
	}
}
