package appcli

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type productionDispatchFaultRunner struct {
	evidence       productionDispatchEvidence
	dispatchCalls  int
	evidenceCalls  int
	secondAccepted bool
}

func (runner *productionDispatchFaultRunner) Run(_ context.Context, command productionCommand) ([]byte, error) {
	if command.Name != commandSSH || len(command.Args) < 4 {
		return nil, errors.New("unexpected dispatch test command")
	}
	remote := command.Args[3:]
	if remote[0] == "systemd-run" {
		runner.dispatchCalls++
		if runner.dispatchCalls == 1 || !runner.secondAccepted {
			return nil, errors.New("injected SSH transport failure")
		}
		return []byte("accepted\n"), nil
	}
	if len(remote) >= 4 && remote[1] == "deploy" && remote[2] == "production" && remote[3] == "dispatch-evidence" {
		runner.evidenceCalls++
		encoded, err := json.Marshal(runner.evidence)
		return append(encoded, '\n'), err
	}
	return nil, errors.New("unexpected remote dispatch test command")
}

func TestProductionActivationDispatchFaultReconciliation(t *testing.T) {
	const deploymentID = "prod-20260824T120000Z-dispatch-fixture"
	unit := productionActivationUnit(deploymentID)
	cases := []struct {
		name           string
		evidence       productionDispatchEvidence
		secondAccepted bool
		wantDispatches int
		wantObserved   bool
		wantAttempts   int
	}{
		{
			name: "failure before SSH acceptance redispatches exactly once",
			evidence: productionDispatchEvidence{
				Format: 1, DeploymentID: deploymentID, Unit: unit, UnitLoadState: "not-found",
			},
			secondAccepted: true, wantDispatches: 2, wantObserved: true, wantAttempts: 2,
		},
		{
			name: "failure after unit creation only observes existing job",
			evidence: productionDispatchEvidence{
				Format: 1, DeploymentID: deploymentID, Unit: unit, UnitLoadState: "loaded", UnitPresent: true,
			},
			wantDispatches: 1, wantObserved: true, wantAttempts: 1,
		},
		{
			name: "result transport failure with status only observes existing job",
			evidence: productionDispatchEvidence{
				Format: 1, DeploymentID: deploymentID, Unit: unit, UnitLoadState: "not-found", StatusPresent: true,
			},
			wantDispatches: 1, wantObserved: true, wantAttempts: 1,
		},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			controllerWorkspace := t.TempDir()
			planSHA256 := strings.Repeat("a", 64)
			plan := productionReleasePlan{
				Format: productionReleasePlanFormat, DeploymentID: deploymentID,
				ControllerWorkspace: controllerWorkspace, TargetAlias: productionTargetAlias,
				ProbeBinary: productionReleaseFilePlan{Path: filepath.Join(controllerWorkspace, "lmm-api")},
			}
			state := productionReleaseControllerState{
				Format: productionReleaseStateFormat, DeploymentID: deploymentID,
				PlanSHA256: planSHA256, Phase: productionReleasePhaseStaged,
				RemoteWorkspace: filepath.Join(defaultProductionPaths().WorkRoot, deploymentID),
				UpdatedUTC:      time.Date(2026, 8, 24, 12, 0, 0, 0, time.UTC),
			}
			runner := &productionDispatchFaultRunner{evidence: test.evidence, secondAccepted: test.secondAccepted}
			runtime := &productionReleaseRuntime{runner: runner, now: func() time.Time { return time.Date(2026, 8, 24, 12, 1, 0, 0, time.UTC) }}
			if err := runtime.dispatchProductionActivation(context.Background(), plan, &state); err != nil {
				t.Fatal(err)
			}
			if runner.dispatchCalls != test.wantDispatches || state.DispatchAttempts != test.wantAttempts || state.DispatchObserved != test.wantObserved {
				t.Fatalf("dispatches=%d attempts=%d observed=%t state=%#v", runner.dispatchCalls, state.DispatchAttempts, state.DispatchObserved, state)
			}
			persisted, exists, err := loadProductionReleaseControllerState(plan, planSHA256)
			if err != nil || !exists {
				t.Fatalf("load persisted dispatch state: exists=%t err=%v", exists, err)
			}
			if persisted.ActivationUnit != unit || persisted.DispatchAttempts != test.wantAttempts || persisted.DispatchObserved != test.wantObserved {
				t.Fatalf("persisted state=%#v", persisted)
			}
		})
	}
}
