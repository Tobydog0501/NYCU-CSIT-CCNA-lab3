VYOS_IMAGE := vyos:rolling
BUILD_DIR  := build
ISO        := $(BUILD_DIR)/vyos.iso
ROOTFS     := $(BUILD_DIR)/rootfs

# Transit DHCP server, run on the Docker host's br-transit bridge (192.168.1.254)
DNSMASQ      ?= /usr/sbin/dnsmasq
TRANSIT_BR   := br-transit
TRANSIT_NET  := 192.168.1.0/24
DNSMASQ_PID  := $(BUILD_DIR)/dnsmasq.pid
DNSMASQ_ARGS := --port=0 --interface=$(TRANSIT_BR) --bind-interfaces --user=root \
	--dhcp-range=192.168.1.100,192.168.1.200,255.255.255.0,12h \
	--dhcp-option=option:router,192.168.1.254 \
	--dhcp-leasefile=$(CURDIR)/$(BUILD_DIR)/dnsmasq.leases \
	--pid-file=$(CURDIR)/$(DNSMASQ_PID) \
	--log-dhcp --log-facility=$(CURDIR)/$(BUILD_DIR)/dnsmasq.log

# Latest VyOS rolling ISO; override with `make ISO_URL=...`
ISO_URL ?= $(shell curl -fsSL https://api.github.com/repos/vyos/vyos-nightly-build/releases/latest \
	| grep -o '"browser_download_url": *"[^"]*generic-amd64\.iso"' | head -n1 | cut -d'"' -f4)

.PHONY: help up down restart ps logs iso vyos-image check-tools check-docker install-docker \
	clean distclean dhcp-up dhcp-down \
	wipe wipe-home-gw wipe-office-gw wipe-office-pc \
	home-gw office-gw home-pc office-pc

help:
	@echo "make install-docker  install/upgrade Docker Engine + Compose (needs sudo)"
	@echo "make up          build images (if needed) and start the lab"
	@echo "make down        stop and remove the lab"
	@echo "make ps|logs     status / logs"
	@echo "make dhcp-up|dhcp-down  start/stop the transit DHCP server on the host (part of up/down)"
	@echo "make home-gw     VyOS shell (vbash) on home-gw"
	@echo "make office-gw   VyOS shell (vbash) on office-gw"
	@echo "make home-pc     bash on home-pc"
	@echo "make office-pc   bash on office-pc"
	@echo "make wipe-home-gw     reset home-gw to an empty VyOS config"
	@echo "make wipe-office-gw   reset office-gw to vyos/office-gw/config.boot"
	@echo "make wipe-office-pc   delete office-pc's WireGuard config (/etc/wireguard)"
	@echo "make wipe             all three of the above"
	@echo "make clean       down + remove build/ (keeps saved configs)"
	@echo "make distclean   clean + remove saved configs and the $(VYOS_IMAGE) image"

up: check-docker vyos-image
	docker compose up -d --build
	$(MAKE) --no-print-directory dhcp-up

down: dhcp-down
	docker compose down

# --- Docker version ---------------------------------------------------------
# `interface_name` (fixed NIC order on the routers) needs Engine 28.1+ / Compose 2.36+

MIN_ENGINE  := 28.1
MIN_COMPOSE := 2.36

check-docker:
	@engine=$$(docker version --format '{{.Server.Version}}' 2>/dev/null); \
	compose=$$(docker compose version --short 2>/dev/null | sed 's/^v//'); \
	ok=1; \
	[ -n "$$engine" ] && [ "$$(printf '%s\n' $(MIN_ENGINE) "$$engine" | sort -V | head -n1)" = $(MIN_ENGINE) ] || ok=0; \
	[ -n "$$compose" ] && [ "$$(printf '%s\n' $(MIN_COMPOSE) "$$compose" | sort -V | head -n1)" = $(MIN_COMPOSE) ] || ok=0; \
	if [ $$ok = 0 ]; then \
		echo "Docker too old (engine $${engine:-none}, compose $${compose:-none});"; \
		echo "need engine $(MIN_ENGINE)+ and compose $(MIN_COMPOSE)+. Run: make install-docker"; \
		exit 1; \
	fi

install-docker:
	sudo sh ./scripts/install-docker.sh

# --- transit DHCP (host) --------------------------------------------------

dhcp-up: dhcp-down
	@test -x $(DNSMASQ) || { echo "missing dnsmasq: sudo apt install dnsmasq-base"; exit 1; }
	@mkdir -p $(BUILD_DIR)
	@# Host NAT only covers 192.168.1.0/24; drop un-NATed LAN traffic (a router without NAT)
	sudo iptables -I DOCKER-USER -i $(TRANSIT_BR) ! -s $(TRANSIT_NET) ! -o $(TRANSIT_BR) -j DROP
	sudo $(DNSMASQ) $(DNSMASQ_ARGS)
	@echo "transit DHCP running on $(TRANSIT_BR) (log: $(BUILD_DIR)/dnsmasq.log)"

dhcp-down:
	@-[ -f $(DNSMASQ_PID) ] && sudo kill $$(cat $(DNSMASQ_PID)) 2>/dev/null; sudo rm -f $(DNSMASQ_PID)
	@-while sudo iptables -D DOCKER-USER -i $(TRANSIT_BR) ! -s $(TRANSIT_NET) ! -o $(TRANSIT_BR) -j DROP 2>/dev/null; do :; done

restart: down up

ps:
	docker compose ps

logs:
	docker compose logs -f

# --- shells ---------------------------------------------------------------

home-gw office-gw:
	docker exec -it $@ su - vyos

home-pc office-pc:
	docker exec -it $@ bash

# --- VyOS image from ISO --------------------------------------------------

check-tools:
	@command -v unsquashfs >/dev/null || { echo "missing unsquashfs: sudo apt install squashfs-tools"; exit 1; }
	@command -v 7z >/dev/null || command -v bsdtar >/dev/null || { echo "missing 7z or bsdtar: sudo apt install 7zip (or libarchive-tools)"; exit 1; }

$(ISO):
	@mkdir -p $(BUILD_DIR)
	@test -n "$(ISO_URL)" || { echo "could not resolve ISO_URL; pass make ISO_URL=..."; exit 1; }
	@echo "Downloading $(ISO_URL)"
	curl -fL -o $@.part "$(ISO_URL)"
	mv $@.part $@

iso: $(ISO)

vyos-image: check-tools
	@if docker image inspect $(VYOS_IMAGE) >/dev/null 2>&1; then \
		echo "$(VYOS_IMAGE) already exists"; \
	else \
		$(MAKE) --no-print-directory $(ISO) && \
		rm -f $(BUILD_DIR)/filesystem.squashfs && \
		if command -v 7z >/dev/null; then \
			7z e -y -o$(BUILD_DIR) $(ISO) live/filesystem.squashfs >/dev/null; \
		else \
			bsdtar -xOf $(ISO) live/filesystem.squashfs > $(BUILD_DIR)/filesystem.squashfs; \
		fi && \
		sudo rm -rf $(ROOTFS) && \
		sudo unsquashfs -f -d $(ROOTFS) $(BUILD_DIR)/filesystem.squashfs && \
		sudo tar -C $(ROOTFS) -c . | docker import - $(VYOS_IMAGE) && \
		sudo rm -rf $(ROOTFS); \
	fi

# --- persistent config ----------------------------------------------------
# VyOS configs (after `save`) and office-pc's /etc/wireguard live in named
# volumes; wiping removes the volume and recreates the container.

wipe-home-gw:     VOLUME := home-gw-config
wipe-office-gw:   VOLUME := office-gw-config
wipe-office-pc:   VOLUME := office-pc-wireguard

wipe-home-gw wipe-office-gw wipe-office-pc:
	docker compose rm -sf $(@:wipe-%=%)
	-docker volume rm ccna-lab_$(VOLUME)
	@if docker compose ps -q | grep -q .; then docker compose up -d $(@:wipe-%=%); fi

wipe: wipe-home-gw wipe-office-gw wipe-office-pc

# --- cleanup --------------------------------------------------------------

clean: down
	sudo rm -rf $(BUILD_DIR)

distclean: clean
	docker compose down -v
	-docker image rm $(VYOS_IMAGE)
