#!/usr/bin/env bash
# ==============================================================================
# Bare-Metal Linux Edge Router Provisioner
# Author: Abdalrahman Bashir "Naksh"
#
# Features:
#   - Ethernet interface discovery or explicit interface argument
#   - 802.1Q VLAN trunking
#   - Authoritative DHCP and caching DNS through dnsmasq
#   - Stateful IPv4 firewall and NAT
#   - TCP MSS clamping
#
# Topology:
#   VLAN 2  : WAN, DHCP
#   VLAN 10 : LAN, 10.10.0.1/24
#   VLAN 30 : K8s, 10.30.0.1/24
#
# DNS:
#   Clients -> dnsmasq -> 1.1.1.1 / 1.0.0.1
#   Upstream DNS is unencrypted.
#
# Usage:
#   sudo ./router-setup.sh enp1s0
#   sudo ./router-setup.sh
#
# WARNING:
#   Run from a local console.
#   This replaces network profiles, DNS configuration, and IPv4 firewall rules.
#   IPv6 policy is not configured by this script.
#   Changes are not transactional and have no automatic rollback.
# ==============================================================================

set -euo pipefail
umask 022

trap 'echo "[-] Failed at line ${LINENO}. Configuration may be partially applied; no automatic rollback was performed." >&2' ERR

if [[ ${EUID} -ne 0 ]]; then
    echo "[-] Error: Run as root." >&2
    exit 1
fi

for cmd in ip nmcli dnf systemctl; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "[-] Missing required command: ${cmd}" >&2
        exit 1
    fi
done

# ==============================================================================
# Configuration
# ==============================================================================

WAN_VLAN="2"
LAN_VLAN="10"
K8S_VLAN="30"

LAN_ADDRESS="10.10.0.1/24"
LAN_GATEWAY="10.10.0.1"
LAN_DHCP_START="10.10.0.50"
LAN_DHCP_END="10.10.0.200"

K8S_ADDRESS="10.30.0.1/24"
K8S_GATEWAY="10.30.0.1"
K8S_DHCP_START="10.30.0.50"
K8S_DHCP_END="10.30.0.200"

UPSTREAM_DNS_1="1.1.1.1"
UPSTREAM_DNS_2="1.0.0.1"

# ==============================================================================
# 1. Select Ethernet interface
# ==============================================================================

echo "=== [1/8] Selecting Ethernet Device ==="

PHYS_IFACE="${1:-}"

if [[ -z "${PHYS_IFACE}" ]]; then
    PHYS_IFACE=$(
        ip -o link show |
            awk -F': ' '{print $2}' |
            grep -E '^(en|eth)' |
            grep -v '\.' |
            head -n 1 || true
    )
fi

if [[ -z "${PHYS_IFACE}" ]]; then
    read -rp "[-] Enter the Ethernet trunk interface name: " PHYS_IFACE
fi

if [[ -z "${PHYS_IFACE}" ]] ||
   ! ip link show dev "${PHYS_IFACE}" >/dev/null 2>&1; then
    echo "[-] Invalid interface: ${PHYS_IFACE}" >&2
    exit 1
fi

WAN_IF="${PHYS_IFACE}.${WAN_VLAN}"
LAN_IF="${PHYS_IFACE}.${LAN_VLAN}"
K8S_IF="${PHYS_IFACE}.${K8S_VLAN}"

echo "[+] Physical trunk: ${PHYS_IFACE}"
echo "[+] WAN interface : ${WAN_IF}"
echo "[+] LAN interface : ${LAN_IF}"
echo "[+] K8s interface : ${K8S_IF}"

read -rp "[!] This will replace router configuration. Type YES to continue: " CONFIRM

if [[ "${CONFIRM}" != "YES" ]]; then
    echo "[-] Cancelled."
    exit 0
fi

# ==============================================================================
# 2. Install packages
# ==============================================================================

echo "=== [2/8] Installing Core Packages ==="

dnf install -y epel-release

dnf install -y \
    iptables-services \
    dnsmasq \
    bind-utils \
    tcpdump

# ==============================================================================
# 3. Back up configuration and prepare forwarding
# ==============================================================================

echo "=== [3/8] Backing Up Configuration ==="

BACKUP_DIR="/root/router-backup-$(date +%Y%m%d-%H%M%S)-$$"
install -d -m 0700 "${BACKUP_DIR}"

for path in \
    /etc/dnsmasq.conf \
    /etc/sysctl.d/99-router-net.conf \
    /etc/NetworkManager/system-connections \
    /etc/systemd/system/dnsmasq.service.d \
    /etc/sysconfig/iptables; do

    if [[ -e "${path}" ]]; then
        cp -a --parents "${path}" "${BACKUP_DIR}/"
    fi
done

iptables-save > "${BACKUP_DIR}/iptables-before.rules"
ip address show > "${BACKUP_DIR}/addresses-before.txt"
ip route show table all > "${BACKUP_DIR}/routes-before.txt"
nmcli connection show > "${BACKUP_DIR}/connections-before.txt"

echo "[+] Backup directory: ${BACKUP_DIR}"

cat > /etc/sysctl.d/99-router-net.conf <<'EOF'
# Enable IPv4 routing.
net.ipv4.ip_forward = 1
EOF

# ==============================================================================
# 4. Prepare parent trunk
# ==============================================================================

echo "=== [4/8] Preparing Parent Trunk ==="

systemctl stop firewalld 2>/dev/null || true
systemctl disable firewalld 2>/dev/null || true
systemctl mask firewalld 2>/dev/null || true

systemctl reload NetworkManager

# Create a strict L2-only profile for the parent. 
# ipv4.method disabled prevents it from getting an IP and causing a metric collision.
nmcli connection delete "trunk-${PHYS_IFACE}" 2>/dev/null || true
nmcli connection add type ethernet \
    con-name "trunk-${PHYS_IFACE}" \
    ifname "${PHYS_IFACE}" \
    ipv4.method disabled \
    ipv6.method disabled \
    connection.autoconnect yes \
    connection.autoconnect-priority 20

nmcli connection up "trunk-${PHYS_IFACE}"


# ==============================================================================
# 5. Configure VLAN interfaces
# ==============================================================================

echo "=== [5/8] Provisioning VLAN Interfaces ==="

for con in "vlan${WAN_VLAN}" "vlan${LAN_VLAN}" "vlan${K8S_VLAN}"; do
    nmcli connection delete "${con}" 2>/dev/null || true
done

nmcli connection add type vlan \
    con-name "vlan${WAN_VLAN}" \
    ifname "${WAN_IF}" \
    dev "${PHYS_IFACE}" \
    id "${WAN_VLAN}" \
    connection.autoconnect yes \
    connection.autoconnect-priority 10 \
    ipv4.method auto \
    ipv4.route-metric 50

nmcli connection add type vlan \
    con-name "vlan${LAN_VLAN}" \
    ifname "${LAN_IF}" \
    dev "${PHYS_IFACE}" \
    id "${LAN_VLAN}" \
    connection.autoconnect yes \
    connection.autoconnect-priority 10 \
    ipv4.method manual \
    ipv4.addresses "${LAN_ADDRESS}" \
    ipv4.never-default yes

nmcli connection add type vlan \
    con-name "vlan${K8S_VLAN}" \
    ifname "${K8S_IF}" \
    dev "${PHYS_IFACE}" \
    id "${K8S_VLAN}" \
    connection.autoconnect yes \
    connection.autoconnect-priority 10 \
    ipv4.method manual \
    ipv4.addresses "${K8S_ADDRESS}" \
    ipv4.never-default yes

nmcli connection up "vlan${WAN_VLAN}"
nmcli connection up "vlan${LAN_VLAN}"
nmcli connection up "vlan${K8S_VLAN}"

# ==============================================================================
# 6. Configure dnsmasq
# ==============================================================================

echo "=== [6/8] Configuring DHCP & Caching DNS ==="

cat > /etc/dnsmasq.conf <<EOF
domain-needed
bogus-priv
no-resolv
dhcp-authoritative

# Direct upstream DNS forwarding; unencrypted.
server=${UPSTREAM_DNS_1}
server=${UPSTREAM_DNS_2}

# Listen locally and on internal VLANs only.
interface=lo
interface=${LAN_IF}
interface=${K8S_IF}
bind-interfaces

# DHCP scopes.
dhcp-range=set:lan,${LAN_DHCP_START},${LAN_DHCP_END},255.255.255.0,12h
dhcp-range=set:k8s,${K8S_DHCP_START},${K8S_DHCP_END},255.255.255.0,12h

# Advertise only the router as DNS.
dhcp-option=tag:lan,option:router,${LAN_GATEWAY}
dhcp-option=tag:lan,option:dns-server,${LAN_GATEWAY}

dhcp-option=tag:k8s,option:router,${K8S_GATEWAY}
dhcp-option=tag:k8s,option:dns-server,${K8S_GATEWAY}
EOF

if command -v restorecon >/dev/null 2>&1; then
    restorecon -v /etc/dnsmasq.conf
fi

dnsmasq --test

systemctl enable dnsmasq
systemctl restart dnsmasq

# ==============================================================================
# 7. Configure IPv4 firewall and NAT
# ==============================================================================

echo "=== [7/8] Configuring Stateful IPv4 Firewall & NAT ==="

# Restrictive policies before clearing existing rules.
# These operations are not transactional.
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F

# Router input.
iptables -A INPUT -i lo -j ACCEPT

iptables -A INPUT \
    -m conntrack --ctstate RELATED,ESTABLISHED \
    -j ACCEPT

iptables -A INPUT -p icmp -j ACCEPT

# SSH from LAN only.
iptables -A INPUT \
    -i "${LAN_IF}" \
    -p tcp --dport 22 \
    -j ACCEPT

# DNS and DHCP on internal VLANs.
for iface in "${LAN_IF}" "${K8S_IF}"; do
    iptables -A INPUT \
        -i "${iface}" \
        -p udp -m multiport --dports 53,67,68 \
        -j ACCEPT

    iptables -A INPUT \
        -i "${iface}" \
        -p tcp --dport 53 \
        -j ACCEPT
done

# Forwarded traffic.
iptables -A FORWARD \
    -m conntrack --ctstate RELATED,ESTABLISHED \
    -j ACCEPT

iptables -A FORWARD \
    -i "${LAN_IF}" -o "${WAN_IF}" \
    -j ACCEPT

iptables -A FORWARD \
    -i "${K8S_IF}" -o "${WAN_IF}" \
    -j ACCEPT

# LAN may initiate connections to K8s.
iptables -A FORWARD \
    -i "${LAN_IF}" -o "${K8S_IF}" \
    -j ACCEPT

# K8s may not initiate connections to LAN.
iptables -A FORWARD \
    -i "${K8S_IF}" -o "${LAN_IF}" \
    -j DROP

# TCP MSS clamping on WAN egress.
iptables -t mangle -A POSTROUTING \
    -p tcp --tcp-flags SYN,RST SYN \
    -o "${WAN_IF}" \
    -j TCPMSS --clamp-mss-to-pmtu

# IPv4 masquerading.
iptables -t nat -A POSTROUTING \
    -o "${WAN_IF}" \
    -j MASQUERADE

iptables-save > /etc/sysconfig/iptables

systemctl enable iptables
systemctl restart iptables

sysctl -p /etc/sysctl.d/99-router-net.conf

# ==============================================================================
# 8. Test DNS resolution
# ==============================================================================

echo "=== [8/8] Testing DNS Resolution ==="

test_dns() {
    local server="$1"
    local attempt
    local answer

    for attempt in 1 2 3; do
        if answer=$(
            dig @"${server}" example.com A \
                +time=5 +tries=1 +short
        ); then
            if grep -Eq \
                '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' <<< "${answer}"; then
                return 0
            fi
        fi

        sleep 2
    done

    return 1
}

if ! test_dns 127.0.0.1; then
    echo "[-] dnsmasq resolution test failed." >&2
    echo "[-] Check WAN connectivity and upstream DNS access." >&2
    journalctl -u dnsmasq -n 30 --no-pager
    exit 1
fi

echo "=========================================================="
echo "[+] Router deployment completed."
echo "[+] Physical trunk : ${PHYS_IFACE}"
echo "[+] WAN            : ${WAN_IF}"
echo "[+] LAN            : ${LAN_IF} — ${LAN_ADDRESS}"
echo "[+] K8s            : ${K8S_IF} — ${K8S_ADDRESS}"
echo "[+] DNS            : dnsmasq -> public DNS, unencrypted"
echo "[+] Upstream DNS   : ${UPSTREAM_DNS_1}, ${UPSTREAM_DNS_2}"
echo "[+] DNS test       : passed"
echo "[+] Backup         : ${BACKUP_DIR}"
echo "=========================================================="