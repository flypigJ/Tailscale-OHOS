package main

import (
	"strings"
	"testing"

	"tailscale.com/tailcfg"
)

func TestPeerStableKeyIsDeterministicAndOpaque(t *testing.T) {
	id := tailcfg.StableNodeID("node-1234567890")
	first := peerStableKey(id)
	second := peerStableKey(id)
	if first != second {
		t.Fatalf("stable key changed: %q != %q", first, second)
	}
	if strings.Contains(first, string(id)) {
		t.Fatalf("stable key leaked node ID: %q", first)
	}
	if first == peerStableKey(tailcfg.StableNodeID("node-other")) {
		t.Fatalf("different node IDs produced the same test key: %q", first)
	}
}

func TestClassifyPeerDevice(t *testing.T) {
	tests := []struct {
		name  string
		os    string
		model string
		want  string
	}{
		{name: "foldable", os: "harmonyos", model: "Mate X6", want: "foldable"},
		{name: "tablet", os: "harmonyos", model: "MatePad Pro", want: "tablet"},
		{name: "laptop", os: "windows", model: "ThinkPad X1", want: "laptop"},
		{name: "phone", os: "android", model: "Pixel", want: "phone"},
		{name: "computer fallback", os: "linux", model: "", want: "computer"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := classifyPeerDevice(test.os, test.model); got != test.want {
				t.Fatalf("classifyPeerDevice(%q, %q) = %q, want %q", test.os, test.model, got, test.want)
			}
		})
	}
}

func TestHarmonyHostnameFallback(t *testing.T) {
	if got := harmonyHostname("default"); got != "harmonyos-next" {
		t.Fatalf("harmonyHostname(default) = %q", got)
	}
	if got := harmonyHostname("Mate 70 Pro"); got == "" || strings.Contains(got, " ") {
		t.Fatalf("harmonyHostname did not sanitize model: %q", got)
	}
}
