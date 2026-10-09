package provider

import (
	"strings"

	"github.com/hashicorp/terraform-plugin-framework/types"
)

// The API canonicalizes single-port ranges ("80" -> "80..80"). Reads
// keep the user's spelling when it normalizes to the API value, so no
// spurious diff is produced; writes send the canonical form.
func normalizedPortRange(prior, apiValue string) types.String {
	if prior != "" && normalizePortRange(prior) == apiValue {
		return types.StringValue(prior)
	}
	return types.StringValue(apiValue)
}

func normalizePortRange(s string) string {
	parts := strings.SplitN(s, "..", 2)
	if len(parts) == 2 && parts[0] == parts[1] {
		return parts[0]
	}
	return s
}
