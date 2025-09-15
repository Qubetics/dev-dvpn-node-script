#!/bin/bash
#
# setup_wireguard.sh
#
# Idempotent installer/manager for a WireGuard interface `wg0`.
# - Installs packages, generates keys, writes wg0.conf, opens firewall,
#   enables forwarding, configures NAT, and manages DNS on wg link only
# - Uninstall cleans up services, rules, configs, and packages
set -e  # Exit on first error

# Configuration (defaults). Adjust WG_NETWORK/WG_PORT/DNS if needed.
WG_DIR="/etc/wireguard"
WG_CONF="$WG_DIR/wg0.conf"
WG_INTERFACE="wg0"
WG_NETWORK="10.8.0.1/24"
WG_PORT="51820"
PRIVATE_KEY=""
DNS="1.1.1.1"
UNINSTALL=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Ensure we have root privileges
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}Error: This script must be run as root${NC}" >&2
        exit 1
    fi
}

# Create keys if missing, or use provided private key
handle_keys() {
    echo -e "${YELLOW}Setting up WireGuard keys...${NC}"    
    # Create directory with secure permissions
    mkdir -p "$WG_DIR"
    chmod 700 "$WG_DIR"
    
    # Use provided private key or generate new one
    if [ -n "$PRIVATE_KEY" ]; then
        echo -e "${YELLOW}Using provided private key${NC}"
        echo "$PRIVATE_KEY" > "$WG_DIR/private.key"
        chmod 600 "$WG_DIR/private.key"
        wg pubkey < "$WG_DIR/private.key" > "$WG_DIR/public.key"
    else
        echo -e "${YELLOW}Generating new private key${NC}"
        umask 077
        wg genkey | tee "$WG_DIR/private.key" | wg pubkey > "$WG_DIR/public.key"
        chmod 600 "$WG_DIR/private.key"
    fi
    
    # Set public key permissions
    chmod 644 "$WG_DIR/public.key"
}

# Create WireGuard config with dynamic egress interface and sane PostUp/Down
create_wg_config() {
    echo -e "${YELLOW}Creating WireGuard configuration...${NC}"
    
    # Check if config already exists
    if [ -f "$WG_CONF" ]; then
        echo -e "${YELLOW}WireGuard configuration already exists, backing up to $WG_CONF.bak${NC}"
        cp "$WG_CONF" "${WG_CONF}.bak"
    fi
    
    # Get the primary network interface (egress)
    PRIMARY_IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '/ dev / {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    if [ -z "$PRIMARY_IFACE" ]; then
        PRIMARY_IFACE=$(ip route | awk '/^default/ {print $5; exit}')
    fi
    
    # Create new config
    cat > "$WG_CONF" <<EOL
[Interface]
PrivateKey = $(cat "$WG_DIR/private.key")
Address = $WG_NETWORK
ListenPort = $WG_PORT
SaveConfig = false
# Scope DNS to wg0 via systemd-resolved so we don't hijack system DNS
PostUp = resolvectl dns %i ${DNS} || true
PostDown = resolvectl revert %i || true
PostUp = iptables -I INPUT -p udp --dport 51820 -j ACCEPT || true
PostUp = iptables -I FORWARD -i wg0 -o ${PRIMARY_IFACE} -j ACCEPT || true
PostUp = iptables -I FORWARD -i ${PRIMARY_IFACE} -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT || true
PostUp = iptables -t nat -A POSTROUTING -o ${PRIMARY_IFACE} -j MASQUERADE || true
PostUp = ip6tables -I FORWARD -i wg0 -o ${PRIMARY_IFACE} -j ACCEPT || true
PostUp = ip6tables -I FORWARD -i ${PRIMARY_IFACE} -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT || true
PostUp = ip6tables -t nat -A POSTROUTING -o ${PRIMARY_IFACE} -j MASQUERADE || true
# nftables fallback
PostUp = nft list tables >/dev/null 2>&1 && nft add table ip wg-nat || true
PostUp = nft list chains ip wg-nat | grep -q POSTROUTING || nft add chain ip wg-nat POSTROUTING '{ type nat hook postrouting priority 100; }' || true
PostUp = nft add rule ip wg-nat POSTROUTING oifname "${PRIMARY_IFACE}" masquerade || true

PostDown = iptables -D INPUT -p udp --dport 51820 -j ACCEPT || true
PostDown = iptables -D FORWARD -i wg0 -o ${PRIMARY_IFACE} -j ACCEPT || true
PostDown = iptables -D FORWARD -i ${PRIMARY_IFACE} -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT || true
PostDown = iptables -t nat -D POSTROUTING -o ${PRIMARY_IFACE} -j MASQUERADE || true
PostDown = ip6tables -D FORWARD -i wg0 -o ${PRIMARY_IFACE} -j ACCEPT || true
PostDown = ip6tables -D FORWARD -i ${PRIMARY_IFACE} -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT || true
PostDown = ip6tables -t nat -D POSTROUTING -o ${PRIMARY_IFACE} -j MASQUERADE || true
PostDown = nft delete rule ip wg-nat POSTROUTING oifname "${PRIMARY_IFACE}" masquerade 2>/dev/null || true
PostDown = nft list chains ip wg-nat >/dev/null 2>&1 && nft flush chain ip wg-nat POSTROUTING 2>/dev/null || true
PostDown = nft list tables ip | grep -q wg-nat && nft delete table ip wg-nat 2>/dev/null || true
EOL

    chmod 600 "$WG_CONF"
}

# Function to display setup information
show_setup_info() {
    echo -e "\n${GREEN}WireGuard setup complete!${NC}"
    echo -e "Public key: ${YELLOW}$(cat "$WG_DIR/public.key")${NC}"
    echo -e "Interface: ${WG_INTERFACE}"
    echo -e "Network: ${WG_NETWORK}"
    echo -e "Port: ${WG_PORT}"
}

# Show current iptables rules for verification
show_iptables_status() {
    echo -e "\n${YELLOW}Current iptables (filter table):${NC}"
    sudo iptables -L -n -v || true
    echo -e "\n${YELLOW}Current iptables (nat table):${NC}"
    sudo iptables -t nat -L -n -v || true
}

# Enable and start WireGuard service
start_wg_service() {
    echo -e "\n${YELLOW}Enabling and starting WireGuard service wg-quick@${WG_INTERFACE}...${NC}"
    # If the interface already exists from a previous run, bring it down first
    if ip link show ${WG_INTERFACE} >/dev/null 2>&1; then
        echo -e "${YELLOW}${WG_INTERFACE} already exists; bringing it down first...${NC}"
        sudo wg-quick down ${WG_INTERFACE} || true
    fi
    sudo systemctl enable wg-quick@${WG_INTERFACE} || true
    if systemctl is-active --quiet wg-quick@${WG_INTERFACE}; then
        sudo systemctl restart wg-quick@${WG_INTERFACE} || true
    fi
    if ! sudo systemctl start wg-quick@${WG_INTERFACE}; then
        echo -e "${RED}Failed to start wg-quick@${WG_INTERFACE}${NC}"
        echo -e "${YELLOW}Service status:${NC}"
        sudo systemctl status wg-quick@${WG_INTERFACE} --no-pager || true
        echo -e "${YELLOW}Recent logs:${NC}"
        sudo journalctl -xeu wg-quick@${WG_INTERFACE} --no-pager | tail -n 80 || true
    fi

    # Ensure DNS is applied even if wg-quick didn't set it
    echo -e "${YELLOW}Verifying DNS for ${WG_INTERFACE}...${NC}"
    if command -v resolvectl >/dev/null 2>&1; then
        CURRENT_DNS=$(resolvectl dns ${WG_INTERFACE} 2>/dev/null | awk '{print $3}')
        if [ -z "$CURRENT_DNS" ] || ! echo "$CURRENT_DNS" | grep -q "$DNS"; then
            echo -e "${YELLOW}Setting DNS on ${WG_INTERFACE} via resolvectl to ${DNS}${NC}"
            sudo resolvectl dns ${WG_INTERFACE} ${DNS} || true
        fi
    elif command -v resolvconf >/dev/null 2>&1; then
        echo -e "${YELLOW}Setting DNS via resolvconf to ${DNS}${NC}"
        echo "nameserver ${DNS}" | sudo resolvconf -a ${WG_INTERFACE}.inet || true
    else
        echo -e "${YELLOW}No resolvectl or resolvconf found; consider installing one to manage DNS.${NC}"
    fi

    # Verify interface IP; if missing, assign the configured address
    echo -e "${YELLOW}Verifying IP address on ${WG_INTERFACE}...${NC}"
    if ! ip -4 addr show dev ${WG_INTERFACE} | grep -q "${WG_NETWORK%%/*}"; then
        echo -e "${YELLOW}Assigning IP ${WG_NETWORK} to ${WG_INTERFACE}${NC}"
        sudo ip addr add ${WG_NETWORK} dev ${WG_INTERFACE} || true
    fi

    # Ensure wg0.conf contains Address under [Interface]
    if ! grep -q "^Address\s*=\s*" "$WG_CONF"; then
        sudo sed -i "/^\[Interface\]/a Address = ${WG_NETWORK}" "$WG_CONF"
    fi
}

# Show usage information
show_usage() {
    echo "Usage: $0 [--private-key PRIVATE_KEY]"
    echo "Options:"
    echo "  --private-key PRIVATE_KEY  Use the provided WireGuard private key"
    echo "  --uninstall               Uninstall WireGuard and remove configuration"
    echo "  -h, --help                Show this help message"
    exit 1
}

enable_ip_forward() {
    echo -e "${YELLOW}Enabling IPv4 forwarding...${NC}"
    sudo sysctl -w net.ipv4.ip_forward=1
    # Persist across reboots for cloud instances
    echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-wireguard.conf >/dev/null
    sudo sysctl --system >/dev/null 2>&1 || true
}

wireguard_install(){
    sudo apt update
    sudo apt install -y wireguard wireguard-tools resolvconf
    # Open UDP port in UFW if present
    if command -v ufw >/dev/null 2>&1; then
        sudo ufw allow ${WG_PORT}/udp || true
    fi
    # Open UDP port in firewalld if present
    if command -v firewall-cmd >/dev/null 2>&1 && sudo systemctl is-active --quiet firewalld; then
        sudo firewall-cmd --add-port=${WG_PORT}/udp --permanent || true
        sudo firewall-cmd --reload || true
    fi
}
# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --private-key)
                PRIVATE_KEY="$2"
                shift 2
                ;;
            --uninstall)
                UNINSTALL=true
                shift 1
                ;;
            -h|--help)
                show_usage
                ;;
            *)
                echo -e "${RED}Error: Unknown option $1${NC}" >&2
                show_usage
                ;;
        esac
    done
}

# Uninstall WireGuard and cleanup
uninstall_wireguard() {
    echo -e "${YELLOW}Uninstalling WireGuard and cleaning up...${NC}"
    # Bring interface down if it exists (will also run PostDown rules)
    if ip link show ${WG_INTERFACE} >/dev/null 2>&1; then
        sudo wg-quick down ${WG_INTERFACE} || true
    fi

    # Revert DNS and delete link explicitly if it still exists
    if command -v resolvectl >/dev/null 2>&1; then
        sudo resolvectl revert ${WG_INTERFACE} || true
    fi
    if command -v resolvconf >/dev/null 2>&1; then
        sudo resolvconf -d ${WG_INTERFACE}.inet 2>/dev/null || true
    fi
    ip link show ${WG_INTERFACE} >/dev/null 2>&1 && sudo ip link del ${WG_INTERFACE} || true

    # Remove iptables/ip6tables rules that might persist if PostDown didn't run
    # IPv4
    sudo iptables -D INPUT -p udp --dport 51820 -j ACCEPT 2>/dev/null || true
    # Determine current primary iface for cleanup
    CLEAN_IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '/ dev / {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    [ -z "$CLEAN_IFACE" ] && CLEAN_IFACE=$(ip route | awk '/^default/ {print $5; exit}')
    sudo iptables -D FORWARD -i wg0 -o ${CLEAN_IFACE} -j ACCEPT 2>/dev/null || true
    sudo iptables -D FORWARD -i ${CLEAN_IFACE} -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    sudo iptables -t nat -D POSTROUTING -o ${CLEAN_IFACE} -j MASQUERADE 2>/dev/null || true
    # IPv6
    sudo ip6tables -D FORWARD -i wg0 -o ${CLEAN_IFACE} -j ACCEPT 2>/dev/null || true
    sudo ip6tables -D FORWARD -i ${CLEAN_IFACE} -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    sudo ip6tables -t nat -D POSTROUTING -o ${CLEAN_IFACE} -j MASQUERADE 2>/dev/null || true

    # nftables cleanup
    nft delete rule ip wg-nat POSTROUTING oifname "${CLEAN_IFACE}" masquerade 2>/dev/null || true
    nft list chains ip wg-nat >/dev/null 2>&1 && nft flush chain ip wg-nat POSTROUTING 2>/dev/null || true
    nft list tables ip | grep -q wg-nat && nft delete table ip wg-nat 2>/dev/null || true

    # Stop and disable service
    sudo systemctl stop wg-quick@${WG_INTERFACE} 2>/dev/null || true
    sudo systemctl disable wg-quick@${WG_INTERFACE} 2>/dev/null || true

    # Remove config and keys
    if [ -f "$WG_CONF" ]; then
        sudo rm -f "$WG_CONF" || true
    fi
    if [ -f "${WG_CONF}.bak" ]; then
        sudo rm -f "${WG_CONF}.bak" || true
    fi
    if [ -d "$WG_DIR" ]; then
        sudo rm -f "$WG_DIR/private.key" "$WG_DIR/public.key" 2>/dev/null || true
        # Remove directory if empty
        rmdir "$WG_DIR" 2>/dev/null || true
    fi

    # Attempt to unload kernel module
    if lsmod | grep -q '^wireguard\b'; then
        sudo modprobe -r wireguard 2>/dev/null || true
    fi

    # Purge packages (keep quiet if not installed)
    sudo apt purge -y wireguard wireguard-tools resolvconf 2>/dev/null || true
    sudo apt autoremove -y 2>/dev/null || true
    # Close firewall ports if managed
    if command -v ufw >/dev/null 2>&1; then
        sudo ufw delete allow ${WG_PORT}/udp 2>/dev/null || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && sudo systemctl is-active --quiet firewalld; then
        sudo firewall-cmd --remove-port=${WG_PORT}/udp --permanent 2>/dev/null || true
        sudo firewall-cmd --reload 2>/dev/null || true
    fi
    echo -e "${GREEN}WireGuard has been fully uninstalled and cleaned up.${NC}"
}

# Main execution
main() {
    wireguard_install
    parse_arguments "$@"
    if [ "$UNINSTALL" = true ]; then
        uninstall_wireguard
        exit 0
    fi
    check_root
    enable_ip_forward
    handle_keys
    create_wg_config
    show_setup_info
    start_wg_service
    show_iptables_status
}

main "$@"