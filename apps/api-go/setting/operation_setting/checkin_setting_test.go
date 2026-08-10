package operation_setting

import (
	"math"
	"testing"
)

func TestScaledCheckinQuotaRangeUsesLevelMultiplier(t *testing.T) {
	min, max := scaledCheckinQuotaRange(1000, 10000, 0.65)
	if min != 650 || max != 6500 {
		t.Fatalf("scaled range = (%d, %d), want (650, 6500)", min, max)
	}
}

func TestCheckinLevelMultiplierClampsLevelsAndInvalidValues(t *testing.T) {
	values := []float64{math.NaN(), -1, 0.75}
	if got := checkinLevelMultiplier(-1, values); got != DefaultCheckinLevelMultipliers[0] {
		t.Fatalf("negative level multiplier = %v, want %v", got, DefaultCheckinLevelMultipliers[0])
	}
	if got := checkinLevelMultiplier(2, values); got != 0.75 {
		t.Fatalf("configured level multiplier = %v, want 0.75", got)
	}
	if got := checkinLevelMultiplier(99, values); got != DefaultCheckinLevelMultipliers[4] {
		t.Fatalf("high level multiplier = %v, want %v", got, DefaultCheckinLevelMultipliers[4])
	}
}

func TestNormalizedCheckinLevelMultipliersReturnsCopy(t *testing.T) {
	values := []float64{0.4, 0.6}
	got := normalizedCheckinLevelMultipliers(values)
	got[0] = 99
	if values[0] != 0.4 {
		t.Fatalf("normalization mutated input: %v", values)
	}
	if len(got) != 5 || got[1] != 0.6 || got[2] != DefaultCheckinLevelMultipliers[2] {
		t.Fatalf("normalized multipliers = %v", got)
	}
}
