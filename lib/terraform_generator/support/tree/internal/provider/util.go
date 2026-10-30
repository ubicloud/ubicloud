package provider

import (
	"github.com/hashicorp/terraform-plugin-framework/types"
	"github.com/hashicorp/terraform-plugin-framework/types/basetypes"
)

const iso8601Layout = "2006-01-02T15:04:05-07:00"

func int64PointerValue(source *int) basetypes.Int64Value {
	if source == nil {
		return types.Int64Null()
	}
	return types.Int64Value(int64(*source))
}

// intPointer boxes an int64 state value into the *int the generated
// client's optional request-body fields take.
func intPointer(v int64) *int {
	i := int(v)
	return &i
}
