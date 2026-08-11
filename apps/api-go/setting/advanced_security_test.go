package setting

import "testing"

func TestParseAdvancedSecurityRulesNormalizesAndValidates(t *testing.T) {
	ruleSet, err := ParseAdvancedSecurityRules(`{
  "version": 1,
  "rules": [{
    "id": " prompt-injection ",
    "category": " abuse ",
    "enabled": true,
    "patterns": [" Ignore previous instructions ", "ignore previous instructions"]
  }]
}`)
	if err != nil {
		t.Fatal(err)
	}
	if ruleSet.Version != 1 || len(ruleSet.Rules) != 1 {
		t.Fatalf("unexpected rule set: %+v", ruleSet)
	}
	rule := ruleSet.Rules[0]
	if rule.ID != "prompt-injection" || rule.Name != "prompt-injection" || rule.Category != "abuse" || len(rule.Patterns) != 1 || rule.Patterns[0] != "Ignore previous instructions" {
		t.Fatalf("unexpected normalized rule: %+v", rule)
	}

	if _, err := ParseAdvancedSecurityRules(`[{"id":"duplicate","enabled":true,"patterns":["x"]},{"id":"duplicate","enabled":true,"patterns":["y"]}]`); err == nil {
		t.Fatal("expected duplicate rule ids to be rejected")
	}
	if _, err := ParseAdvancedSecurityRules(`{"version":2,"rules":[]}`); err == nil {
		t.Fatal("expected unsupported rule version to be rejected")
	}
	if _, err := ParseAdvancedSecurityRules(`{"version":1,"rules":[{"id":"empty","enabled":true,"patterns":[]}]}`); err == nil {
		t.Fatal("expected empty patterns to be rejected")
	}
}

func TestAdvancedSecuritySettingsUpdates(t *testing.T) {
	original := GetAdvancedSecuritySettings()
	t.Cleanup(func() {
		SetAdvancedSecurityEnabled(original.Enabled)
		SetAdvancedSecurityOnPrompt(original.OnPrompt)
		_ = UpdateAdvancedSecurityAction(original.Action)
		_ = UpdateAdvancedSecurityRules(AdvancedSecurityRulesToJSONStringForTest(original.RuleSet))
	})

	SetAdvancedSecurityEnabled(true)
	SetAdvancedSecurityOnPrompt(false)
	if err := UpdateAdvancedSecurityAction(AdvancedSecurityActionAudit); err != nil {
		t.Fatal(err)
	}
	if err := UpdateAdvancedSecurityRules(`[{"id":"test","enabled":true,"patterns":["needle"]}]`); err != nil {
		t.Fatal(err)
	}

	updated := GetAdvancedSecuritySettings()
	if !updated.Enabled || updated.OnPrompt || updated.Action != AdvancedSecurityActionAudit || len(updated.RuleSet.Rules) != 1 {
		t.Fatalf("unexpected advanced security settings: %+v", updated)
	}
}

func AdvancedSecurityRulesToJSONStringForTest(ruleSet AdvancedSecurityRuleSet) string {
	// Keep test cleanup independent of the current global state.
	encoded := `{"version":1,"rules":[]}`
	if len(ruleSet.Rules) == 1 && ruleSet.Rules[0].ID == "test" {
		encoded = `{"version":1,"rules":[{"id":"test","name":"test","category":"custom","enabled":true,"patterns":["needle"]}]}`
	}
	return encoded
}
