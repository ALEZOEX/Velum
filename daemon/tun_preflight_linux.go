//go:build linux

package main

import (
	"errors"
	"fmt"
	"net/netip"
	"time"

	"github.com/sagernet/netlink"
	"golang.org/x/sys/unix"
)

// No mutating netlink methods are exposed to the preflight.
type tunResourceReader interface {
	LinkList() ([]netlink.Link, error)
	AddrList(netlink.Link, int) ([]netlink.Addr, error)
	RuleList(int) ([]netlink.Rule, error)
	RouteListFiltered(int, *netlink.Route, uint64) ([]netlink.Route, error)
}

func checkTUNResources(cfg map[string]any) error {
	handle, err := netlink.NewHandle(unix.NETLINK_ROUTE)
	if err != nil {
		return fmt.Errorf("TUN не запущен: невозможно открыть netlink для проверки ресурсов: %w", err)
	}
	defer handle.Close()
	if err = handle.SetSocketTimeout(2 * time.Second); err != nil {
		return fmt.Errorf("TUN не запущен: невозможно ограничить время проверки netlink: %w", err)
	}
	return checkLinuxTUNResources(cfg, handle)
}

func checkLinuxTUNResources(cfg map[string]any, reader tunResourceReader) error {
	inbounds, _ := cfg["inbounds"].([]any)
	var tun map[string]any
	for _, raw := range inbounds {
		inbound, ok := raw.(map[string]any)
		if ok && inbound["type"] == "tun" {
			if tun != nil {
				return errors.New("TUN не запущен: несколько TUN-интерфейсов не поддерживаются")
			}
			tun = inbound
		}
	}
	if tun == nil || tun["interface_name"] != "velum0" || tun["auto_route"] != true ||
		tun["iproute2_table_index"] != linuxTUNTable || tun["iproute2_rule_index"] != linuxTUNRuleStart {
		return errors.New("TUN не запущен: конфигурация не использует проверяемые ресурсы Velum")
	}
	// These options require additional resources/priority calculations. Refuse
	// future config changes rather than silently checking an incomplete set.
	for _, key := range []string{"auto_redirect", "include_interface", "exclude_interface", "include_uid", "exclude_uid", "include_uid_range", "exclude_uid_range", "include_android_user", "include_package", "exclude_package"} {
		if _, exists := tun[key]; exists {
			return fmt.Errorf("TUN не запущен: проверка ресурсов не поддерживает %s", key)
		}
	}
	addresses, ok := tun["address"].([]string)
	if !ok || len(addresses) == 0 {
		return errors.New("TUN не запущен: отсутствуют проверяемые адреса интерфейса")
	}
	prefixes := make([]netip.Prefix, 0, len(addresses))
	for _, value := range addresses {
		prefix, err := netip.ParsePrefix(value)
		if err != nil {
			return fmt.Errorf("TUN не запущен: некорректный адрес интерфейса %q", value)
		}
		prefixes = append(prefixes, prefix.Masked())
	}
	links, err := reader.LinkList()
	if err != nil {
		return fmt.Errorf("TUN не запущен: не удалось проверить интерфейсы: %w", err)
	}
	for _, link := range links {
		if link.Attrs().Name == "velum0" {
			return errors.New("TUN не запущен: интерфейс velum0 уже существует; его владелец неизвестен, автоматическое удаление запрещено")
		}
	}
	// Both families are mandatory even with IPv6 disabled: strict_route may add
	// an unreachable IPv6 rule, and unsetRules scans FAMILY_ALL regardless.
	for _, family := range []int{netlink.FAMILY_V4, netlink.FAMILY_V6} {
		label := "IPv4"
		if family == netlink.FAMILY_V6 {
			label = "IPv6"
		}
		rules, err := reader.RuleList(family)
		if err != nil {
			return fmt.Errorf("TUN не запущен: не удалось проверить %s policy rules: %w", label, err)
		}
		for _, rule := range rules {
			switch {
			case inTUNRuleRange(rule.Priority):
				return fmt.Errorf("TUN не запущен: %s policy rule с приоритетом %d занимает диапазон Velum %d–%d; чужие правила не удаляются", label, rule.Priority, linuxTUNRuleStart, linuxTUNRuleEnd)
			case rule.Table == linuxTUNTable:
				return fmt.Errorf("TUN не запущен: %s policy rule %d ссылается на таблицу Velum %d", label, rule.Priority, linuxTUNTable)
			case inTUNRuleRange(rule.Goto):
				return fmt.Errorf("TUN не запущен: %s policy rule %d содержит goto в диапазон Velum (%d)", label, rule.Priority, rule.Goto)
			case rule.IifName == "velum0" || rule.OifName == "velum0":
				return fmt.Errorf("TUN не запущен: %s policy rule %d ссылается на velum0", label, rule.Priority)
			}
		}
		// Table UNSPEC + RT_FILTER_TABLE means all tables in this netlink
		// version. RouteList(nil, family) would silently omit non-main tables.
		routes, err := reader.RouteListFiltered(family, &netlink.Route{Table: unix.RT_TABLE_UNSPEC}, netlink.RT_FILTER_TABLE)
		if err != nil {
			return fmt.Errorf("TUN не запущен: не удалось проверить %s routing tables: %w", label, err)
		}
		for _, route := range routes {
			if route.Table == linuxTUNTable {
				return fmt.Errorf("TUN не запущен: таблица %s %d содержит маршрут %s; автоматическая очистка запрещена", label, linuxTUNTable, route.String())
			}
			// Connected/local networks must not overlap addresses installed by
			// configure(). Ignore default/split-default routes of other VPNs.
			if route.Dst != nil && (route.Scope == netlink.SCOPE_LINK || route.Scope == netlink.SCOPE_HOST) {
				prefix, err := netip.ParsePrefix(route.Dst.String())
				if err != nil {
					return fmt.Errorf("TUN не запущен: невозможно проверить %s маршрут %v: %w", label, route.Dst, err)
				}
				if overlapsTUNPrefixes(prefix, prefixes) {
					return fmt.Errorf("TUN не запущен: адреса Velum пересекаются с %s маршрутом %s в таблице %d", label, route.Dst, route.Table)
				}
			}
		}
		addrs, err := reader.AddrList(nil, family)
		if err != nil {
			return fmt.Errorf("TUN не запущен: не удалось проверить %s адреса интерфейсов: %w", label, err)
		}
		for _, addr := range addrs {
			if addr.IPNet == nil {
				continue
			}
			prefix, err := netip.ParsePrefix(addr.IPNet.String())
			if err != nil {
				return fmt.Errorf("TUN не запущен: невозможно проверить %s адрес %v: %w", label, addr.IPNet, err)
			}
			if overlapsTUNPrefixes(prefix, prefixes) {
				return fmt.Errorf("TUN не запущен: адреса Velum пересекаются с %s адресом %s интерфейса %d", label, prefix, addr.LinkIndex)
			}
		}
	}
	return nil
}

func inTUNRuleRange(value int) bool {
	return value >= linuxTUNRuleStart && value <= linuxTUNRuleEnd
}

func overlapsTUNPrefixes(prefix netip.Prefix, prefixes []netip.Prefix) bool {
	for _, own := range prefixes {
		if prefix.Overlaps(own) {
			return true
		}
	}
	return false
}
