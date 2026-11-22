package main

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/net/memnet"
)

func TestNormalizeDeviceAuthKey(t *testing.T) {
	for _, tc := range []struct {
		value  string
		custom bool
		reason string
	}{
		{"", false, "empty"}, {" \n ", true, "empty"},
		{" tskey-auth-example_secret \r\n", false, ""},
		{"tskey-api-example", true, "management_key"},
		{"tskey-client-example", false, "management_key"},
		{"headscale123", false, "invalid"}, {"headscale123", true, ""},
		{"tskey-auth-", false, "invalid"}, {"tskey-unknown-example", true, "invalid"},
		{"tskey-auth-abc\x00def", false, "invalid"},
		{"tskey-auth-abc\ndef", false, "invalid"},
		{"tskey-auth-中文", true, "invalid"},
		{"file:/private/key", true, "invalid"},
		{strings.Repeat("a", 4097), true, "invalid"},
	} {
		key, reason := normalizeDeviceAuthKey(tc.value, tc.custom)
		if reason != tc.reason || reason != "" && key != "" {
			t.Fatalf("validation category = %q; want %q (custom=%v)", reason, tc.reason, tc.custom)
		}
	}
}

func TestAuthenticateDeviceWithKey(t *testing.T) {
	for _, tc := range []struct {
		name       string
		initial    string
		nodeKey    bool
		state      ipn.State
		reject     bool
		stale      bool
		startError bool
		want       string
	}{
		{name: "new node", initial: "NeedsLogin", state: ipn.Running, want: "OK | auth key | authenticated"},
		{name: "expired node", initial: "NeedsLogin", nodeKey: true, state: ipn.Running, want: "OK | auth key | authenticated"},
		{name: "approval", initial: "NeedsLogin", state: ipn.NeedsMachineAuth, want: "OK | auth key | needs_approval"},
		{name: "rejected secret is not echoed", initial: "NeedsLogin", reject: true, want: "FAILED | auth key | rejected"},
		{name: "active account preserved", initial: "Running", want: "FAILED | auth key | already_authenticated"},
		{name: "pending account preserved", initial: "NeedsMachineAuth", want: "FAILED | auth key | already_authenticated"},
		{name: "backend changed", initial: "NeedsLogin", state: ipn.Running, stale: true, want: "FAILED | auth key | backend_changed"},
		{name: "start failure is not retried", initial: "NeedsLogin", startError: true, want: "FAILED | auth key | request_failed"},
		{name: "bounded wait", initial: "NeedsLogin", want: "FAILED | auth key | timeout"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			const secret = "tskey-auth-fake_test_secret"
			events := make(chan ipn.Notify, 8)
			starts, triggers := 0, 0
			listener := memnet.Listen("local-tailscaled.sock:80")
			srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch r.URL.Path {
				case "/localapi/v0/status":
					json.NewEncoder(w).Encode(ipnstate.Status{BackendState: tc.initial, HaveNodeKey: tc.nodeKey})
				case "/localapi/v0/watch-ipn-bus":
					w.Header().Set("Content-Type", "application/json")
					w.WriteHeader(http.StatusOK)
					w.(http.Flusher).Flush()
					for {
						select {
						case event := <-events:
							json.NewEncoder(w).Encode(event)
							w.(http.Flusher).Flush()
						case <-r.Context().Done():
							return
						}
					}
				case "/localapi/v0/start":
					starts++
					var opts ipn.Options
					if err := json.NewDecoder(r.Body).Decode(&opts); err != nil || opts.AuthKey != secret || opts.UpdatePrefs != nil {
						t.Error("auth key was not passed through Start, or preferences were replaced")
					}
					if tc.startError {
						http.Error(w, secret, http.StatusBadRequest)
						return
					}
					if tc.reject {
						message := "invalid key: " + secret
						events <- ipn.Notify{ErrMessage: &message}
					} else if tc.state != 0 {
						state := tc.state
						events <- ipn.Notify{State: &state}
					}
					w.WriteHeader(http.StatusNoContent)
				case "/localapi/v0/login-interactive":
					triggers++
					w.WriteHeader(http.StatusNoContent)
				default:
					t.Errorf("unexpected mutation or request: %s", r.URL.Path)
					w.WriteHeader(http.StatusNotFound)
				}
			})}
			go srv.Serve(listener)
			defer srv.Close()
			client := &local.Client{OmitAuth: true, Dial: listener.Dial}
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			if _, err := client.StatusWithoutPeers(ctx); err != nil {
				t.Fatalf("fake local API status: %v", err)
			}
			if tc.name == "bounded wait" {
				cancel()
				ctx, cancel = context.WithTimeout(context.Background(), 100*time.Millisecond)
				defer cancel()
			}
			checks := 0
			got := authenticateDeviceWithKey(ctx, client, secret, func() bool {
				checks++
				return checks == 1 || !tc.stale
			})
			if got != tc.want || strings.Contains(got, secret) {
				t.Fatalf("result category = %q; want %q", got, tc.want)
			}
			if tc.initial != "NeedsLogin" {
				if starts != 0 || triggers != 0 {
					t.Fatal("existing account was mutated")
				}
			} else if starts != 1 {
				t.Fatalf("Start called %d times", starts)
			}
			if tc.nodeKey && triggers != 0 {
				t.Fatal("existing node was forced through reauthentication")
			}
			if !tc.nodeKey && !tc.startError && tc.initial == "NeedsLogin" && triggers != 1 {
				t.Fatal("new node login was not triggered exactly once")
			}
		})
	}
}
