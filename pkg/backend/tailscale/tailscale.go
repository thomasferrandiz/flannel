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
	"context"
	"encoding/json"
	"fmt"
	"net"
	"sync"

	"github.com/flannel-io/flannel/pkg/backend"
	"github.com/flannel-io/flannel/pkg/ip"
	"github.com/flannel-io/flannel/pkg/lease"
	"github.com/flannel-io/flannel/pkg/subnet"
	"github.com/vishvananda/netlink"
	log "k8s.io/klog/v2"
	"tailscale.com/client/local"
)

func init() {
	backend.Register("tailscale", New)
}

type TailscaleBackend struct {
	sm       subnet.Manager
	extIface *backend.ExternalInterface
}

type tailscaleLeaseAttrs struct {
	TailscaleIP string
}

func New(sm subnet.Manager, extIface *backend.ExternalInterface) (backend.Backend, error) {
	be := &TailscaleBackend{
		sm:       sm,
		extIface: extIface,
	}
	return be, nil
}

func newSubnetAttrs(publicIP net.IP, publicIPv6 net.IP, enableIPv4, enableIPv6 bool, tsIPv4, tsIPv6 net.IP) (*lease.LeaseAttrs, error) {
	leaseAttrs := &lease.LeaseAttrs{
		BackendType: "tailscale",
	}

	if publicIP != nil {
		leaseAttrs.PublicIP = ip.FromIP(publicIP)
	}

	if enableIPv4 && tsIPv4 != nil {
		data, err := json.Marshal(&tailscaleLeaseAttrs{TailscaleIP: tsIPv4.String()})
		if err != nil {
			return nil, err
		}
		leaseAttrs.BackendData = json.RawMessage(data)
	}

	if publicIPv6 != nil {
		leaseAttrs.PublicIPv6 = ip.FromIP6(publicIPv6)
	}

	if enableIPv6 && tsIPv6 != nil {
		data, err := json.Marshal(&tailscaleLeaseAttrs{TailscaleIP: tsIPv6.String()})
		if err != nil {
			return nil, err
		}
		leaseAttrs.BackendV6Data = json.RawMessage(data)
	}

	return leaseAttrs, nil
}

func (be *TailscaleBackend) RegisterNetwork(ctx context.Context, wg *sync.WaitGroup, config *subnet.Config) (backend.Network, error) {
	cfg := struct {
		InterfaceName string
		MTU           int
	}{
		InterfaceName: "tailscale0",
		MTU:           0,
	}

	if len(config.Backend) > 0 {
		if err := json.Unmarshal(config.Backend, &cfg); err != nil {
			return nil, fmt.Errorf("error decoding tailscale backend config: %w", err)
		}
	}

	var tsClient local.Client
	status, err := tsClient.StatusWithoutPeers(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to tailscaled: is tailscaled running? error: %w", err)
	}

	if status.BackendState != "Running" {
		return nil, fmt.Errorf("tailscaled is not in Running state (current: %s). Run 'tailscale up' to authenticate", status.BackendState)
	}

	var tsIPv4, tsIPv6 net.IP
	for _, addr := range status.TailscaleIPs {
		if addr.Is4() && tsIPv4 == nil {
			tsIPv4 = addr.AsSlice()
		}
		if addr.Is6() && tsIPv6 == nil {
			tsIPv6 = addr.AsSlice()
		}
	}

	if config.EnableIPv4 && tsIPv4 == nil {
		return nil, fmt.Errorf("IPv4 enabled but tailscaled has no IPv4 address")
	}
	if config.EnableIPv6 && tsIPv6 == nil {
		return nil, fmt.Errorf("IPv6 enabled but tailscaled has no IPv6 address")
	}

	tsLink, err := netlink.LinkByName(cfg.InterfaceName)
	if err != nil {
		return nil, fmt.Errorf("tailscale interface %q not found: %w. Is tailscaled running?", cfg.InterfaceName, err)
	}

	mtu := cfg.MTU
	if mtu == 0 {
		mtu = tsLink.Attrs().MTU
	}

	log.Infof("Tailscale backend: using interface %s (index %d, MTU %d)", cfg.InterfaceName, tsLink.Attrs().Index, mtu)
	if tsIPv4 != nil {
		log.Infof("Tailscale IPv4: %s", tsIPv4)
	}
	if tsIPv6 != nil {
		log.Infof("Tailscale IPv6: %s", tsIPv6)
	}

	subnetAttrs, err := newSubnetAttrs(be.extIface.ExtAddr, be.extIface.ExtV6Addr, config.EnableIPv4, config.EnableIPv6, tsIPv4, tsIPv6)
	if err != nil {
		return nil, err
	}

	l, err := be.sm.AcquireLease(ctx, subnetAttrs)
	switch err {
	case nil:
	case context.Canceled, context.DeadlineExceeded:
		return nil, err
	default:
		return nil, fmt.Errorf("failed to acquire lease: %w", err)
	}

	return newNetwork(be.sm, be.extIface, l, mtu, tsLink.Attrs().Index, cfg.InterfaceName)
}
