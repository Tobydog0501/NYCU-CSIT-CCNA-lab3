FROM debian:trixie-slim

# Tools are installed at build time; the running lab has no internet access.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        iproute2 iputils-ping traceroute tcpdump mtr-tiny curl dnsutils \
        wireguard-tools isc-dhcp-client procps \
        openssh-server openssh-client \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/ssh/ssh_host_* \
    && useradd -m -s /bin/bash ccna \
    && echo 'ccna:ccna' | chpasswd

CMD ["sleep", "infinity"]
