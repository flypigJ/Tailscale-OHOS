package main

import (
	"context"
	"errors"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/types/netmap"
)

var errVPNNetMapNotReady = errors.New("current network map unavailable")

// waitForCurrentNetMap reads the one initial notification that LocalAPI emits
// for a new watcher. On this platform later NetMap notifications are not
// emitted, so keeping the watcher open cannot make an incomplete initial map
// become current. Callers should retry the whole query instead.
func waitForCurrentNetMap(ctx context.Context, client *local.Client) (*netmap.NetworkMap, error) {
	if client == nil {
		return nil, errVPNNetMapNotReady
	}
	watcher, err := client.WatchIPNBus(ctx,
		ipn.NotifyInitialNetMap|ipn.NotifyInitialState|ipn.NotifyNoPrivateKeys)
	if err != nil {
		return nil, err
	}
	defer watcher.Close()

	notify, err := watcher.Next()
	if err != nil {
		return nil, err
	}
	if notify.NetMap == nil || notify.NetMap.Cached || !notify.NetMap.SelfNode.Valid() || notify.NetMap.SelfNode.ID() == 0 {
		return nil, errVPNNetMapNotReady
	}
	return notify.NetMap, nil
}
