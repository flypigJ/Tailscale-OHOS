package main

import "testing"

func TestControlProbeResultCanBeConsumedAndRetried(t *testing.T) {
	probe := controlProbeController{result: "FAILED | stage=dns"}

	if got := probe.startOrStatus(); got != "FAILED | stage=dns" {
		t.Fatalf("startOrStatus() = %q, want cached result", got)
	}
	if probe.result != "" {
		t.Fatalf("cached result was not consumed: %q", probe.result)
	}
}

func TestControlProbeRunningStatusDoesNotStartAnotherProbe(t *testing.T) {
	probe := controlProbeController{running: true}

	if got := probe.startOrStatus(); got != "OK | control probe running" {
		t.Fatalf("startOrStatus() = %q, want running status", got)
	}
}
