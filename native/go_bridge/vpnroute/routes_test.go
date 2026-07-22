package vpnroute

import (
	"net/netip"
	"strings"
	"testing"

	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tailcfg"
	"tailscale.com/types/key"
	"tailscale.com/types/views"
)

func TestBuildUsesExitNodePreferenceBeforeStatusRefresh(t *testing.T) {
	exitNodeID := tailcfg.StableNodeID("node-exit")
	allowedIPs := views.SliceOf([]netip.Prefix{
		netip.MustParsePrefix("100.64.0.2/32"),
		netip.MustParsePrefix("0.0.0.0/0"),
		netip.MustParsePrefix("::/0"),
	})
	status := &ipnstate.Status{
		Peer: map[key.NodePublic]*ipnstate.PeerStatus{
			{}: {
				ID:             exitNodeID,
				ExitNode:       false,
				ExitNodeOption: true,
				AllowedIPs:     &allowedIPs,
			},
		},
	}
	prefs := &ipn.Prefs{ExitNodeID: exitNodeID}

	routes, subnetRoutes := Build(status, prefs)
	if got, want := strings.Join(routes, ","), "0.0.0.0/0,::/0"; got != want {
		t.Fatalf("routes = %q, want %q", got, want)
	}
	if subnetRoutes != 0 {
		t.Fatalf("subnetRoutes = %d, want 0", subnetRoutes)
	}
	if !Contains(routes, "0.0.0.0/0") {
		t.Fatal("IPv4 default route is missing")
	}
	if Contains(routes, "10.0.0.0/8") {
		t.Fatal("unexpected route reported as present")
	}
}

func TestBuildRejectsUnselectedExitNode(t *testing.T) {
	allowedIPs := views.SliceOf([]netip.Prefix{
		netip.MustParsePrefix("0.0.0.0/0"),
		netip.MustParsePrefix("::/0"),
	})
	status := &ipnstate.Status{
		Peer: map[key.NodePublic]*ipnstate.PeerStatus{
			{}: {
				ID:             tailcfg.StableNodeID("node-exit"),
				ExitNodeOption: true,
				AllowedIPs:     &allowedIPs,
			},
		},
	}
	prefs := &ipn.Prefs{ExitNodeID: tailcfg.StableNodeID("node-other")}

	routes, subnetRoutes := Build(status, prefs)
	if len(routes) != 0 || subnetRoutes != 0 {
		t.Fatalf("unselected exit node produced routes=%v subnetRoutes=%d", routes, subnetRoutes)
	}
}

func TestBuildKeepsApprovedSubnetRoutes(t *testing.T) {
	primaryRoutes := views.SliceOf([]netip.Prefix{
		netip.MustParsePrefix("10.20.30.40/24"),
	})
	status := &ipnstate.Status{
		Peer: map[key.NodePublic]*ipnstate.PeerStatus{
			{}: {PrimaryRoutes: &primaryRoutes},
		},
	}

	routes, subnetRoutes := Build(status, &ipn.Prefs{RouteAll: true})
	if got, want := strings.Join(routes, ","), "10.20.30.0/24"; got != want {
		t.Fatalf("routes = %q, want %q", got, want)
	}
	if subnetRoutes != 1 {
		t.Fatalf("subnetRoutes = %d, want 1", subnetRoutes)
	}
}
