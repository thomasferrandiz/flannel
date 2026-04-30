//go:build !windows
// +build !windows

// Copyright 2024 flannel authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
package tailscale

import (
	"bytes"
	"context"
	"encoding/json"
	"net"
	"sync"
	"time"

	"github.com/flannel-io/flannel/pkg/backend"
	"github.com/flannel-io/flannel/pkg/lease"
	"github.com/flannel-io/flannel/pkg/subnet"
	"github.com/vishvananda/netlink"
	log "k8s.io/klog/v2"
)

const (
	routeCheckRetries = 10
)

type network struct {
	extIface    *backend.ExternalInterface
	lease       *lease.Lease
	sm          subnet.Manager
	mtu         int
	tsLinkIndex int
	tsLinkName  string
	routes      []netlink.Route
	v6Routes    []netlink.Route
	mu          sync.Mutex
}

func newNetwork(sm subnet.Manager, extIface *backend.ExternalInterface, l *lease.Lease, mtu, tsLinkIndex int, tsLinkName string) (*network, error) {
	return &network{
		extIface:    extIface,
		lease:       l,
		sm:          sm,
		mtu:         mtu,
		tsLinkIndex: tsLinkIndex,
		tsLinkName:  tsLinkName,
		routes:      make([]netlink.Route, 0, 10),
		v6Routes:    make([]netlink.Route, 0, 10),
	}, nil
}

func (n *network) Lease() *lease.Lease {
	return n.lease
}

func (n *network) MTU() int {
	return n.mtu
}

func (n *network) Run(ctx context.Context) {
	wg := sync.WaitGroup{}

	log.Info("Watching for new subnet leases")
	events := make(chan []lease.Event)
	wg.Add(1)
	go func() {
		subnet.WatchLeases(ctx, n.sm, n.lease, events)
		wg.Done()
	}()

	wg.Add(1)
	go func() {
		n.routeCheck(ctx)
		wg.Done()
	}()

	defer wg.Wait()

	for {
		select {
		case evtBatch, ok := <-events:
			if !ok {
				log.Infof("evts chan closed")
				return
			}
			n.handleSubnetEvents(evtBatch)
		case <-ctx.Done():
			n.removeAllRoutes()
			return
		}
	}
}

func (n *network) handleSubnetEvents(batch []lease.Event) {
	for _, event := range batch {
		switch event.Type {
		case lease.EventAdded:
			if event.Lease.Attrs.BackendType != "tailscale" {
				log.Warningf("Ignoring non-tailscale subnet: type=%v", event.Lease.Attrs.BackendType)
				continue
			}

			if event.Lease.EnableIPv4 {
				var attrs tailscaleLeaseAttrs
				if len(event.Lease.Attrs.BackendData) > 0 {
					if err := json.Unmarshal(event.Lease.Attrs.BackendData, &attrs); err != nil {
						log.Errorf("failed to unmarshal tailscale BackendData: %v", err)
						continue
					}
				}

				peerTsIP := net.ParseIP(attrs.TailscaleIP)
				if peerTsIP == nil {
					log.Errorf("invalid Tailscale IPv4 %q in BackendData", attrs.TailscaleIP)
					continue
				}

				route := netlink.Route{
					LinkIndex: n.tsLinkIndex,
					Dst:       event.Lease.Subnet.ToIPNet(),
					Gw:        peerTsIP,
					Flags:     int(netlink.FLAG_ONLINK),
				}

				log.Infof("Subnet added: %v via tailscale %v", event.Lease.Subnet, peerTsIP)
				if err := netlink.RouteReplace(&route); err != nil {
					log.Errorf("failed to add route to %v via %v: %v", event.Lease.Subnet, peerTsIP, err)
				} else {
					n.mu.Lock()
					n.routes = addToRouteList(route, n.routes)
					n.mu.Unlock()
				}
			}

			if event.Lease.EnableIPv6 {
				var attrs tailscaleLeaseAttrs
				if len(event.Lease.Attrs.BackendV6Data) > 0 {
					if err := json.Unmarshal(event.Lease.Attrs.BackendV6Data, &attrs); err != nil {
						log.Errorf("failed to unmarshal tailscale BackendV6Data: %v", err)
						continue
					}
				}

				peerTsIP := net.ParseIP(attrs.TailscaleIP)
				if peerTsIP == nil {
					log.Errorf("invalid Tailscale IPv6 %q in BackendV6Data", attrs.TailscaleIP)
					continue
				}

				route := netlink.Route{
					LinkIndex: n.tsLinkIndex,
					Dst:       event.Lease.IPv6Subnet.ToIPNet(),
					Gw:        peerTsIP,
					Flags:     int(netlink.FLAG_ONLINK),
				}

				log.Infof("Subnet added: %v via tailscale %v", event.Lease.IPv6Subnet, peerTsIP)
				if err := netlink.RouteReplace(&route); err != nil {
					log.Errorf("failed to add IPv6 route to %v via %v: %v", event.Lease.IPv6Subnet, peerTsIP, err)
				} else {
					n.mu.Lock()
					n.v6Routes = addToRouteList(route, n.v6Routes)
					n.mu.Unlock()
				}
			}

		case lease.EventRemoved:
			if event.Lease.Attrs.BackendType != "tailscale" {
				log.Warningf("Ignoring non-tailscale subnet: type=%v", event.Lease.Attrs.BackendType)
				continue
			}

			if event.Lease.EnableIPv4 {
				var attrs tailscaleLeaseAttrs
				if len(event.Lease.Attrs.BackendData) > 0 {
					if err := json.Unmarshal(event.Lease.Attrs.BackendData, &attrs); err != nil {
						log.Errorf("failed to unmarshal tailscale BackendData: %v", err)
						continue
					}
				}

				peerTsIP := net.ParseIP(attrs.TailscaleIP)
				route := netlink.Route{
					LinkIndex: n.tsLinkIndex,
					Dst:       event.Lease.Subnet.ToIPNet(),
					Gw:        peerTsIP,
					Flags:     int(netlink.FLAG_ONLINK),
				}

				log.Infof("Subnet removed: %v", event.Lease.Subnet)
				n.mu.Lock()
				n.routes = removeFromRouteList(route, n.routes)
				n.mu.Unlock()

				if err := netlink.RouteDel(&route); err != nil {
					log.Errorf("failed to delete route to %v: %v", event.Lease.Subnet, err)
				}
			}

			if event.Lease.EnableIPv6 {
				var attrs tailscaleLeaseAttrs
				if len(event.Lease.Attrs.BackendV6Data) > 0 {
					if err := json.Unmarshal(event.Lease.Attrs.BackendV6Data, &attrs); err != nil {
						log.Errorf("failed to unmarshal tailscale BackendV6Data: %v", err)
						continue
					}
				}

				peerTsIP := net.ParseIP(attrs.TailscaleIP)
				route := netlink.Route{
					LinkIndex: n.tsLinkIndex,
					Dst:       event.Lease.IPv6Subnet.ToIPNet(),
					Gw:        peerTsIP,
					Flags:     int(netlink.FLAG_ONLINK),
				}

				log.Infof("Subnet removed: %v", event.Lease.IPv6Subnet)
				n.mu.Lock()
				n.v6Routes = removeFromRouteList(route, n.v6Routes)
				n.mu.Unlock()

				if err := netlink.RouteDel(&route); err != nil {
					log.Errorf("failed to delete IPv6 route to %v: %v", event.Lease.IPv6Subnet, err)
				}
			}

		default:
			log.Error("Internal error: unknown event type: ", int(event.Type))
		}
	}
}

func (n *network) routeCheck(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-time.After(routeCheckRetries * time.Second):
			n.checkTailscaleLink()
			n.mu.Lock()
			n.checkRoutes(n.routes, netlink.FAMILY_V4)
			n.checkRoutes(n.v6Routes, netlink.FAMILY_V6)
			n.mu.Unlock()
		}
	}
}

func (n *network) checkTailscaleLink() {
	link, err := netlink.LinkByName(n.tsLinkName)
	if err != nil {
		log.Warningf("Tailscale interface %s not found: %v", n.tsLinkName, err)
		return
	}
	newIndex := link.Attrs().Index
	if newIndex != n.tsLinkIndex {
		log.Infof("Tailscale interface %s index changed from %d to %d, updating routes", n.tsLinkName, n.tsLinkIndex, newIndex)
		n.mu.Lock()
		n.tsLinkIndex = newIndex
		for i := range n.routes {
			n.routes[i].LinkIndex = newIndex
		}
		for i := range n.v6Routes {
			n.v6Routes[i].LinkIndex = newIndex
		}
		n.mu.Unlock()
	}
}

func (n *network) checkRoutes(routes []netlink.Route, family int) {
	routeList, err := netlink.RouteList(nil, family)
	if err != nil {
		log.Errorf("Error fetching route list: %v", err)
		return
	}

	for _, route := range routes {
		exists := false
		for _, r := range routeList {
			if r.Dst == nil {
				continue
			}
			if routeEqual(r, route) {
				exists = true
				break
			}
		}
		if !exists {
			if err := netlink.RouteReplace(&route); err != nil {
				log.Errorf("Error recovering route to %v via %v: %v", route.Dst, route.Gw, err)
			} else {
				log.Infof("Route recovered %v via %v", route.Dst, route.Gw)
			}
		}
	}
}

func (n *network) removeAllRoutes() {
	n.mu.Lock()
	defer n.mu.Unlock()

	for _, route := range n.routes {
		if err := netlink.RouteDel(&route); err != nil {
			log.Errorf("Error deleting route to %v: %v", route.Dst, err)
		}
	}
	n.routes = nil

	for _, route := range n.v6Routes {
		if err := netlink.RouteDel(&route); err != nil {
			log.Errorf("Error deleting IPv6 route to %v: %v", route.Dst, err)
		}
	}
	n.v6Routes = nil
}

func addToRouteList(route netlink.Route, routes []netlink.Route) []netlink.Route {
	for _, r := range routes {
		if routeEqual(r, route) {
			return routes
		}
	}
	return append(routes, route)
}

func removeFromRouteList(route netlink.Route, routes []netlink.Route) []netlink.Route {
	for i, r := range routes {
		if routeEqual(r, route) {
			return append(routes[:i], routes[i+1:]...)
		}
	}
	return routes
}

func routeEqual(x, y netlink.Route) bool {
	if x.Dst == nil || y.Dst == nil {
		return false
	}
	return x.Dst.IP.Equal(y.Dst.IP) && x.Gw.Equal(y.Gw) && bytes.Equal(x.Dst.Mask, y.Dst.Mask) && x.LinkIndex == y.LinkIndex
}
