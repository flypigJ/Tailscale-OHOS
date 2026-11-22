package main

import (
	"context"
	"strings"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
)

// Device auth keys are credentials, never settings or diagnostic text. Headscale
// uses unprefixed keys; only permit those with a custom control server.
func normalizeDeviceAuthKey(value string, customControl bool) (string, string) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", "empty"
	}
	if strings.HasPrefix(value, "tskey-api-") || strings.HasPrefix(value, "tskey-client-") {
		return "", "management_key"
	}
	if len(value) > 4096 || (strings.HasPrefix(value, "tskey-") && !strings.HasPrefix(value, "tskey-auth-")) ||
		(!customControl && !strings.HasPrefix(value, "tskey-auth-")) || value == "tskey-auth-" {
		return "", "invalid"
	}
	for _, c := range value {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return "", "invalid"
		}
	}
	return value, ""
}

func authenticateDeviceWithKey(ctx context.Context, client *local.Client, authKey string, stillCurrent func() bool) string {
	status, err := client.StatusWithoutPeers(ctx)
	if err != nil {
		return "FAILED | auth key | unavailable"
	}
	// Replacing an existing account requires the existing explicit logout flow.
	if status.BackendState != "NeedsLogin" {
		return "FAILED | auth key | already_authenticated"
	}
	// Subscribe before Start so fast success/rejection cannot be missed. Do not
	// request initial state, which may contain the previous browser login URL.
	watcher, err := client.WatchIPNBus(ctx, ipn.NotifyNoPrivateKeys)
	if err != nil {
		return "FAILED | auth key | unavailable"
	}
	defer watcher.Close()
	if !stillCurrent() {
		return "FAILED | auth key | backend_changed"
	}
	// Nil UpdatePrefs preserves control URL, routes and the persistent node keys.
	err = client.Start(ctx, ipn.Options{AuthKey: authKey})
	authKey = ""
	if err != nil {
		return "FAILED | auth key | request_failed"
	}
	// Match tailscale up: a new/logged-out node still needs a login trigger
	// after Start installs the auth key. This does not open a browser; the
	// control client uses the key supplied above for registration.
	if !status.HaveNodeKey {
		if err := client.StartLoginInteractive(ctx); err != nil {
			return "FAILED | auth key | request_failed"
		}
	}
	for {
		notify, nextErr := watcher.Next()
		if !stillCurrent() {
			return "FAILED | auth key | backend_changed"
		}
		if nextErr != nil {
			if ctx.Err() == context.DeadlineExceeded {
				return "FAILED | auth key | timeout"
			}
			return "FAILED | auth key | unavailable"
		}
		if notify.ErrMessage != nil {
			// Control errors can echo credentials. Only return this fixed category.
			return "FAILED | auth key | rejected"
		}
		if notify.State != nil {
			switch *notify.State {
			case ipn.Running:
				return "OK | auth key | authenticated"
			case ipn.NeedsMachineAuth:
				return "OK | auth key | needs_approval"
			}
		}
	}
}
