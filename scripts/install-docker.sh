#!/bin/sh
# Install/upgrade Docker Engine + Compose plugin from Docker's official apt repo
# (the lab needs Engine 28.1+ and Compose 2.36+ for `interface_name`).
# Supports Debian, Ubuntu and their derivatives. Run with sudo.
# Images, containers and volumes in /var/lib/docker are kept.
set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "run as root: sudo $0" >&2
    exit 1
fi

. /etc/os-release
case " ${ID} ${ID_LIKE:-} " in
    *" ubuntu "*) distro=ubuntu; codename=${UBUNTU_CODENAME:-$VERSION_CODENAME} ;;
    *" debian "*) distro=debian; codename=$VERSION_CODENAME ;;
    *) echo "unsupported distro: ${ID} (need Debian/Ubuntu based)" >&2; exit 1 ;;
esac
echo "Installing Docker for ${distro} ${codename}"

# Distro packages conflict with Docker's own (only removes the packages, not data)
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        apt-get remove -y "$pkg"
    fi
done

apt-get update
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/${distro}/gpg" -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${distro} ${codename} stable" \
    > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

if [ -d /run/systemd/system ]; then
    systemctl enable --now docker
    systemctl restart docker
fi

# Let the invoking user run docker without sudo (takes effect on next login)
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    usermod -aG docker "$SUDO_USER"
fi

docker --version
docker compose version
