Here is the updated `README.md` reflecting the latest features: **Client Management (Roaming)**, **SSH Hardening**, and
**Direct Output** (no files/QR codes).

***

# WireGuard Mesh & Client Manager

A production-ready Bash script to manage a **Secure Full Mesh VPN**.

It handles two types of connections:

1. **Mesh Servers:** Permanent nodes (Servers/VMs) that connect directly to every other node (Peer-to-Peer).
2. **Roaming Clients:** Laptops or Phones that connect to the mesh to access internal services securely.

### 🗺 Topology

* **Servers:** Full Mesh. If the Manager goes down, servers keep talking.
* **Clients:** Connect to the Manager (and can access the whole mesh via routing).
* **Security:** The Manager acts as an **SSH Bastion**. Worker nodes block public SSH access and only allow connections
  from the Manager or via the VPN.

---

## 🚀 Quick Start

### 1. Prerequisites

* **Manager Node:** Needs a **Static Public IP** and `root` access.
* **Worker Nodes:** Need Public IPs and `root` access.
* **SSH:** The Manager needs passwordless SSH access to Workers (`ssh-copy-id`).

### 2. Installation

Save the script as `wg-mesh.sh` on your **Manager** server:

```bash
chmod +x wg-mesh.sh
```

### 3. Initialize Manager

Sets up the Interface, Database, and Firewall.

```bash
sudo ./wg-mesh.sh init
```

---

## 🖥 Server Management (Mesh)

Add servers to create a persistent, self-healing cluster.

| Command         | Usage                                 | Description                                                       |
|:----------------|:--------------------------------------|:------------------------------------------------------------------|
| **Add Node**    | `./wg-mesh.sh add <user@host> <name>` | Installs WG, hardens Firewall, and meshes with all peers.         |
| **List Status** | `./wg-mesh.sh ls`                     | Real-time dashboard of all Servers and Clients.                   |
| **Update OS**   | `./wg-mesh.sh upgrade all`            | **Rolling Update.** Updates OS/Kernel on nodes one-by-one safely. |
| **Remove**      | `./wg-mesh.sh remove <name>`          | Deletes node and updates all peers to drop connections.           |
| **Sync**        | `./wg-mesh.sh sync`                   | Force-pushes configuration to all nodes (Fixes drift).            |

**Example:**

```bash
sudo ./wg-mesh.sh add root@192.168.1.50 db-server
```

---

## 💻 Client Management (Laptops/Phones)

Add roaming devices. These configurations are printed directly to the terminal for you to copy-paste into your WireGuard
Client.

| Command        | Usage                            | Description                                        |
|:---------------|:---------------------------------|:---------------------------------------------------|
| **Add Client** | `./wg-mesh.sh add-client <name>` | Creates keys, updates mesh, and prints Config.     |
| **Export**     | `./wg-mesh.sh export <name>`     | Re-prints the config block for an existing client. |
| **Remove**     | `./wg-mesh.sh remove <name>`     | Revokes access immediately across the entire mesh. |

**Example:**

```bash
sudo ./wg-mesh.sh add-client my-macbook
```

*Output will be a text block starting with `[Interface]`. Copy this into your WireGuard app.*

---

## 🛡 Security & Firewall Model

The script **automatically configures** `ufw` on every server you add.

### 1. Worker Nodes (Hardened)

* **Public SSH (Port 22):** **BLOCKED** from the internet.
    * *Exception:* Allowed ONLY from the **Manager's IP**.
* **VPN SSH:** Allowed from anywhere inside the VPN (`10.10.0.x`).
* **Public Ports:** 80, 443, 51820 (WG).
* **Internal Trust:** **ALL** traffic is allowed on the `wg0` interface.

### 2. Manager Node (Bastion)

* **Public SSH:** **OPEN**. You must SSH here first to access other nodes if the VPN is down.

### ⚠️ Important: Manager IP

If your Manager's IP changes, you will lose public SSH access to workers.
**Recovery:** SSH into the Manager, then SSH into the worker via its **VPN IP** (`10.10.0.x`) and update the firewall
rule manually.

---

## 📂 Data & State

* **Database:** `/etc/wireguard/mesh.db` (SQLite) - The Single Source of Truth.
* **Configs:** `/etc/wireguard/wg0.conf` - Generated automatically. **Do not edit manually**, use `sync`.