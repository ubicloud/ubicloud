package provider

import "testing"

func TestNormalizePortRange(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"22..22", "22"},             // equal bounds collapse
		{"22", "22"},                 // already collapsed, no ".." separator
		{"22..25", "22..25"},         // distinct bounds preserved
		{"", ""},                     // blank
		{"22..", "22.."},             // single-ended, bounds differ
		{"..22", "..22"},             // single-ended, bounds differ
		{"0..0", "0"},                // equal bounds collapse
		{"22..22..22", "22..22..22"}, // SplitN limit 2: parts differ
	}
	for _, c := range cases {
		if got := normalizePortRange(c.in); got != c.want {
			t.Errorf("normalizePortRange(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestNormalizedPortRange(t *testing.T) {
	cases := []struct {
		name     string
		prior    string
		apiValue string
		want     string
	}{
		{"alias preserved", "22..22", "22", "22..22"},
		{"identical", "22", "22", "22"},
		{"range preserved", "22..25", "22..25", "22..25"},
		{"empty prior takes api", "", "22", "22"},
		{"changed config takes api", "80", "22", "22"},
		{"prior not alias takes api", "22..25", "22", "22"},
	}
	for _, c := range cases {
		got := normalizedPortRange(c.prior, c.apiValue)
		if got.ValueString() != c.want {
			t.Errorf("%s: normalizedPortRange(%q, %q) = %q, want %q", c.name, c.prior, c.apiValue, got.ValueString(), c.want)
		}
	}
}
