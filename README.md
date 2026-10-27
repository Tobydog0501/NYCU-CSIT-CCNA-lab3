# CCNA Lab: NAT & VPN with VyOS

A Docker Compose lab with two sites. Each site has a VyOS router and a Debian PC behind it. Students configure **home-gw** from scratch for NAT and DHCP, then set up a **WireGuard point-to-site VPN** so that **office-pc** can SSH into **home-pc**. **office-gw** comes already configured, as a working example to compare against.

## Topology

```
                         Docker host = "ISP"
                     192.168.1.254 (DHCP + NAT)
                                │
                  transit 192.168.1.0/24 (br-transit)
              ┌─────────────────┴─────────────────┐
         eth0 │ DHCP                         DHCP │ eth0
         ┌────┴────┐                         ┌────┴─────┐
         │ home-gw │  (you configure this)   │ office-gw│  (example config)
         └────┬────┘                         └────┬─────┘
         eth1 │ .254                         .254 │ eth1
  home-lan 172.20.21.0/24              office-lan 172.20.22.0/24
              │                                   │
         eth0 │                              eth0 │ DHCP from office-gw
         ┌────┴────┐                         ┌────┴─────┐
         │ home-pc │                         │ office-pc│  (WireGuard client)
         └─────────┘                         └──────────┘
```

| Network | Subnet | Gateway | Notes |
|---|---|---|---|
| transit | 192.168.1.0/24 | 192.168.1.254 (Docker host) | The host's DHCP server hands out .100–.200 and NATs this subnet to the internet |
| home-lan | 172.20.21.0/24 | 172.20.21.254 (home-gw eth1) | Nothing is configured to start with |
| office-lan | 172.20.22.0/24 | 172.20.22.254 (office-gw eth1) | office-gw runs DHCP for .100–.200 |

On both routers, **eth0 = transit (WAN)** and **eth1 = LAN**.

### Internet access

- The host only NATs traffic coming from `192.168.1.0/24`. Packets from a LAN that reach the transit network without being NATed are dropped.
- So a LAN can reach the internet only if its router does source NAT. office-gw already does, so office-pc is online from the start.
- home-gw and home-pc are offline until you configure home-gw.
- The two LANs can't reach each other directly. Only routed traffic and VPN traffic gets through.

## Requirements

- Debian/Ubuntu-based Linux host with **Docker Engine 28.1+ and Docker Compose 2.36+**. `make up` checks this for you.
- `sudo`. It's used to build the VyOS image, to run the transit DHCP server, and to add one firewall rule.
- Packages: `squashfs-tools`, `7zip` or `libarchive-tools`, and `dnsmasq-base`

```bash
sudo apt install squashfs-tools 7zip dnsmasq-base
```

If your Docker is too old (distro packages usually are), upgrade it to Docker's official packages:

```bash
make install-docker      # runs: sudo sh ./scripts/install-docker.sh
```

The script removes the distro's Docker packages (`docker.io` etc.) and installs `docker-ce` and `docker-compose-plugin` from download.docker.com. Your existing images, containers and volumes are kept. It also adds you to the `docker` group, so log out and back in afterwards if `docker` then asks for permissions.

## Quick start

```bash
make up          # first run downloads the VyOS ISO and builds the image (takes a few minutes)
make ps          # all 4 containers should be running
make home-gw     # open a shell on a container (see below)
make down        # stop the lab (saved configs are kept)
```

VyOS needs about 30–60 seconds to boot after `make up`. You can log in before then, but configuration commands won't work until it has finished.

### Shells

| Command | Container | Shell |
|---|---|---|
| `make home-gw` | home-gw | VyOS CLI as `vyos` (use `configure`, `show …`) |
| `make office-gw` | office-gw | VyOS CLI as `vyos` |
| `make home-pc` | home-pc | root bash |
| `make office-pc` | office-pc | root bash |

### Accounts

| Where | User | Password |
|---|---|---|
| VyOS routers | `vyos` | `vyos` |
| home-pc / office-pc (SSH) | `ccna` | `ccna` |

## What's preconfigured

| Container | At start | What persists |
|---|---|---|
| **home-gw** | Empty VyOS config. Only the hostname is set. | Anything you `save` |
| **office-gw** | Example config: eth0 = DHCP, eth1 = 172.20.22.254/24, DHCP server for office-lan, source NAT out eth0 | Anything you `save` |
| **home-pc** | No IP. sshd is running. | Nothing. It's reset whenever the container is recreated. |
| **office-pc** | Gets its IP by DHCP from office-gw. WireGuard tools are installed. | `/etc/wireguard` |

To see the example config, run `show configuration commands` on office-gw, or read [`vyos/office-gw/config.boot`](vyos/office-gw/config.boot).

## Tasks

1. **WAN:** give home-gw a transit address by DHCP on eth0, then check that home-gw can `ping 1.1.1.1`.
2. **LAN + DHCP:** give home-gw eth1 the address `172.20.21.254/24` and run a DHCP server for home-lan. On home-pc, get a lease with `dhclient -v eth0`.
3. **NAT:** configure source NAT on home-gw so that home-pc can `ping 1.1.1.1`.
4. **VPN:** set up a WireGuard server on home-gw and a client on office-pc in `/etc/wireguard/wg0.conf`. Bring the tunnel up with `wg-quick up wg0`.
5. **Verify:** from office-pc, run `ssh ccna@<home-pc IP>` through the tunnel.

Remember to `save` on the VyOS routers, or your config is lost when the container restarts.

## Resetting

| Command | Effect |
|---|---|
| `make wipe-home-gw` | Resets home-gw to an empty config |
| `make wipe-office-gw` | Resets office-gw to the example config |
| `make wipe-office-pc` | Deletes office-pc's WireGuard config |
| `make wipe` | Runs all three of the above |
| `make restart` | `down` + `up`. Saved configs are kept and home-pc is reset. |
| `make clean` | `down`, then deletes `build/` (the ISO and build files). Saved configs are kept. |
| `make distclean` | `clean`, then deletes all saved configs and the `vyos:rolling` image |

## Useful commands

**VyOS**
```
show interfaces
show ip route
show nat source rules
show nat source statistics
show dhcp server leases
show interfaces wireguard wg0
show configuration commands
generate pki wireguard key-pair     # in configure mode: run generate ...
```

**Debian PCs**
```
ip -br a; ip route
dhclient -v eth0                    # get a lease
dhclient -r eth0 && dhclient -v eth0   # renew
ip addr flush dev eth0              # remove all addresses
wg genkey | tee privatekey | wg pubkey > publickey
wg show                             # handshake, transfer, endpoint
wg-quick up wg0 / wg-quick down wg0
tcpdump -ni eth0
traceroute 1.1.1.1
```

## Troubleshooting

- **`ping 1.1.1.1` says "Network is unreachable".** The device has no default route. Check `show ip route` on the router or `ip route` on the PC.
- **home-gw is online but home-pc isn't.** Either source NAT is missing, or home-pc has no default route via `.254`.
- **Two default routes on home-gw, or the internet only works some of the time.** Only eth0 (the WAN) should use `address dhcp`. If eth1 also uses DHCP, home-gw takes a lease from its own DHCP server and adds a default route pointing at itself.
- **WireGuard shows `0 B received` and no handshake.** Usually the public keys don't match. The peer's `public-key` on home-gw must equal the output of `wg show wg0 public-key` on office-pc, and the reverse. Also check that the `Endpoint` is home-gw's current transit IP.
- **Domain names resolve but there are no replies.** Docker's built-in DNS (`127.0.0.11`) answers name lookups even when there's no route, so test reachability with IP addresses.
- **`sudo: unable to resolve host …` on a router.** The VyOS `host-name` doesn't match the container name. The warning is harmless, but don't change `system host-name`.
- **office-pc has no IP.** Run `dhclient -v eth0`. office-gw may still have been booting when office-pc started.
- **The tunnel is down after a restart.** office-pc keeps `wg0.conf` but doesn't bring the tunnel up by itself. Run `wg-quick up wg0`.
- **home-gw's transit IP changed.** Its address comes from the host's DHCP server, so after a restart it may get a different lease. Update the `Endpoint` in `wg0.conf`.

## How it works

- **VyOS image:** VyOS has no official Docker image. `make up` downloads the latest rolling ISO from [vyos-nightly-build](https://github.com/vyos/vyos-nightly-build/releases), extracts its root filesystem and imports it as `vyos:rolling`. To use a specific version, run `make up ISO_URL=<url>`.
- **Router boot:** `vyos/preconfig-bootup.script` runs before VyOS loads its config. It does three things:
  - turns IPv6 back on per interface (Docker disables it, and VyOS needs it to commit any interface config)
  - removes the IPv4 addresses Docker assigned, so VyOS controls all addressing
  - when a config volume is brand new, copies in office-gw's example config, or sets home-gw's hostname
- **Persistence:** router configs and office-pc's `/etc/wireguard` live in Docker named volumes (`ccna-lab_*`).
- **Transit "ISP":** `make up` starts `dnsmasq` on the host for DHCP only (no DNS) and adds one `DOCKER-USER` iptables rule that drops un-NATed LAN traffic. `make down` removes both. The LAN bridges have no IP on the host side.

## Files

```
Makefile                      build, start/stop, shells, reset
scripts/install-docker.sh     install/upgrade Docker Engine + Compose
docker-compose.yml            networks, containers, volumes
debian/Dockerfile             PC image (net tools, WireGuard, SSH, ccna user)
vyos/preconfig-bootup.script  router boot fixups and config seeding
vyos/office-gw/config.boot    office-gw example config
```
