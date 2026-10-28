#!/bin/bash
# Lab checker (`make test`): NAT, DHCP and the WireGuard point-to-site VPN.
# Discovers addresses from the running containers, so any valid student
# addressing passes. Exit status = number of failed checks.
set -u

# Students' accounts aren't in the docker group: go through sudo unless root
if [ "$(id -u)" -ne 0 ]; then
    docker() { sudo docker "$@"; }
fi

ISP=${ISP:-192.168.1.254}   # transit gateway (Docker host); only reachable from a LAN via NAT
HOME_GW_LAN=172.20.21.254

pass=0
fail=0

ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; fail=$((fail + 1)); }

ping_from() {  # container target
    docker exec "$1" ping -c 2 -W 2 "$2" >/dev/null 2>&1
}

ipv4_of() {  # container interface -> first IPv4 address (no prefix)
    docker exec "$1" ip -4 -o addr show dev "$2" 2>/dev/null | awk '{split($4, a, "/"); print a[1]; exit}'
}

check_ping() {  # description container target hint
    if ping_from "$2" "$3"; then ok "$1"; else bad "$1" "$4"; fi
}

for c in home-gw home-pc office-gw office-pc; do
    if [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" != true ]; then
        echo "container $c is not running; start the lab with 'make up'" >&2
        exit 1
    fi
done

echo "== NAT / DHCP"
check_ping "1. office-pc can ping $ISP" office-pc "$ISP" \
    "office-pc needs an IP + default route (DHCP from office-gw), office-gw needs source NAT"
check_ping "2. home-gw can ping $ISP" home-gw "$ISP" \
    "home-gw eth0 needs an address (DHCP) and a default route via $ISP"

home_pc_ip=$(ipv4_of home-pc eth0)
if [ -z "$home_pc_ip" ]; then
    bad "3. home-pc can ping home-gw ($HOME_GW_LAN)" "home-pc has no IPv4 address on eth0 (DHCP server on home-gw? run 'dhclient -v eth0')"
    bad "4. home-pc can ping $ISP" "home-pc has no IPv4 address"
else
    check_ping "3. home-pc ($home_pc_ip) can ping home-gw ($HOME_GW_LAN)" home-pc "$HOME_GW_LAN" \
        "home-gw eth1 should be $HOME_GW_LAN/24 on home-lan"
    check_ping "4. home-pc can ping $ISP" home-pc "$ISP" \
        "home-pc needs a default route via $HOME_GW_LAN, home-gw needs source NAT out eth0"
fi

echo "== WireGuard (office-pc -> home)"
wg_if=$(docker exec office-pc wg show interfaces 2>/dev/null | awk '{print $1}')
home_wg_ip=$(docker exec home-gw sh -c 'for i in $(wg show interfaces); do ip -4 -o addr show dev $i; done' 2>/dev/null \
    | awk '{split($4, a, "/"); print a[1]; exit}')
if [ -z "$wg_if" ]; then
    bad "5. office-pc has a WireGuard interface up" "run 'wg-quick up wg0' on office-pc"
elif [ -z "$home_wg_ip" ]; then
    bad "5. home-gw has a WireGuard interface with an address" "configure 'interfaces wireguard wg0' on home-gw"
else
    ok "5. WireGuard up (office-pc $wg_if, home-gw $home_wg_ip)"

    # A handshake may only happen once traffic flows; ping first, then check
    ping_from office-pc "$home_wg_ip"
    handshake=$(docker exec office-pc wg show "$wg_if" latest-handshakes 2>/dev/null | awk '$2 > 0 {print $2; exit}')
    if [ -n "$handshake" ]; then
        ok "5a. WireGuard handshake completed"
    else
        bad "5a. WireGuard handshake completed" "check public keys on both sides and office-pc's Endpoint (home-gw eth0 IP:port)"
    fi

    check_ping "5b. office-pc can ping home-gw over the tunnel ($home_wg_ip)" office-pc "$home_wg_ip" \
        "check Address/AllowedIPs on both sides"

    if [ -z "$home_pc_ip" ]; then
        bad "5c. office-pc can reach home-pc over the tunnel" "home-pc has no IPv4 address"
    else
        route_dev=$(docker exec office-pc ip -4 route get "$home_pc_ip" 2>/dev/null | grep -o 'dev [^ ]*' | cut -d' ' -f2)
        if [ "$route_dev" = "$wg_if" ]; then
            ok "5c. office-pc routes home-pc ($home_pc_ip) via $wg_if"
        else
            bad "5c. office-pc routes home-pc ($home_pc_ip) via $wg_if" "goes via '${route_dev:-nothing}'; add 172.20.21.0/24 to AllowedIPs"
        fi
        check_ping "5d. office-pc can ping home-pc over the tunnel" office-pc "$home_pc_ip" \
            "home-gw peer allowed-ips must include office-pc's tunnel address; home-pc needs a default route via $HOME_GW_LAN"
        if docker exec office-pc timeout 3 bash -c "</dev/tcp/$home_pc_ip/22" 2>/dev/null; then
            ok "5e. office-pc can reach SSH on home-pc ($home_pc_ip:22)"
        else
            bad "5e. office-pc can reach SSH on home-pc ($home_pc_ip:22)"
        fi
    fi
fi

echo
echo "$pass passed, $fail failed"
exit "$fail"
