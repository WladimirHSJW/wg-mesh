#!/bin/bash

# ==========================================
# CONFIGURATION
# ==========================================
# Detect IPs at runtime
MGMT_IPV4=$(curl -4 -s ifconfig.me)
MGMT_IPV6=$(curl -6 -s ifconfig.me)

DEFAULT_PORT="51820"
VPN_SUBNET="10.10.0"
WG_IFACE="wg0"
CONFIG_DIR="/etc/wireguard"
DB_FILE="$CONFIG_DIR/mesh.db"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

check_root() {
    if [ "$EUID" -ne 0 ]; then echo -e "${RED}Please run as root${NC}"; exit 1; fi
}

ensure_deps() {
    if ! command -v sqlite3 &> /dev/null; then
        echo -e "${YELLOW}Installing dependencies...${NC}"
        apt-get update && apt-get install -y wireguard sqlite3 bc ufw curl
    fi
}

# ==========================================
# DATABASE
# ==========================================
init_db() {
    if [ ! -f "$DB_FILE" ]; then
        mkdir -p $CONFIG_DIR
        sqlite3 "$DB_FILE" "CREATE TABLE peers (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            hostname TEXT NOT NULL UNIQUE,
            vpn_ip TEXT NOT NULL,
            public_key TEXT NOT NULL,
            private_key TEXT,
            endpoint_ip TEXT NOT NULL,
            listen_port INTEGER NOT NULL,
            peer_type TEXT DEFAULT 'server',
            is_manager INTEGER DEFAULT 0,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );"
    fi
}

# ==========================================
# MANAGER INIT
# ==========================================
init_manager() {
    check_root
    ensure_deps
    init_db

    EXISTS=$(sqlite3 "$DB_FILE" "SELECT count(*) FROM peers WHERE is_manager=1;")
    if [ "$EXISTS" -gt 0 ]; then echo "Manager already in DB."; return; fi

    echo -e "${GREEN}Initializing Mesh Manager...${NC}"
    echo "Detected Manager IPs - IPv4: $MGMT_IPV4 | IPv6: $MGMT_IPV6"

    umask 077
    PRIV_KEY=$(wg genkey)
    PUB_KEY=$(echo "$PRIV_KEY" | wg pubkey)

    # Firewall
    ufw allow ssh
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow ${DEFAULT_PORT}/udp
    ufw allow in on ${WG_IFACE}
    echo "y" | ufw enable

    # Prefer IPv4 for the database endpoint if available
    MGMT_ENDPOINT=${MGMT_IPV4:-$MGMT_IPV6}

    sqlite3 "$DB_FILE" "INSERT INTO peers (hostname, vpn_ip, public_key, endpoint_ip, listen_port, peer_type, is_manager)
        VALUES ('manager', '${VPN_SUBNET}.1', '${PUB_KEY}', '${MGMT_ENDPOINT}', ${DEFAULT_PORT}, 'server', 1);"

    cat > "$CONFIG_DIR/$WG_IFACE.conf" <<EOF
[Interface]
Address = ${VPN_SUBNET}.1/24
ListenPort = ${DEFAULT_PORT}
PrivateKey = ${PRIV_KEY}
SaveConfig = false
EOF

    systemctl enable wg-quick@$WG_IFACE
    systemctl start wg-quick@$WG_IFACE
    echo -e "${GREEN}Manager Initialized.${NC}"
}

# ==========================================
# ADD SERVER (Mesh Node)
# ==========================================
add_node() {
    REMOTE_USER_HOST=$1
    NODE_NAME=$2
    MANUAL_ENDPOINT=$3

    if [[ -z "$REMOTE_USER_HOST" || -z "$NODE_NAME" ]]; then
        echo "Usage: $0 add <root@host> <name> [manual_ip]"
        exit 1
    fi
    check_root; init_db

    EXISTS=$(sqlite3 "$DB_FILE" "SELECT count(*) FROM peers WHERE hostname='$NODE_NAME';")
    if [ "$EXISTS" -gt 0 ]; then echo -e "${RED}Hostname exists.${NC}"; exit 1; fi

    LAST_IP=$(sqlite3 "$DB_FILE" "SELECT MAX(id) FROM peers;")
    NODE_VPN_IP="${VPN_SUBNET}.$((LAST_IP + 1))"

    echo -e "${BLUE}Step 1/3: Installing & Securing $NODE_NAME...${NC}"

    # Build Firewall Rules
    FW_RULES=""
    if [ -n "$MGMT_IPV4" ]; then FW_RULES+="ufw allow from $MGMT_IPV4 to any port 22 proto tcp;"; fi
    if [ -n "$MGMT_IPV6" ]; then FW_RULES+="ufw allow from $MGMT_IPV6 to any port 22 proto tcp;"; fi

    # 1. INSTALLATION
    SETUP_CMD="
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq && apt-get install -y ufw wireguard curl -qq
        ufw --force reset
        ufw default deny incoming
        ufw default allow outgoing
        $FW_RULES
        ufw allow 80/tcp
        ufw allow 443/tcp
        ufw allow ${DEFAULT_PORT}/udp
        ufw allow in on ${WG_IFACE}
        echo 'y' | ufw enable
    "
    ssh -o StrictHostKeyChecking=no $REMOTE_USER_HOST "$SETUP_CMD"
    if [ $? -ne 0 ]; then echo -e "${RED}Installation failed.${NC}"; exit 1; fi

    # 2. GENERATE KEYS
    echo -e "${BLUE}Step 2/3: Generating keys...${NC}"
    DATA_CMD="
        PRIV=\$(wg genkey)
        PUB=\$(echo \"\$PRIV\" | wg pubkey)
        mkdir -p /etc/wireguard
        echo \"[Interface]\" > /etc/wireguard/wg0.conf
        echo \"PrivateKey = \$PRIV\" >> /etc/wireguard/wg0.conf
        chmod 600 /etc/wireguard/wg0.conf
        echo \"MATCH_PUB:\$PUB\"
        echo \"MATCH_IP:\$(curl -s ifconfig.me)\"
    "
    REMOTE_DATA=$(ssh -o StrictHostKeyChecking=no $REMOTE_USER_HOST "$DATA_CMD")

    # IPv6 Safe Parsing
    PUB=$(echo "$REMOTE_DATA" | grep "MATCH_PUB:" | sed 's/^MATCH_PUB://' | tr -d '\r')
    DETECTED_IP=$(echo "$REMOTE_DATA" | grep "MATCH_IP:" | sed 's/^MATCH_IP://' | tr -d '\r')
    ENDPOINT=${MANUAL_ENDPOINT:-$DETECTED_IP}

    if [[ -z "$PUB" ]]; then
        echo -e "${RED}Failed to extract keys. Raw output below:${NC}"
        echo "$REMOTE_DATA"
        exit 1
    fi

    sqlite3 "$DB_FILE" "INSERT INTO peers (hostname, vpn_ip, public_key, endpoint_ip, listen_port, peer_type, is_manager)
        VALUES ('$NODE_NAME', '$NODE_VPN_IP', '$PUB', '$ENDPOINT', ${DEFAULT_PORT}, 'server', 0);"

    echo -e "${BLUE}Step 3/3: Syncing Mesh...${NC}"
    sync_mesh
}

# ==========================================
# ADD CLIENT
# ==========================================
add_client() {
    CLIENT_NAME=$1
    if [[ -z "$CLIENT_NAME" ]]; then echo "Usage: $0 add-client <name>"; exit 1; fi
    check_root; init_db

    EXISTS=$(sqlite3 "$DB_FILE" "SELECT count(*) FROM peers WHERE hostname='$CLIENT_NAME';")
    if [ "$EXISTS" -gt 0 ]; then echo -e "${RED}Name exists.${NC}"; exit 1; fi

    LAST_IP=$(sqlite3 "$DB_FILE" "SELECT MAX(id) FROM peers;")
    CLIENT_IP="${VPN_SUBNET}.$((LAST_IP + 1))"

    echo -e "${BLUE}Creating Client: $CLIENT_NAME ($CLIENT_IP)...${NC}"

    PRIV_KEY=$(wg genkey)
    PUB_KEY=$(echo "$PRIV_KEY" | wg pubkey)

    sqlite3 "$DB_FILE" "INSERT INTO peers (hostname, vpn_ip, public_key, private_key, endpoint_ip, listen_port, peer_type, is_manager)
        VALUES ('$CLIENT_NAME', '$CLIENT_IP', '$PUB_KEY', '$PRIV_KEY', 'dynamic', 0, 'client', 0);"

    sync_mesh > /dev/null 2>&1
    export_client "$CLIENT_NAME"
}

export_client() {
    CLIENT_NAME=$1
    if [[ -z "$CLIENT_NAME" ]]; then echo "Usage: $0 export <name>"; exit 1; fi

    DATA=$(sqlite3 -separator "|" "$DB_FILE" "SELECT private_key, vpn_ip FROM peers WHERE hostname='$CLIENT_NAME'")
    if [[ -z "$DATA" ]]; then echo "Client '$CLIENT_NAME' not found."; exit 1; fi

    IFS='|' read -r PRIV IP <<< "$DATA"

    # Get Public Key and Port from DB
    MGR_DATA=$(sqlite3 -separator "|" "$DB_FILE" "SELECT public_key, listen_port FROM peers WHERE is_manager=1")
    IFS='|' read -r M_PUB M_PORT <<< "$MGR_DATA"

    # FORCE IPV4 DETECTION FOR CLIENT EXPORT
    # Even if DB has IPv6, clients prefer IPv4 for compatibility
    CURRENT_V4=$(curl -4 -s ifconfig.me)

    if [ -n "$CURRENT_V4" ]; then
        M_EP="$CURRENT_V4:$M_PORT"
    else
        # Fallback to DB endpoint (likely IPv6)
        DB_EP=$(sqlite3 "$DB_FILE" "SELECT endpoint_ip FROM peers WHERE is_manager=1")
        if [[ "$DB_EP" == *":"* ]]; then M_EP="[$DB_EP]:$M_PORT"; else M_EP="$DB_EP:$M_PORT"; fi
    fi

    echo ""
    echo -e "${GREEN}### COPY BELOW FOR WIREGUARD CLIENT ($CLIENT_NAME) ###${NC}"
    echo "---------------------------------------------------------"
    echo "[Interface]"
    echo "PrivateKey = $PRIV"
    echo "Address = $IP/32"
    echo "DNS = 1.1.1.1"
    echo ""
    echo "[Peer]"
    echo "# Manager connection"
    echo "PublicKey = $M_PUB"
    echo "Endpoint = $M_EP"
    echo "AllowedIPs = ${VPN_SUBNET}.0/24"
    echo "PersistentKeepalive = 25"
    echo "---------------------------------------------------------"
    echo ""
}

# ==========================================
# REMOVE PEER
# ==========================================
remove_peer() {
    TARGET=$1
    if [[ -z "$TARGET" ]]; then echo "Usage: $0 remove <name>"; exit 1; fi
    check_root

    PEER_DATA=$(sqlite3 -separator "|" "$DB_FILE" "SELECT peer_type, is_manager FROM peers WHERE hostname='$TARGET';")
    if [[ -z "$PEER_DATA" ]]; then echo -e "${RED}Error: Peer '$TARGET' not found.${NC}"; exit 1; fi

    IFS='|' read -r TYPE IS_MGR <<< "$PEER_DATA"
    if [ "$IS_MGR" == "1" ]; then echo -e "${RED}Error: Cannot remove the Manager node.${NC}"; exit 1; fi

    echo -e "${YELLOW}Removing $TYPE: $TARGET...${NC}"
    sqlite3 "$DB_FILE" "DELETE FROM peers WHERE hostname='$TARGET';"
    sync_mesh
    echo -e "${GREEN}Successfully removed $TARGET.${NC}"
}

# ==========================================
# SYNC MESH
# ==========================================
sync_mesh() {
    echo -e "${GREEN}Syncing Mesh...${NC}"
    SERVER_IDS=$(sqlite3 "$DB_FILE" "SELECT id FROM peers WHERE peer_type='server';")

    for ID in $SERVER_IDS; do
        IFS='|' read -r T_NAME T_VPN T_REAL T_MGR <<< $(sqlite3 -separator "|" "$DB_FILE" "SELECT hostname, vpn_ip, endpoint_ip, is_manager FROM peers WHERE id=$ID")

        PEER_BLOCKS=""
        OTHER_IDS=$(sqlite3 "$DB_FILE" "SELECT id FROM peers WHERE id != $ID;")
        for O_ID in $OTHER_IDS; do
            IFS='|' read -r O_PUB O_VPN O_REAL O_PORT O_TYPE <<< $(sqlite3 -separator "|" "$DB_FILE" "SELECT public_key, vpn_ip, endpoint_ip, listen_port, peer_type FROM peers WHERE id=$O_ID")

            if [ "$O_TYPE" == "client" ]; then
                BLOCK=$(printf "[Peer]\n# Client: Peer_%s\nPublicKey = %s\nAllowedIPs = %s/32\n" "$O_ID" "$O_PUB" "$O_VPN")
            else
                # IPv6 WRAPPING LOGIC FOR ENDPOINTS
                if [[ "$O_REAL" == *":"* ]]; then EP="[$O_REAL]:$O_PORT"; else EP="$O_REAL:$O_PORT"; fi

                BLOCK=$(printf "[Peer]\n# Server: Peer_%s\nPublicKey = %s\nEndpoint = %s\nAllowedIPs = %s/32\nPersistentKeepalive = 25\n" "$O_ID" "$O_PUB" "$EP" "$O_VPN")
            fi
            PEER_BLOCKS="${PEER_BLOCKS}${BLOCK}"
        done

        if [ "$T_NAME" == "manager" ]; then
            CUR_KEY=$(grep "PrivateKey" $CONFIG_DIR/$WG_IFACE.conf | awk '{print $3}')
            cat > "$CONFIG_DIR/$WG_IFACE.conf" <<EOF
[Interface]
Address = $T_VPN/24
ListenPort = ${DEFAULT_PORT}
PrivateKey = $CUR_KEY
SaveConfig = false
$PEER_BLOCKS
EOF
            wg syncconf $WG_IFACE <(wg-quick strip $WG_IFACE)
        else
            ssh -o StrictHostKeyChecking=no root@$T_REAL "
                CUR_KEY=\$(grep 'PrivateKey' /etc/wireguard/wg0.conf | awk '{print \$3}')
                cat > /etc/wireguard/wg0.conf <<EOF_CONF
[Interface]
Address = $T_VPN/24
ListenPort = ${DEFAULT_PORT}
PrivateKey = \$CUR_KEY
SaveConfig = false
$PEER_BLOCKS
EOF_CONF
                systemctl enable wg-quick@wg0
                if systemctl is-active --quiet wg-quick@wg0; then
                    wg syncconf wg0 <(wg-quick strip wg0)
                else
                    systemctl start wg-quick@wg0
                fi
            "
        fi
    done
    echo -e "${GREEN}Mesh Synced.${NC}"
}

# ==========================================
# UPGRADE
# ==========================================
perform_upgrade() {
    TARGET_NAME=$1; TARGET_IP=$2; IS_LOCAL=$3
    echo -e "${BLUE}>>> Upgrade: $TARGET_NAME${NC}"
    CMD="export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get upgrade -y"
    CHECK="[ -f /var/run/reboot-required ] && echo 'REBOOT_NEEDED' || echo 'NO_REBOOT'"

    if [ "$IS_LOCAL" == "1" ]; then eval "$CMD"; RES=$(eval "$CHECK"); else
        ssh -o StrictHostKeyChecking=no root@$TARGET_IP "$CMD"
        RES=$(ssh -o StrictHostKeyChecking=no root@$TARGET_IP "$CHECK")
    fi

    if [[ "$RES" == *"REBOOT_NEEDED"* ]]; then
        echo -e "${YELLOW}REBOOT REQUIRED for $TARGET_NAME${NC}"
        read -p "Reboot now? (y/n): " -n 1 -r; echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            if [ "$IS_LOCAL" == "1" ]; then reboot; else ssh -o StrictHostKeyChecking=no root@$TARGET_IP "reboot" & fi
        fi
    fi
}

upgrade_system() {
    TARGET=$1; check_root
    if [ "$TARGET" == "all" ]; then
        sqlite3 -separator "|" "$DB_FILE" "SELECT hostname, endpoint_ip, is_manager FROM peers WHERE peer_type='server'" | while read -r line; do
            IFS='|' read -r NAME REAL MGR <<< "$line"
            read -p "Upgrade '$NAME'? (y/n/q): " -n 1 -r; echo
            if [[ $REPLY =~ ^[Qq]$ ]]; then exit 0; fi
            if [[ $REPLY =~ ^[Yy]$ ]]; then perform_upgrade "$NAME" "$REAL" "$MGR"; fi
        done
    else
        RAW=$(sqlite3 -separator "|" "$DB_FILE" "SELECT hostname, endpoint_ip, is_manager FROM peers WHERE hostname='$TARGET'")
        if [[ -z "$RAW" ]]; then echo "Node not found."; exit 1; fi
        IFS='|' read -r NAME REAL MGR <<< "$RAW"
        perform_upgrade "$NAME" "$REAL" "$MGR"
    fi
}

# ==========================================
# LIST
# ==========================================
list_peers() {
    printf "${BLUE}%-15s %-15s %-15s %-10s %-10s %-10s${NC}\n" "HOSTNAME" "VPN IP" "REAL IP" "TYPE" "STATUS" "SEEN"
    echo "-----------------------------------------------------------------------------"
    DUMP=$(wg show $WG_IFACE dump)
    NOW=$(date +%s)
    # Added is_manager to selection
    sqlite3 -separator "|" "$DB_FILE" "SELECT hostname, vpn_ip, endpoint_ip, public_key, peer_type, is_manager FROM peers" | while read -r line; do
        IFS='|' read -r NAME VPN REAL PUB TYPE MGR <<< "$line"

        # Display Manager clearly
        if [ "$MGR" == "1" ]; then
            printf "%-15s %-15s %-15s %-10s %-10s %-10s\n" "$NAME" "$VPN" "$REAL" "OWNER" "ONLINE" "-"
            continue
        fi

        STATS=$(echo "$DUMP" | grep "$PUB")
        STATUS="${RED}OFFLINE${NC}"; SEEN="-"
        if [ ! -z "$STATS" ]; then
            HS=$(echo "$STATS" | awk '{print $5}')
            if [[ "$HS" =~ ^[0-9]+$ ]] && [ "$HS" -ne 0 ]; then
                if [ $((NOW - HS)) -lt 180 ]; then STATUS="${GREEN}ONLINE${NC}"; else STATUS="${YELLOW}IDLE${NC}"; fi
                SEEN=$(date -d @$HS "+%H:%M:%S")
            else
                STATUS="${RED}OFFLINE${NC}"; SEEN="Never"
            fi
        fi
        printf "%-15s %-15s %-15s %-10s %-10b %-10s\n" "$NAME" "$VPN" "$REAL" "$TYPE" "$STATUS" "$SEEN"
    done
}

case "$1" in
    init) init_manager ;;
    add) add_node "$2" "$3" "$4" ;;
    add-client) add_client "$2" ;;
    export) export_client "$2" ;;
    rm|remove|remove-client) remove_peer "$2" ;;
    upgrade) upgrade_system "$2" ;;
    sync) check_root; sync_mesh ;;
    ls) check_root; list_peers ;;
    *) echo "Usage: $0 {init|add|add-client|export|remove|upgrade|ls|sync}"; exit 1 ;;
esac