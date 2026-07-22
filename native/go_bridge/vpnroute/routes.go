package vpnroute

import (
	"net/netip"
	"sort"

	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
)

// Contains reports whether routes contains the exact canonical prefix.
func Contains(routes []string, prefix string) bool {
	index := sort.SearchStrings(routes, prefix)
	return index < len(routes) && routes[index] == prefix
}

// Build returns the system VPN routes derived from the current netmap and
// user preferences, plus the number of non-default subnet routes.
func Build(status *ipnstate.Status, prefs *ipn.Prefs) ([]string, int) {
	// PrimaryRoutes contains control-plane-approved routes for the peers that
	// currently own them. Exit-node selection is authoritative in prefs;
	// PeerStatus.ExitNode can briefly lag behind EditPrefs during startup. If
	// the VPN config is captured in that window, omitting the default routes
	// leaves the session connected but unable to carry public traffic.
	routeSet := make(map[string]struct{})
	for _, peer := range status.Peer {
		if prefs.RouteAll && peer.PrimaryRoutes != nil {
			for _, prefix := range peer.PrimaryRoutes.All() {
				if prefix.IsValid() {
					routeSet[prefix.Masked().String()] = struct{}{}
				}
			}
		}
		selectedExitNode := peer.ExitNode ||
			(!prefs.ExitNodeID.IsZero() && peer.ID == prefs.ExitNodeID)
		if selectedExitNode && peer.AllowedIPs != nil {
			for _, prefix := range peer.AllowedIPs.All() {
				if prefix.IsValid() && prefix.Bits() == 0 {
					routeSet[prefix.Masked().String()] = struct{}{}
				}
			}
		}
	}

	routes := make([]string, 0, len(routeSet))
	subnetRoutes := 0
	for route := range routeSet {
		routes = append(routes, route)
		if prefix, err := netip.ParsePrefix(route); err == nil && prefix.Bits() > 0 {
			subnetRoutes++
		}
	}
	sort.Strings(routes)
	return routes, subnetRoutes
}
