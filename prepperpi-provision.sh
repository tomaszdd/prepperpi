#!/usr/bin/env bash
#===============================================================================
# prepperpi-provision.sh  —  one-shot setup for the prepper/grab-and-go Pi
#
# Reproduces the 2026-07-10 build (see memory: project-prepperpi).
# Target: Raspberry Pi 4/5, Raspberry Pi OS (Debian 12 Bookworm / 13 Trixie), 64-bit.
# Safe to re-run (idempotent). Run as:   sudo bash prepperpi-provision.sh
#
# For the 512GB build: after this runs, drop ZIMs in /data/zim, offline maps in
# /data/maps, list ZIM URLs in /etc/prepperpi/zim.list, and (optionally) install
# IIAB. The daily self-update timer will then keep that content fresh too.
#
# ⚠ VERIFY USB PORTS BEFORE DEPLOYING ⚠
# The 2026-07-13 board had DEAD USB-A ports (VL805 enumerates but no external
# device — SDR or USB stick — ever appears; a known-good SDR + a plain stick
# were both invisible with zero dmesg events). The SDR software here is fine;
# it was a hardware fault. Before trusting a Pi for this build, plug in a USB
# stick and confirm it enumerates (`lsusb` shows it). The preflight below warns
# if the ports look dead. Re-test the SDR after with: prepperpi-sdr-check
#===============================================================================
set -euo pipefail

#--- CONFIG (edit to taste) ----------------------------------------------------
HOSTNAME_SET="prepperpi"
TIMEZONE="Europe/London"
WIFI_COUNTRY="GB"
AP_SSID="PrepperPi"
AP_PASS="ChangeMe-2026"          # WPA2, min 8 chars — CHANGE THIS
AP_CHANNEL="7"
AP_IP="192.168.50.1"
AP_NET="192.168.50"              # /24
UPLINK_IF="eth0"                 # primary internet interface
AP_IF="wlan0"                    # hotspot interface
BT_PASS="CHANGE_ME"              # admin password: guards Bluetooth control, web panel :8090, web terminal :7681
                                  # leave as CHANGE_ME to be prompted (or auto-generated if non-interactive) at run time
# OpenAIP key is NOT set here - see ENABLE_OPENAIP block below (opt-in, supply your own OPENAIP_API_KEY env var)
#-------------------------------------------------------------------------------

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)"; exit 1; }
export DEBIAN_FRONTEND=noninteractive
log(){ echo -e "\n\033[1m### $*\033[0m"; }
warn(){ echo -e "\033[1;33m### WARN: $*\033[0m"; }

# --- admin password (guards Bluetooth control, web panel :8090, web terminal :7681) ---
# Never ship a hardcoded default here — assign one now instead of leaving a guessable
# static password baked into a version-controlled script.
if [ "$BT_PASS" = "CHANGE_ME" ]; then
  if [ -t 0 ]; then
    while :; do
      read -r -s -p "Set the admin password (guards BT control / web panel / terminal): " BT_PASS; echo
      read -r -s -p "Confirm: " BT_PASS_CONFIRM; echo
      [ -n "$BT_PASS" ] && [ "$BT_PASS" = "$BT_PASS_CONFIRM" ] && break
      warn "passwords empty or didn't match — try again"
    done
  else
    BT_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c12)
    warn "non-interactive run — generated admin password: ${BT_PASS}  (write this down now)"
  fi
fi

#--- USB-A port preflight (see header: the 2026-07-13 board's ports were dead) --
# Non-fatal. Counts external (non-root-hub, non-internal-VL805) USB devices.
usb_preflight(){
  local ext
  ext=$(lsusb 2>/dev/null | grep -ivE "root hub|2109:3431|1d6b:" | wc -l)
  if [ "$ext" -eq 0 ]; then
    warn "No external USB devices detected. If you have an SDR/stick plugged in"
    warn "and it's not showing, this Pi's USB-A ports may be faulty (dead-port"
    warn "signature). Plug in a USB stick and check 'lsusb' before deploying."
  else
    log "USB preflight: $ext external USB device(s) seen — ports look alive."
  fi
}
usb_preflight

log "1/11  identity: hostname + timezone + wifi country"
hostnamectl set-hostname "$HOSTNAME_SET"
grep -q "$HOSTNAME_SET" /etc/hosts || sed -i "s/^127.0.1.1.*/127.0.1.1\t$HOSTNAME_SET/" /etc/hosts || true
timedatectl set-timezone "$TIMEZONE"
raspi-config nonint do_wifi_country "$WIFI_COUNTRY" 2>/dev/null || true

log "2/11  full OS upgrade"
apt-get update && apt-get -y full-upgrade && apt-get -y autoremove && apt-get clean

log "3/11  base packages (rtl-sdr already supports V4 on 2.0.x; hostapd/dnsmasq/iw/nft)"
apt-get -y install rtl-sdr hostapd dnsmasq iw nftables curl ca-certificates ffmpeg parted
echo 'blacklist dvb_usb_rtl28xxu' > /etc/modprobe.d/blacklist-rtlsdr.conf

log "4/11  SDR++ (prebuilt deb matching this distro; GUI app / has --server for headless)"
CODENAME="$(. /etc/os-release; echo "${VERSION_CODENAME:-trixie}")"
ARCH="$(dpkg --print-architecture)"   # arm64
DEB="sdrpp_debian_${CODENAME}_aarch64.deb"
if ! dpkg -l sdrpp >/dev/null 2>&1; then
  if curl -fsSL -o /tmp/sdrpp.deb "https://github.com/AlexandreRouma/SDRPlusPlus/releases/latest/download/${DEB}"; then
    apt-get -y install /tmp/sdrpp.deb || echo "!! SDR++ deb dep issue — install manually"; rm -f /tmp/sdrpp.deb
  else
    echo "!! no prebuilt SDR++ for ${CODENAME}/${ARCH} — skip (rtl_test still works for V4 testing)"
  fi
fi

log "5/11  yt-dlp (standalone binary, self-updating)"
curl -fsSL -o /usr/local/bin/yt-dlp https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux_aarch64
chmod a+rx /usr/local/bin/yt-dlp

log "6/11  kiwix-serve (+ kiwix-manage) + curated ZIM manifest + service"
KURL=$(curl -fsSL https://download.kiwix.org/release/kiwix-tools/ | grep -oE 'kiwix-tools_linux-aarch64-[0-9.]+\.tar\.gz' | sort -V | tail -1)
curl -fsSL "https://download.kiwix.org/release/kiwix-tools/$KURL" | tar xz -C /tmp
cp /tmp/kiwix-tools_linux-aarch64-*/kiwix-serve /tmp/kiwix-tools_linux-aarch64-*/kiwix-manage /usr/local/bin/
chmod a+rx /usr/local/bin/kiwix-serve /usr/local/bin/kiwix-manage
rm -rf /tmp/kiwix-tools_linux-aarch64-*
mkdir -p /data/zim /data/maps /etc/prepperpi
# curated manifest: "<download.kiwix.org/zim subdir>/<basename>" (newest date auto-resolved by updater).
# Verified 2026-07. Full Wikipedia+Gutenberg+TED are big — trim for smaller cards.
[ -f /etc/prepperpi/zim.list ] || cat > /etc/prepperpi/zim.list <<'EOF'
# --- reference ---
wikipedia/wikipedia_en_all_maxi
gutenberg/gutenberg_en_all
wiktionary/wiktionary_en_all_nopic
# --- how-to / repair / sustainability ---
ifixit/ifixit_en_all
other/appropedia_en_all_maxi
# --- medical ---
other/mdwiki_en_all_maxi
other/zimgit-medicine_en
# --- survival / self-reliance (the prepper core) ---
other/zimgit-post-disaster_en
other/zimgit-water_en
other/zimgit-food-preparation_en
other/zimgit-knots_en
# --- travel / geography ---
wikivoyage/wikivoyage_en_all_maxi
# --- Q&A (survival-relevant Stack Exchange) ---
stack_exchange/outdoors.stackexchange.com_en_all
stack_exchange/gardening.stackexchange.com_en_all
stack_exchange/cooking.stackexchange.com_en_all
stack_exchange/diy.stackexchange.com_en_all
stack_exchange/ham.stackexchange.com_en_all
EOF
# kiwix-serve as a service (idles until ZIMs exist; updater restarts it after downloads)
cat > /usr/local/sbin/kiwix-start.sh <<'EOF'
#!/bin/bash
shopt -s nullglob; z=(/data/zim/*.zim)
[ ${#z[@]} -eq 0 ] && { echo "no ZIMs yet; idling"; exec sleep infinity; }
exec /usr/local/bin/kiwix-serve --port 8080 "${z[@]}"
EOF
chmod +x /usr/local/sbin/kiwix-start.sh
cat > /etc/systemd/system/kiwix-serve.service <<'EOF'
[Unit]
Description=Kiwix offline content server (:8080)
After=network.target
[Service]
ExecStart=/usr/local/sbin/kiwix-start.sh
Restart=always
[Install]
WantedBy=multi-user.target
EOF
systemctl enable kiwix-serve.service >/dev/null 2>&1

log "7/11  hostapd hotspot on ${AP_IF}  (SSID ${AP_SSID})"
cat > /etc/NetworkManager/conf.d/99-unmanage-wlan0.conf <<EOF
[keyfile]
unmanaged-devices=interface-name:${AP_IF}
EOF
cat > /etc/systemd/network/10-wlan0-ap.network <<EOF
[Match]
Name=${AP_IF}
[Network]
Address=${AP_IP}/24
ConfigureWithoutCarrier=yes
EOF
systemctl enable systemd-networkd >/dev/null 2>&1
cat > /etc/hostapd/hostapd.conf <<EOF
country_code=${WIFI_COUNTRY}
interface=${AP_IF}
driver=nl80211
ssid=${AP_SSID}
hw_mode=g
channel=${AP_CHANNEL}
ieee80211n=1
wmm_enabled=1
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${AP_PASS}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF
sed -i 's|^#*DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
systemctl unmask hostapd >/dev/null 2>&1; systemctl enable hostapd >/dev/null 2>&1

log "8/11  DHCP for hotspot clients (dnsmasq)"
cat > /etc/dnsmasq.d/prepperpi-ap.conf <<EOF
interface=${AP_IF}
bind-dynamic
dhcp-range=${AP_NET}.50,${AP_NET}.150,255.255.255.0,24h
dhcp-option=option:router,${AP_IP}
dhcp-option=option:dns-server,${AP_IP}
domain=prepperpi.lan
EOF
systemctl enable dnsmasq >/dev/null 2>&1

log "9/11  ${UPLINK_IF} primary + NAT share to ${AP_IF}"
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-prepperpi-forward.conf
sysctl -p /etc/sysctl.d/99-prepperpi-forward.conf >/dev/null
mkdir -p /etc/prepperpi
cat > /etc/prepperpi/nat.nft <<EOF
#!/usr/sbin/nft -f
table ip prepperpi_nat
delete table ip prepperpi_nat
table ip prepperpi_nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "${UPLINK_IF}" masquerade
  }
}
EOF
cat > /etc/systemd/system/prepperpi-nat.service <<EOF
[Unit]
Description=prepperpi NAT (${AP_IF}->${UPLINK_IF})
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/sbin/nft -f /etc/prepperpi/nat.nft
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl enable prepperpi-nat.service >/dev/null 2>&1

log "10/11  system info script + self-update timer"
cat > /usr/local/bin/prepperpi-info <<'SCRIPT'
#!/usr/bin/env bash
b=$(tput bold 2>/dev/null||true); r=$(tput sgr0 2>/dev/null||true)
echo "${b}=== prepperpi @ $(date '+%F %T %Z') ===${r}"
echo "${b}-- IP addresses --${r}"; ip -brief -4 addr show | awk '$1!="lo"{printf "  %-8s %s\n",$1,$3}'
echo "${b}-- Disk usage --${r}"; df -h / /boot/firmware /data 2>/dev/null | awk 'NR==1||/\//{print "  "$0}'
echo "${b}-- Connected WiFi clients --${r}"
if /usr/sbin/iw dev wlan0 info 2>/dev/null | grep -q "type AP"; then
  echo "  $(/usr/sbin/iw dev wlan0 station dump 2>/dev/null | grep -c Station) client(s):"
  for m in $(/usr/sbin/iw dev wlan0 station dump 2>/dev/null | awk '/Station/{print $2}'); do
    echo "    $m  $(grep -i "$m" /var/lib/misc/dnsmasq.leases 2>/dev/null | awk '{print $3" ("$4")"}')"
  done
else echo "  wlan0 not in AP mode"; fi
echo "${b}-- Last update --${r}"
[ -f /var/lib/prepperpi/last_update ] && echo "  job: $(cat /var/lib/prepperpi/last_update)"
echo "  apt: $(grep -h '^Start-Date' /var/log/apt/history.log 2>/dev/null | tail -1 | cut -d' ' -f2-)"
SCRIPT
chmod a+rx /usr/local/bin/prepperpi-info
# WiFi mode switch (single-radio Pi): flip wlan0 hotspot <-> client for updates when no ethernet
cat > /usr/local/bin/prepperpi-mode <<'SCRIPT'
#!/usr/bin/env bash
# prepperpi-mode ap | client <SSID> <PASS> | update [<SSID> <PASS>]   (hotspot drops in client mode)
set -e
UNMANAGE=/etc/NetworkManager/conf.d/99-unmanage-wlan0.conf
MODE="${1:-}"; SSID="${2:-}"; PASS="${3:-}"
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
case "$MODE" in
  client)
    [ -z "$SSID" ] && { . /etc/prepperpi/uplink-wifi 2>/dev/null || true; SSID="${UPLINK_SSID:-}"; PASS="${UPLINK_PASS:-}"; }
    [ -z "$SSID" ] && { echo "usage: prepperpi-mode client <SSID> <PASS>"; exit 1; }
    echo ">> CLIENT: hotspot dropping, joining '$SSID'..."
    systemctl stop hostapd dnsmasq; ip addr flush dev wlan0 || true
    rm -f "$UNMANAGE"; systemctl reload NetworkManager; sleep 2
    nmcli radio wifi on; nmcli dev set wlan0 managed yes 2>/dev/null || true
    nmcli dev wifi connect "$SSID" password "$PASS" ifname wlan0
    echo ">> $(ip -4 -brief addr show wlan0)" ;;
  ap)
    echo ">> AP: restoring hotspot..."
    nmcli dev disconnect wlan0 2>/dev/null || true
    printf '[keyfile]\nunmanaged-devices=interface-name:wlan0\n' > "$UNMANAGE"
    systemctl reload NetworkManager; sleep 2; systemctl restart systemd-networkd; sleep 2
    systemctl start hostapd dnsmasq; echo ">> $(ip -4 -brief addr show wlan0)" ;;
  update) "$0" client "$SSID" "$PASS"; sleep 3; /usr/local/sbin/prepperpi-update.sh || true; "$0" ap ;;
  *) echo "usage: prepperpi-mode {ap | client <SSID> <PASS> | update [<SSID> <PASS>]}"; exit 1;;
esac
SCRIPT
chmod +x /usr/local/bin/prepperpi-mode
[ -f /etc/prepperpi/uplink-wifi ] || printf '# UPLINK_SSID="YourWiFi"\n# UPLINK_PASS="pass"\n' > /etc/prepperpi/uplink-wifi
# --- Bluetooth wifi-control (out-of-band toggle: pair phone, send ap/client/status over BT serial) ---
apt-get -y install bluez-tools >/dev/null 2>&1 || true
[ -f /etc/prepperpi/bt.conf ] || { echo "BT_PASS=\"${BT_PASS}\"" > /etc/prepperpi/bt.conf; chmod 600 /etc/prepperpi/bt.conf; }
cat > /usr/local/bin/prepperpi-bt-server.py <<'PYEOF'
#!/usr/bin/env python3
import socket, subprocess, re
CHANNEL = 1
BANNER = b"\r\nprepperpi wifi control\r\ncmds: ap | client [SSID PASS] | update [SSID PASS] | status | quit\r\n> "
def load_pass():
    try:
        for ln in open("/etc/prepperpi/bt.conf"):
            if ln.strip().startswith("BT_PASS="): return ln.split("=",1)[1].strip().strip('"').strip("'")
    except Exception: pass
    return None
def readline(conn, buf):
    while not re.search(b"[\r\n]", buf):
        d = conn.recv(1024)
        if not d: return None, buf
        buf += d
    line, buf = re.split(b"[\r\n]", buf, 1)
    return line.decode("utf-8","ignore").strip(), buf
def run(a):
    try: r = subprocess.run(a, capture_output=True, text=True, timeout=120); return (r.stdout + r.stderr) or "(ok)\n"
    except Exception as e: return f"error: {e}\n"
def handle(conn):
    buf = b""; pw = load_pass()
    if pw:
        conn.sendall(b"\r\nprepperpi - password: ")
        for _ in range(3):
            line, buf = readline(conn, buf)
            if line is None: conn.close(); return
            if line == pw: break
            conn.sendall(b"wrong. password: ")
        else:
            conn.sendall(b"denied\r\n"); conn.close(); return
    conn.sendall(BANNER)
    while True:
        line, buf = readline(conn, buf)
        if line is None: break
        if not line: conn.sendall(b"> "); continue
        t = line.split(); op = t[0].lower()
        if op == "status": out = run(["/usr/local/bin/prepperpi-info"])
        elif op in ("ap","client","update"): out = run(["/usr/local/bin/prepperpi-mode"] + t)
        elif op in ("quit","exit"): conn.sendall(b"bye\r\n"); break
        else: out = "cmds: ap | client [SSID PASS] | update [SSID PASS] | status | quit\n"
        conn.sendall(out.replace("\n","\r\n").encode("utf-8","ignore") + b"\r\n> ")
    conn.close()
s = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM, socket.BTPROTO_RFCOMM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("00:00:00:00:00:00", CHANNEL)); s.listen(1)
print(f"prepperpi BT control on RFCOMM channel {CHANNEL}", flush=True)
while True:
    try: conn, addr = s.accept(); handle(conn)
    except Exception as e: print("err", e, flush=True)
PYEOF
chmod +x /usr/local/bin/prepperpi-bt-server.py
BTD=$(grep -m1 '^ExecStart=' /lib/systemd/system/bluetooth.service | cut -d= -f2-)
mkdir -p /etc/systemd/system/bluetooth.service.d
printf '[Service]\nExecStart=\nExecStart=%s --compat --experimental\n' "$BTD" > /etc/systemd/system/bluetooth.service.d/override.conf
sed -i 's/^#\?Name = .*/Name = prepperpi/' /etc/bluetooth/main.conf 2>/dev/null || true
sed -i 's/^#\?DiscoverableTimeout = .*/DiscoverableTimeout = 0/' /etc/bluetooth/main.conf 2>/dev/null || true
sed -i 's/^#\?PairableTimeout = .*/PairableTimeout = 0/' /etc/bluetooth/main.conf 2>/dev/null || true
grep -q '^\[Policy\]' /etc/bluetooth/main.conf || echo '[Policy]' >> /etc/bluetooth/main.conf
grep -q '^AutoEnable=true' /etc/bluetooth/main.conf || echo 'AutoEnable=true' >> /etc/bluetooth/main.conf
rfkill unblock bluetooth 2>/dev/null || true
cat > /etc/systemd/system/prepperpi-bt-agent.service <<'EOF'
[Unit]
Description=prepperpi BT auto-pair agent
After=bluetooth.service
Requires=bluetooth.service
[Service]
ExecStart=/usr/bin/bt-agent -c NoInputNoOutput
Restart=always
[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/prepperpi-bt.service <<'EOF'
[Unit]
Description=prepperpi Bluetooth wifi-control (SPP)
After=bluetooth.service prepperpi-bt-agent.service
Requires=bluetooth.service
[Service]
ExecStartPre=/bin/bash -c 'bluetoothctl power on; bluetoothctl pairable on; bluetoothctl discoverable on; sdptool add --channel=1 SP || true'
ExecStart=/usr/local/bin/prepperpi-bt-server.py
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload; systemctl restart bluetooth
systemctl enable prepperpi-bt-agent.service prepperpi-bt.service >/dev/null 2>&1
# --- web control panel (:8090, same password as BT) ---
cat > /usr/local/bin/prepperpi-web.py <<'PYEOF'
#!/usr/bin/env python3
import http.server, socketserver, subprocess, base64, urllib.parse
PORT = 8090
def load_pass():
    try:
        for ln in open("/etc/prepperpi/bt.conf"):
            if ln.strip().startswith("BT_PASS="): return ln.split("=",1)[1].strip().strip('"').strip("'")
    except Exception: pass
    return None
def cmd(a):
    try: return subprocess.run(a,capture_output=True,text=True,timeout=20).stdout
    except Exception as e: return str(e)
def info(): return cmd(["/usr/local/bin/prepperpi-info"])
def netinfo(): return cmd(["/usr/local/bin/prepperpi-netinfo"])
def content(): return cmd(["/usr/local/bin/prepperpi-content"])
def power(): return cmd(["/usr/local/bin/prepperpi-power","status"])
PAGE = """<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1"><title>prepperpi control</title><style>
body{font-family:system-ui,sans-serif;background:#0e1116;color:#e6e9ef;margin:0;padding:16px;max-width:640px;margin:auto}
h1{font-size:20px}.card{background:#171d2b;border:1px solid #28303f;border-radius:10px;padding:14px;margin:12px 0}
button{background:#f59e0b;color:#0e1116;border:0;border-radius:8px;padding:12px 16px;font-size:15px;font-weight:700;width:100%;margin:6px 0}
button.sec{background:#2b3547;color:#e6e9ef}.two{display:flex;gap:8px}.two button{width:50%}
input{width:100%;padding:10px;margin:5px 0;border-radius:8px;border:1px solid #28303f;background:#0e1116;color:#e6e9ef;box-sizing:border-box}
pre{background:#0e1116;border:1px solid #28303f;border-radius:8px;padding:10px;overflow:auto;font-size:12px;white-space:pre-wrap}label{font-size:13px;color:#98a2b3}a{color:#f59e0b}</style></head><body>
<h1>&#128225; prepperpi control</h1>
<div class=card><b>Status</b><pre>__INFO__</pre></div>
<div class=card><b>Network &amp; Internet</b><pre>__NET__</pre><form method=get><button class=sec>&#8635; Refresh</button></form></div>
<div class=card><b>Content &amp; Downloads</b><pre>__CONTENT__</pre>
<form method=post action=/action><div class=two><button name=action value=getzim>&#8595; Download library (Wikipedia&hellip;)</button>
<button class=sec name=action value=getvideos>&#127909; Download videos</button></div></form>
<div style="font-size:11px;color:#98a2b3">Downloads run in the background &amp; keep themselves refreshed nightly.</div></div>
<div class=card><b>Power mode</b><pre>__POWER__</pre>
<form method=post action=/action><div class=two><button class=sec name=action value=powerlow>&#128267; Low power</button>
<button name=action value=powerfull>&#9889; Full power</button></div></form></div>
<div class=card><b>E-ink display</b><form method=post action=/action><button class=sec name=action value=eink>&#128421; Refresh e-ink status/QR (auto every 15 min)</button></form></div>
<div class=card><b>Transmit (hotspot)</b><form method=post action=/action><button name=action value=ap>&#128246; Hotspot mode (PrepperPi)</button></form></div>
<div class=card><b>Receive (join WiFi)</b><form method=post action=/action>
<label>WiFi name (SSID)</label><input name=ssid placeholder="network name">
<label>WiFi password</label><input name=pass type=password placeholder="password">
<button name=action value=client>&#128268; Connect to WiFi</button>
<button class=sec name=action value=update>&#10515; Connect &middot; Update &middot; back to Hotspot</button></form></div>
<p style="color:#98a2b3;font-size:12px">Switching to WiFi drops this hotspot connection.</p></body></html>"""
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def auth(self):
        pw = load_pass()
        if not pw: return True
        h = self.headers.get("Authorization","")
        if h.startswith("Basic "):
            try:
                _,p = base64.b64decode(h[6:]).decode().split(":",1)
                if p == pw: return True
            except Exception: pass
        self.send_response(401); self.send_header("WWW-Authenticate",'Basic realm="prepperpi"'); self.end_headers(); return False
    def do_GET(self):
        if not self.auth(): return
        b = PAGE.replace("__INFO__",info()).replace("__NET__",netinfo()).replace("__CONTENT__",content()).replace("__POWER__",power()).encode()
        self.send_response(200); self.send_header("Content-Type","text/html"); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        if not self.auth(): return
        n = int(self.headers.get("Content-Length",0)); f = urllib.parse.parse_qs(self.rfile.read(n).decode())
        a = f.get("action",[""])[0]; ssid = f.get("ssid",[""])[0]; pw = f.get("pass",[""])[0]
        if a in ("ap","client","update"):
            subprocess.Popen(["/usr/local/bin/prepperpi-mode",a]+([ssid,pw] if a in("client","update") and ssid else []),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); msg=f"started: {a} {ssid}".strip()
        elif a=="getzim":
            subprocess.Popen(["systemctl","start","--no-block","prepperpi-update.service"]); msg="library download started (background)"
        elif a=="getvideos":
            subprocess.Popen(["/usr/local/bin/prepperpi-getvideos"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); msg="video download started (background)"
        elif a=="eink":
            subprocess.Popen(["systemctl","start","--no-block","prepperpi-eink.service"]); msg="e-ink display refreshing"
        elif a in ("powerlow","powerfull"):
            subprocess.run(["/usr/local/bin/prepperpi-power","low" if a=="powerlow" else "full"],timeout=30); msg=f"power: {a[5:]}"
        else: msg="unknown action"
        h=f"<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><body style='font-family:system-ui;background:#0e1116;color:#e6e9ef;padding:16px'><p>&#9989; {msg}</p><a style='color:#f59e0b' href='/'>&larr; back</a></body>"
        self.send_response(200); self.send_header("Content-Type","text/html"); self.end_headers(); self.wfile.write(h.encode())
srv = socketserver.ThreadingTCPServer(("0.0.0.0", PORT), H); srv.allow_reuse_address = True
print(f"prepperpi web control on :{PORT}", flush=True); srv.serve_forever()
PYEOF
chmod +x /usr/local/bin/prepperpi-web.py
cat > /etc/systemd/system/prepperpi-web.service <<'EOF'
[Unit]
Description=prepperpi web control panel (:8090)
After=network.target
[Service]
ExecStart=/usr/local/bin/prepperpi-web.py
Restart=always
[Install]
WantedBy=multi-user.target
EOF
systemctl enable prepperpi-web.service >/dev/null 2>&1
# --- landing page (:80) linking to all services ---
mkdir -p /var/www/prepperpi
cat > /var/www/prepperpi/index.html <<'HTML'
<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1"><title>prepperpi</title><style>
:root{--bg:#0e1116;--card:#171d2b;--line:#28303f;--ink:#e6e9ef;--dim:#98a2b3;--acc:#f59e0b}
*{box-sizing:border-box}body{font-family:system-ui,sans-serif;background:var(--bg);color:var(--ink);margin:0;padding:20px;max-width:760px;margin:auto}
h1{font-size:28px;text-align:center;margin:0}.sub{text-align:center;color:var(--dim);font-size:13px;margin:2px 0 16px}
.status{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px;margin-bottom:16px}
.bar{height:12px;border-radius:6px;background:#0e1116;border:1px solid var(--line);overflow:hidden;display:flex}
.seg{height:100%}.stats{display:flex;flex-wrap:wrap;gap:6px 16px;margin-top:9px;font-size:12.5px;color:var(--dim)}
.stats b{color:var(--ink)}
.grid{display:grid;grid-template-columns:1fr 1fr 1fr;gap:12px}
a.tile{display:block;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:18px 10px;text-decoration:none;color:var(--ink);text-align:center;transition:border-color .15s,transform .1s}
a.tile:hover{border-color:var(--acc);transform:translateY(-1px)}.ico{font-size:32px}.name{font-weight:700;margin-top:6px;font-size:14px}.desc{font-size:11px;color:var(--dim);margin-top:3px}
.foot{text-align:center;color:#5b6472;font-size:11px;margin-top:18px}
@media(max-width:520px){.grid{grid-template-columns:1fr 1fr}}
</style></head><body>
<h1>&#128225; prepperpi</h1><div class=sub>offline knowledge &middot; maps &middot; radio &middot; control</div>
<div class=status><div class=bar id=bar></div><div class=stats id=stats>loading&hellip;</div></div>
<div class=grid id=grid></div>
<div class=foot>hotspot: PrepperPi &middot; you are on <span id=host></span></div>
<script>
const h=location.hostname;document.getElementById('host').textContent=h;
const svc=[{i:'&#128218;',n:'Library',d:'Wikipedia, medical, guides',p:8080},{i:'&#127909;',n:'Videos',d:'Survival & skills',p:8082},{i:'&#129302;',n:'Assistant',d:'Offline AI',u:'/assistant.html'},{i:'&#128483;&#65039;',n:'Phrasebook',d:'7 languages',u:'/phrasebook.html'},{i:'&#9992;&#65039;',n:'Airports',d:'72k + radio freqs',u:'/airports.html'},{i:'&#127758;',n:'Maps',d:'World + UK/PL detail',u:'/map.html'},{i:'&#128240;',n:'News',d:'World headlines, 7-day cache',u:'/news.html'},{i:'&#128161;',n:'Help',d:'Misc reference & guides',u:'/help.html'},{i:'&#128752;',n:'Sat Images',d:'Captured weather sat images',p:8095},{i:'&#128225;',n:'Web-SDR',d:'Live radio',p:8073},{i:'&#127899;',n:'Control',d:'Downloads, power, WiFi',p:8090},{i:'&#128421;',n:'Terminal',d:'Shell access',p:7681}];
svc.push({i:'&#127760;',n:'OverMesh',d:'LoRa mesh dashboard + chat/maps',p:8094});
document.getElementById('grid').innerHTML=svc.map(s=>`<a class=tile href="${s.u?'http://'+h+s.u:'http://'+h+':'+s.p+'/'}"><div class=ico>${s.i}</div><div class=name>${s.n}</div><div class=desc>${s.d}</div></a>`).join('');
const fmt=b=>{const g=b/1073741824;return g>=100?g.toFixed(0):g.toFixed(1);};
async function status(){try{const s=await(await fetch('/data/status.json?_='+Date.now())).json();const up=100*s.used/s.total;
 document.getElementById('bar').innerHTML=`<div class=seg style="width:${up}%;background:#f59e0b"></div><div class=seg style="width:${100-up}%;background:#2b3547"></div>`;
 const md=s.mode=='low'?'&#128267; low power':'&#9889; full power';const dl=s.dl=='downloading'?' &middot; <b style=color:#f59e0b>downloading&hellip;</b>':'';
 document.getElementById('stats').innerHTML=`<span><b>${fmt(s.free)} GB</b> free of ${fmt(s.total)} GB</span><span><b>${s.clients}</b> WiFi client${s.clients==1?'':'s'}</span><span>${md}</span><span><b>${s.zims}</b> libraries &middot; <b>${s.videos}</b> videos</span><span>${s.temp}&deg;C</span>${dl}<span style=color:#5b6472>@ ${s.ts}</span>`;
}catch(e){document.getElementById('stats').textContent='status unavailable';}}
status();setInterval(status,30000);
</script></body></html>
HTML
cat > /etc/systemd/system/prepperpi-portal.service <<'EOF'
[Unit]
Description=prepperpi landing page (:80)
After=network.target
[Service]
ExecStart=/usr/bin/python3 -m http.server 80 --directory /var/www/prepperpi --bind 0.0.0.0
Restart=always
[Install]
WantedBy=multi-user.target
EOF
systemctl enable prepperpi-portal.service >/dev/null 2>&1
# --- status feed for the front page (storage/clients/power/temp), refreshed by a timer ---
cat > /usr/local/bin/prepperpi-status <<'ST'
#!/usr/bin/env bash
D=/var/www/prepperpi/data; mkdir -p "$D"
read tot used free <<<"$(df -B1 / | awk 'NR==2{print $2,$3,$4}')"
cl=$(/usr/sbin/iw dev wlan0 station dump 2>/dev/null | grep -c Station)
mode=$(cat /etc/prepperpi/power-mode 2>/dev/null || echo full)
zims=$(ls /data/zim/*.zim 2>/dev/null | wc -l); vids=$(find /data/videos -name '*.mp4' 2>/dev/null | wc -l)
temp=$(vcgencmd measure_temp 2>/dev/null | grep -oE '[0-9.]+' | head -1)
dl=idle; pgrep -f 'prepperpi-update.sh|yt-dlp|wget' >/dev/null && dl=downloading
printf '{"total":%s,"used":%s,"free":%s,"clients":%s,"mode":"%s","zims":%s,"videos":%s,"temp":"%s","dl":"%s","ts":"%s"}\n' \
 "$tot" "$used" "$free" "$cl" "$mode" "$zims" "$vids" "$temp" "$dl" "$(date '+%H:%M')" > "$D/status.json"
ST
chmod +x /usr/local/bin/prepperpi-status
cat > /etc/systemd/system/prepperpi-status.service <<'EOF'
[Unit]
Description=prepperpi status feed
[Service]
Type=oneshot
ExecStart=/usr/local/bin/prepperpi-status
EOF
cat > /etc/systemd/system/prepperpi-status.timer <<'EOF'
[Unit]
Description=refresh prepperpi status
[Timer]
OnBootSec=30
OnUnitActiveSec=2min
[Install]
WantedBy=timers.target
EOF
systemctl enable prepperpi-status.timer >/dev/null 2>&1
# --- offline emergency phrasebook (7 languages incl Polish) ---
cat > /var/www/prepperpi/phrasebook.html <<'HTML'
<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1"><title>prepperpi phrasebook</title><style>
body{font-family:system-ui,sans-serif;background:#0e1116;color:#e6e9ef;margin:0;padding:16px;max-width:680px;margin:auto}
h1{font-size:20px}a{color:#f59e0b}select{width:100%;padding:12px;margin:10px 0;border-radius:8px;border:1px solid #28303f;background:#171d2b;color:#e6e9ef;font-size:16px}
.row{background:#171d2b;border:1px solid #28303f;border-radius:10px;padding:12px;margin:8px 0}
.en{color:#98a2b3;font-size:13px}.tr{font-size:18px;font-weight:700;margin-top:3px}
.cat{color:#f59e0b;font-size:12px;text-transform:uppercase;letter-spacing:.5px;margin:16px 0 4px}</style></head><body>
<h1>&#128483;&#65039; Phrasebook <a href="/" style="font-size:13px;float:right">&larr; home</a></h1>
<select id=lang></select><div id=list></div>
<script>
const L={pl:"Polski",es:"Espanol",fr:"Francais",de:"Deutsch",it:"Italiano",ru:"Russian",pt:"Portugues"};
const P=[["Basics",[
{en:"Hello",pl:"Dzien dobry",es:"Hola",fr:"Bonjour",de:"Guten Tag",it:"Buongiorno",ru:"Zdravstvuyte",pt:"Ola"},
{en:"Thank you",pl:"Dziekuje",es:"Gracias",fr:"Merci",de:"Danke",it:"Grazie",ru:"Spasibo",pt:"Obrigado"},
{en:"Please",pl:"Prosze",es:"Por favor",fr:"S'il vous plait",de:"Bitte",it:"Per favore",ru:"Pozhaluysta",pt:"Por favor"},
{en:"Yes / No",pl:"Tak / Nie",es:"Si / No",fr:"Oui / Non",de:"Ja / Nein",it:"Si / No",ru:"Da / Nyet",pt:"Sim / Nao"},
{en:"Sorry / Excuse me",pl:"Przepraszam",es:"Perdon",fr:"Pardon",de:"Entschuldigung",it:"Mi scusi",ru:"Izvinite",pt:"Desculpe"},
{en:"Do you speak English?",pl:"Czy mowisz po angielsku?",es:"Habla ingles?",fr:"Parlez-vous anglais?",de:"Sprechen Sie Englisch?",it:"Parla inglese?",ru:"Vy govorite po-angliyski?",pt:"Voce fala ingles?"},
{en:"I don't understand",pl:"Nie rozumiem",es:"No entiendo",fr:"Je ne comprends pas",de:"Ich verstehe nicht",it:"Non capisco",ru:"Ya ne ponimayu",pt:"Nao entendo"}]],
["Emergency",[
{en:"Help!",pl:"Pomocy!",es:"Socorro!",fr:"Au secours!",de:"Hilfe!",it:"Aiuto!",ru:"Pomogite!",pt:"Socorro!"},
{en:"It's an emergency",pl:"To nagly wypadek",es:"Es una emergencia",fr:"C'est une urgence",de:"Es ist ein Notfall",it:"E un'emergenza",ru:"Eto chrezvychaynaya situatsiya",pt:"E uma emergencia"},
{en:"Call the police",pl:"Wezwij policje",es:"Llame a la policia",fr:"Appelez la police",de:"Rufen Sie die Polizei",it:"Chiami la polizia",ru:"Vyzovite politsiyu",pt:"Chame a policia"},
{en:"Call a doctor",pl:"Wezwij lekarza",es:"Llame a un medico",fr:"Appelez un medecin",de:"Rufen Sie einen Arzt",it:"Chiami un medico",ru:"Vyzovite vracha",pt:"Chame um medico"},
{en:"I need a doctor",pl:"Potrzebuje lekarza",es:"Necesito un medico",fr:"J'ai besoin d'un medecin",de:"Ich brauche einen Arzt",it:"Ho bisogno di un medico",ru:"Mne nuzhen vrach",pt:"Preciso de um medico"},
{en:"Fire!",pl:"Pozar!",es:"Fuego!",fr:"Au feu!",de:"Feuer!",it:"Al fuoco!",ru:"Pozhar!",pt:"Fogo!"},
{en:"I'm lost",pl:"Zgubilem sie",es:"Estoy perdido",fr:"Je suis perdu",de:"Ich habe mich verlaufen",it:"Mi sono perso",ru:"Ya zabludilsya",pt:"Estou perdido"},
{en:"I'm allergic",pl:"Jestem uczulony",es:"Soy alergico",fr:"Je suis allergique",de:"Ich bin allergisch",it:"Sono allergico",ru:"U menya allergiya",pt:"Sou alergico"}]],
["Needs & places",[
{en:"Where is...?",pl:"Gdzie jest...?",es:"Donde esta...?",fr:"Ou est...?",de:"Wo ist...?",it:"Dov'e...?",ru:"Gde...?",pt:"Onde fica...?"},
{en:"Hospital",pl:"Szpital",es:"Hospital",fr:"Hopital",de:"Krankenhaus",it:"Ospedale",ru:"Bolnitsa",pt:"Hospital"},
{en:"Pharmacy",pl:"Apteka",es:"Farmacia",fr:"Pharmacie",de:"Apotheke",it:"Farmacia",ru:"Apteka",pt:"Farmacia"},
{en:"Toilet",pl:"Toaleta",es:"Bano",fr:"Toilettes",de:"Toilette",it:"Bagno",ru:"Tualet",pt:"Banheiro"},
{en:"Water",pl:"Woda",es:"Agua",fr:"Eau",de:"Wasser",it:"Acqua",ru:"Voda",pt:"Agua"},
{en:"Food",pl:"Jedzenie",es:"Comida",fr:"Nourriture",de:"Essen",it:"Cibo",ru:"Yeda",pt:"Comida"},
{en:"How much?",pl:"Ile to kosztuje?",es:"Cuanto cuesta?",fr:"Combien ca coute?",de:"Wie viel kostet das?",it:"Quanto costa?",ru:"Skolko eto stoit?",pt:"Quanto custa?"}]],
["Numbers 1-5",[
{en:"One",pl:"jeden",es:"uno",fr:"un",de:"eins",it:"uno",ru:"odin",pt:"um"},
{en:"Two",pl:"dwa",es:"dos",fr:"deux",de:"zwei",it:"due",ru:"dva",pt:"dois"},
{en:"Three",pl:"trzy",es:"tres",fr:"trois",de:"drei",it:"tre",ru:"tri",pt:"tres"},
{en:"Four",pl:"cztery",es:"cuatro",fr:"quatre",de:"vier",it:"quattro",ru:"chetyre",pt:"quatro"},
{en:"Five",pl:"piec",es:"cinco",fr:"cinq",de:"funf",it:"cinque",ru:"pyat",pt:"cinco"}]]];
const sel=document.getElementById('lang');
sel.innerHTML=Object.entries(L).map(([k,v])=>`<option value=${k}>${v}</option>`).join('');
function render(){const k=sel.value;document.getElementById('list').innerHTML=P.map(([cat,rows])=>`<div class=cat>${cat}</div>`+rows.map(r=>`<div class=row><div class=en>${r.en}</div><div class=tr>${r[k]}</div></div>`).join('')).join('');}
sel.onchange=render;render();
</script></body></html>
HTML
# --- offline airport database (OurAirports, ~72k airports) + search page ---
( cd /tmp && curl -fsSL -o ap.csv https://davidmegginson.github.io/ourairports-data/airports.csv && \
  curl -fsSL -o rw.csv https://davidmegginson.github.io/ourairports-data/runways.csv && \
  python3 - <<'PY'
import csv,json
rw={}
for r in csv.DictReader(open('/tmp/rw.csv')): rw[r['airport_ref']]=rw.get(r['airport_ref'],0)+1
out=[]
for a in csv.DictReader(open('/tmp/ap.csv')):
    if a['type']=='closed': continue
    out.append([a['ident'],a.get('iata_code',''),a['name'],a['iso_country'],a.get('municipality',''),
      round(float(a['latitude_deg']),4) if a['latitude_deg'] else '',round(float(a['longitude_deg']),4) if a['longitude_deg'] else '',
      a.get('elevation_ft',''),a['type'].replace('_airport','').replace('_',' '),rw.get(a['id'],0)])
json.dump(out,open('/var/www/prepperpi/data/airports.json','w'),separators=(',',':'))
PY
  rm -f /tmp/ap.csv /tmp/rw.csv ) || echo "!! airport data download skipped (no net?)"
mkdir -p /var/www/prepperpi/data
cat > /var/www/prepperpi/airports.html <<'HTML'
<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1"><title>prepperpi airports</title><style>
body{font-family:system-ui,sans-serif;background:#0e1116;color:#e6e9ef;margin:0;padding:16px;max-width:700px;margin:auto}
h1{font-size:20px}a{color:#f59e0b}input{width:100%;padding:12px;margin:8px 0;border-radius:8px;border:1px solid #28303f;background:#171d2b;color:#e6e9ef;font-size:16px;box-sizing:border-box}
.r{background:#171d2b;border:1px solid #28303f;border-radius:10px;padding:11px;margin:7px 0}.n{font-weight:700}.m{color:#98a2b3;font-size:13px;margin-top:2px}
.b{display:inline-block;background:#2b3547;border-radius:5px;padding:1px 7px;font-size:12px;margin-right:6px;font-family:monospace}.hint{color:#98a2b3;font-size:12px}</style></head><body>
<h1>&#9992;&#65039; Airports <a href="/" style="font-size:13px;float:right">&larr; home</a></h1>
<input id=q placeholder="search ICAO / IATA / name / city" autocomplete=off>
<div class=hint id=st>loading&hellip;</div><div id=out></div>
<script>
let A=[];const out=document.getElementById('out'),st=document.getElementById('st');
fetch('/data/airports.json').then(r=>r.json()).then(d=>{A=d;st.textContent=A.length+" airports loaded. Type to search.";});
const q=document.getElementById('q');let t;q.oninput=()=>{clearTimeout(t);t=setTimeout(search,120);};
function search(){const s=q.value.trim().toLowerCase();if(s.length<2){out.innerHTML='';return;}
 const res=[];for(const a of A){if(a[0].toLowerCase()==s||(a[1]&&a[1].toLowerCase()==s)||a[2].toLowerCase().includes(s)||(a[4]&&a[4].toLowerCase().includes(s))){res.push(a);if(res.length>=60)break;}}
 st.textContent=res.length+(res.length>=60?'+ ':' ')+'results';
 out.innerHTML=res.map(a=>{const ll=(a[5]!==''&&a[6]!=='')?`${a[5]},${a[6]}`:'';
  return `<div class=r><div class=n>${a[2]}</div><div class=m>${a[4]?a[4]+', ':''}${a[3]} &middot; ${a[8]}${a[9]?' &middot; '+a[9]+' rwy':''}${a[7]?' &middot; '+a[7]+' ft':''}</div>
  <div style=margin-top:6px>${a[0]?'<span class=b>'+a[0]+'</span>':''}${a[1]?'<span class=b>'+a[1]+'</span>':''}${ll?'<span class=m>'+ll+'</span> <a href="https://www.openstreetmap.org/?mlat='+a[5]+'&mlon='+a[6]+'#map=14/'+a[5]+'/'+a[6]+'" style=font-size:12px>map&#8599;</a>':''}</div></div>`;}).join('');}
</script></body></html>
HTML
# --- world news headlines (rolling 7-day offline cache from major RSS feeds, no API key) ---
mkdir -p /var/www/prepperpi/data
cat > /usr/local/bin/prepperpi-news-update <<'PY'
#!/usr/bin/env python3
import json
import os
import re
import html as htmlmod
import xml.etree.ElementTree as ET
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from email.utils import parsedate_to_datetime
from datetime import datetime, timezone, timedelta

OUT_FILE = "/var/www/prepperpi/data/news.json"
RETAIN_DAYS = 7
TIMEOUT = 15
ARTICLE_TIMEOUT = 10
MAX_ARTICLE_CHARS = 6000
FETCH_WORKERS = 8

FEEDS = [
    ("BBC World", "http://feeds.bbci.co.uk/news/world/rss.xml"),
    ("Al Jazeera", "https://www.aljazeera.com/xml/rss/all.xml"),
    ("The Guardian World", "https://www.theguardian.com/world/rss"),
    ("NPR World", "https://feeds.npr.org/1004/rss.xml"),
    ("DW World", "https://rss.dw.com/xml/rss-en-world"),
    ("France 24", "https://www.france24.com/en/rss"),
    ("ABC Australia", "https://www.abc.net.au/news/feed/51120/rss.xml"),
    ("Sky News World", "https://feeds.skynews.com/feeds/rss/world.xml"),
]

TAG_RE = re.compile(r"<[^>]+>")
STRIP_BLOCK_RE = re.compile(r"(?is)<(script|style|noscript|nav|header|footer|form|aside|figure|iframe)\b[^>]*>.*?</\1>")
COMMENT_RE = re.compile(r"(?is)<!--.*?-->")
PARA_RE = re.compile(r"(?is)<p\b[^>]*>(.*?)</p>")
BOILERPLATE_MARKERS = ("subscribe", "sign up for", "newsletter", "cookie", "all rights reserved", "follow us on")

def strip_html(s):
    if not s:
        return ""
    s = TAG_RE.sub("", s)
    s = s.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&#39;", "'").replace("&quot;", '"')
    return s.strip()

def fetch(url, timeout=TIMEOUT):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (prepperpi-news)"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()

def extract_article_text(raw_html, max_chars=MAX_ARTICLE_CHARS):
    h = STRIP_BLOCK_RE.sub(" ", raw_html)
    h = COMMENT_RE.sub(" ", h)
    clean = []
    for p in PARA_RE.findall(h):
        t = TAG_RE.sub("", p)
        t = htmlmod.unescape(t)
        t = re.sub(r"\s+", " ", t).strip()
        if len(t) < 40:
            continue
        if any(k in t.lower() for k in BOILERPLATE_MARKERS):
            continue
        clean.append(t)
    return "\n\n".join(clean)[:max_chars]

def fetch_article_text(link):
    try:
        raw = fetch(link, timeout=ARTICLE_TIMEOUT).decode("utf-8", "replace")
        return extract_article_text(raw)
    except Exception:
        return ""

def parse_feed(source, url):
    items = []
    try:
        raw = fetch(url)
        root = ET.fromstring(raw)
    except Exception as e:
        print("!! {}: {}".format(source, e))
        return items
    for item in root.iter("item"):
        title = item.findtext("title") or ""
        link = item.findtext("link") or ""
        pub = item.findtext("pubDate") or item.findtext("{http://purl.org/dc/elements/1.1/}date") or ""
        desc = item.findtext("description") or ""
        if not title or not link:
            continue
        try:
            dt = parsedate_to_datetime(pub)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
        except Exception:
            dt = datetime.now(timezone.utc)
        items.append({
            "source": source,
            "title": strip_html(title),
            "link": link.strip(),
            "summary": strip_html(desc)[:300],
            "date": dt.astimezone(timezone.utc).isoformat(),
        })
    return items

def load_existing():
    try:
        with open(OUT_FILE) as f:
            return json.load(f)
    except Exception:
        return []

def write_atomic(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f)
    os.replace(tmp, path)

def _parse_iso(s):
    try:
        return datetime.fromisoformat(s)
    except Exception:
        return datetime.now(timezone.utc)

def main():
    os.makedirs(os.path.dirname(OUT_FILE), exist_ok=True)
    all_items = load_existing()
    by_link = {a["link"]: a for a in all_items}

    pending_links = []
    for source, url in FEEDS:
        new_items = parse_feed(source, url)
        for it in new_items:
            existing = by_link.get(it["link"])
            if existing and existing.get("text"):
                it["text"] = existing["text"]
            else:
                pending_links.append(it["link"])
            by_link[it["link"]] = it
        print("{}: {} items".format(source, len(new_items)))

    if pending_links:
        print("fetching full text for {} new articles...".format(len(pending_links)))
        with ThreadPoolExecutor(max_workers=FETCH_WORKERS) as ex:
            texts = list(ex.map(fetch_article_text, pending_links))
        for link, text in zip(pending_links, texts):
            by_link[link]["text"] = text

    cutoff = datetime.now(timezone.utc) - timedelta(days=RETAIN_DAYS)
    merged = [a for a in by_link.values() if _parse_iso(a["date"]) >= cutoff]
    merged.sort(key=lambda a: a["date"], reverse=True)

    write_atomic(OUT_FILE, merged)
    with_text = sum(1 for a in merged if a.get("text"))
    print("total cached (last {} days): {} ({} with full text)".format(RETAIN_DAYS, len(merged), with_text))

if __name__ == "__main__":
    main()
PY
chmod +x /usr/local/bin/prepperpi-news-update
/usr/local/bin/prepperpi-news-update || echo "!! news headline fetch skipped (no net?)"
cat > /var/www/prepperpi/news.html <<'HTML'
<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1"><title>prepperpi news</title><style>
body{font-family:system-ui,sans-serif;background:#0e1116;color:#e6e9ef;margin:0;padding:16px;max-width:760px;margin:auto}
h1{font-size:20px}a{color:#f59e0b}input,select{width:100%;padding:12px;margin:6px 0;border-radius:8px;border:1px solid #28303f;background:#171d2b;color:#e6e9ef;font-size:15px;box-sizing:border-box}
.row{display:flex;gap:8px}.row>*{flex:1}
.day{color:#98a2b3;font-size:12px;text-transform:uppercase;letter-spacing:.04em;margin:16px 0 6px}
.r{background:#171d2b;border:1px solid #28303f;border-radius:10px;padding:11px;margin:7px 0;cursor:pointer}
.r .hd{font-weight:700}.r .hd:hover{color:#f59e0b}
.m{color:#98a2b3;font-size:13px;margin-top:5px}
.b{display:inline-block;background:#2b3547;border-radius:5px;padding:1px 7px;font-size:11px;margin-right:6px;color:#f59e0b}
.b.live{color:#5b8fd6}
.body{margin-top:10px;padding-top:10px;border-top:1px solid #28303f;font-size:14px;line-height:1.55;white-space:pre-wrap;display:none}
.body.open{display:block}
.orig{display:inline-block;margin-top:8px;font-size:12px}
.hint{color:#98a2b3;font-size:12px}</style></head><body>
<h1>&#128240; World Headlines <a href="/" style="font-size:13px;float:right">&larr; home</a></h1>
<div class=hint id=st>loading&hellip;</div>
<div class=row><input id=q placeholder="search headlines" autocomplete=off><select id=src><option value="">All sources</option></select></div>
<div id=out></div>
<script>
let A=[];const out=document.getElementById('out'),st=document.getElementById('st'),q=document.getElementById('q'),src=document.getElementById('src');
fetch('/data/news.json').then(r=>r.json()).then(d=>{
 A=d;
 const sources=[...new Set(A.map(a=>a.source))].sort();
 src.innerHTML='<option value="">All sources</option>'+sources.map(s=>`<option value="${s}">${s}</option>`).join('');
 const newest=A.length?new Date(A[0].date):null;
 const cached=A.filter(a=>a.text).length;
 st.textContent=A.length+' headlines cached ('+cached+' with full offline text), last 7 days'+(newest?' - newest: '+newest.toLocaleString():'');
 render();
}).catch(()=>{st.textContent='no cached headlines yet (needs one online refresh)';});
function dayLabel(d){const dt=new Date(d);const days=['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];return days[dt.getDay()]+' '+dt.toLocaleDateString();}
function esc(s){return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
function render(){
 const s=q.value.trim().toLowerCase(),so=src.value;
 const res=A.filter(a=>(!so||a.source===so)&&(!s||a.title.toLowerCase().includes(s)||a.summary.toLowerCase().includes(s)));
 let html='',lastDay='';
 res.forEach((a,i)=>{
  const d=dayLabel(a.date);
  if(d!==lastDay){html+=`<div class=day>${d}</div>`;lastDay=d;}
  const hasText=!!a.text;
  html+=`<div class=r onclick="toggle(${i})"><div class=hd>${esc(a.title)}</div><div class=m><span class=b>${a.source}</span>${hasText?'<span class="b live">&#128190; offline-ready</span>':'<span class="b live">&#127760; needs internet</span>'}${hasText?'':' '+esc(a.summary).slice(0,140)}</div>`+
   `<div class=body id=body${i}>${hasText?esc(a.text):'<i>Full text not cached for this one'+(a.summary?' - summary: '+esc(a.summary):'')+'.</i>'}<br><a class=orig href="${a.link}" target=_blank rel=noopener onclick="event.stopPropagation()">open original &#8599;</a></div></div>`;
 });
 out.innerHTML=html||'<div class=hint>no matches</div>';
 window._res=res;
}
function toggle(i){const el=document.getElementById('body'+i);el.classList.toggle('open');}
q.oninput=render;src.onchange=render;
</script></body></html>
HTML
cat > /etc/systemd/system/prepperpi-news.service <<'EOF'
[Unit]
Description=prepperpi world news headline refresh
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
Nice=15
ExecStart=/usr/local/bin/prepperpi-news-update
EOF
cat > /etc/systemd/system/prepperpi-news.timer <<'EOF'
[Unit]
Description=refresh prepperpi world news headlines
[Timer]
OnBootSec=2min
OnUnitActiveSec=3h
RandomizedDelaySec=5min
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now prepperpi-news.timer >/dev/null 2>&1
# --- misc help/reference page (offline reading, no data feed) ---
cat > /var/www/prepperpi/help.html <<'HTML'
<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1"><title>prepperpi help</title><style>
body{font-family:system-ui,sans-serif;background:#0e1116;color:#e6e9ef;margin:0;padding:16px;max-width:760px;margin:auto}
h1{font-size:20px}h2{font-size:16px;color:#f59e0b;margin-top:26px;border-top:1px solid #28303f;padding-top:16px}
a{color:#f59e0b}.card{background:#171d2b;border:1px solid #28303f;border-radius:10px;padding:12px 14px;margin:10px 0}
table{width:100%;border-collapse:collapse;font-size:13px}th,td{text-align:left;padding:6px 8px;border-bottom:1px solid #28303f}
th{color:#98a2b3;font-weight:600;font-size:12px;text-transform:uppercase}
.dim{color:#98a2b3;font-size:12.5px}.warn{color:#f5a623}
code{background:#0e1116;border:1px solid #28303f;border-radius:4px;padding:1px 5px;font-size:12.5px}
ol,ul{padding-left:20px;font-size:14px;line-height:1.6}
.diagram{background:#0e1116;border:1px solid #28303f;border-radius:8px;padding:10px;font-family:monospace;font-size:12px;white-space:pre;overflow-x:auto;color:#98a2b3}
.toc{font-size:13px}.toc a{display:inline-block;margin:2px 10px 2px 0}</style></head><body>
<h1>&#128161; Misc / Help <a href="/" style="font-size:13px;float:right">&larr; home</a></h1>
<p class=dim>Odds and ends that don't need their own home-screen tile &mdash; kept offline, add sections here as they come up.</p>
<div class=toc card><a href="#satellites">Weather satellite / Iridium reception</a></div>

<h2 id=satellites>&#128752; Weather satellite &amp; Iridium reception</h2>
<p class=dim>Reference for the RTL-SDR V4 on this box. <span class=warn>Frequencies below are commonly published nominal values &mdash; individual satellites occasionally get reassigned, so cross-check when you have signal.</span></p>

<div class=card><table>
<tr><th>System</th><th>Freq</th><th>Type</th><th>Pol.</th><th>Notes</th></tr>
<tr><td>Meteor-M2 LRPT</td><td>137.1 or 137.9125 MHz</td><td>Digital QPSK</td><td>RHCP</td><td>polar orbit, ~15min passes</td></tr>
<tr><td>Elektro-L LRIT</td><td>&#8776;1693.9 MHz</td><td>Digital</td><td>RHCP</td><td>geostationary &mdash; always up, needs dish/helix + LNA</td></tr>
<tr><td>NOAA-15 APT <span class=dim>(ref only)</span></td><td>137.620 MHz</td><td>Analog FM</td><td>RHCP</td><td>satellite retired &mdash; kept for reference</td></tr>
<tr><td>NOAA-18 APT <span class=dim>(ref only)</span></td><td>137.9125 MHz</td><td>Analog FM</td><td>RHCP</td><td>verify still active before relying on it</td></tr>
<tr><td>NOAA-19 APT <span class=dim>(ref only)</span></td><td>137.100 MHz</td><td>Analog FM</td><td>RHCP</td><td>satellite retired &mdash; kept for reference</td></tr>
<tr><td>Iridium ring/paging</td><td>1616&ndash;1626.5 MHz</td><td>Digital, LEO constellation</td><td>RHCP</td><td>unencrypted signalling only</td></tr>
</table></div>

<div class=card>
<b>V-dipole for 137MHz (Meteor-M2 / APT)</b> &mdash; recommended starting build. Cheap, portable, forgiving.
<p><b>Cut length per element: &#8776; 52 cm</b> (137.5MHz centre, quarter-wave, 0.95 wire-velocity factor). Wire or steel tape measure, two elements from one feedpoint.</p>
<div class=diagram>        feedpoint (coax here)
             \  /
              \/
             /  \
   element  /    \  element
   ~52cm   /      \   ~52cm
          /        \
   (~120-140 deg included angle, drooping down)</div>
<ol>
<li>Coax centre &rarr; one element, shield/braid &rarr; the other, at the feedpoint.</li>
<li>Feedpoint up (zenith), elements drooping ~30-40&deg; below horizontal.</li>
<li>Weatherproof the feedpoint.</li>
<li>No tuning needed for RX-only use.</li>
</ol>
</div>

<div class=card>
<b>QFH (quadrifilar helix)</b> &mdash; the upgrade, not the starting point. Circularly polarized + omnidirectional, but fiddly: dimensions are sensitive to your exact tubing diameter, unlike the forgiving dipole above.
<p class=dim>Rule-of-thumb if home-brewing: bottom loop circumference &#8776; 1.05&times;&lambda;, top loop &#8776; 0.88&times; the bottom loop's electrical length, axial height &#8776; 0.15-0.16&times;&lambda; (&lambda;=2.18m @ 137.5MHz). Most people buy a pre-made 137MHz QFH (&#163;25-40) rather than home-brew blind given how sensitive it is. Build the V-dipole first, decide afterwards if a QFH is worth it.</p>
</div>

<div class=card>
<b>Iridium</b> &mdash; the antenna you already have (small RHCP patch/helix near 1621MHz) is already the right shape, no build needed. Connect straight to the RTL-SDR V4.
</div>

<div class=card><b>General tips</b><ul>
<li><b>Meteor-M2 / NOAA (137MHz):</b> low orbit &mdash; only overhead ~10-15min, a few times a day. Needs pass-time prediction (TLE-based) to know when to record.</li>
<li><b>Elektro-L (1.69GHz geostationary):</b> fixed spot in the sky, no scheduling, but weaker signal &mdash; more sensitive to antenna/LNA quality.</li>
<li><b>Iridium:</b> 66 satellites, passes frequent and short, something almost always in view.</li>
<li>RHCP antennas give the best results for all of these; a plain linear dipole works but loses a bit of signal &mdash; fine for high-elevation LEO passes, more noticeable on the weaker geostationary/Iridium signals.</li>
</ul></div>

</body></html>
HTML

# --- Meteor-M2 weather satellite reception (satdump + skyfield pass scheduler) ---
# satdump's OpenWebRX+ integration is a stub (never calls the image-render step), so this
# runs satdump directly against the RTL-SDR, stopping/restarting the openwebrx container
# around each pass since the dongle can only be used by one process at a time.
apt-get install -y satdump python3-skyfield 2>&1 | tail -5 || echo "!! satdump/skyfield install skipped (no net?)"
mkdir -p /var/lib/prepperpi /var/www/prepperpi/data/satimages
cat > /usr/local/bin/prepperpi-tle-update <<'PY'
#!/usr/bin/env python3
import os
import urllib.request

OUT_FILE = "/var/lib/prepperpi/meteor-tles.txt"
URL = "https://celestrak.org/NORAD/elements/gp.php?GROUP=weather&FORMAT=tle"
# Only keep these (Meteor-M2 series - the ones satdump's meteor_m2-x_lrpt pipeline decodes)
WANTED_PREFIXES = ("METEOR-M2", "METEOR-M 2")

def fetch(url, timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (prepperpi-tle-update)"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode("utf-8", "replace")

def main():
    os.makedirs(os.path.dirname(OUT_FILE), exist_ok=True)
    try:
        raw = fetch(URL)
    except Exception as e:
        print("!! TLE fetch failed ({}), leaving existing cache in place".format(e))
        return
    lines = [l.rstrip("\r\n") for l in raw.splitlines()]
    kept = []
    i = 0
    while i < len(lines) - 2:
        name = lines[i].strip()
        if name.startswith(WANTED_PREFIXES) and lines[i + 1].startswith("1 ") and lines[i + 2].startswith("2 "):
            kept.extend([name, lines[i + 1], lines[i + 2]])
            i += 3
        else:
            i += 1
    if not kept:
        print("!! no matching Meteor-M2 TLEs found in feed, leaving existing cache in place")
        return
    tmp = OUT_FILE + ".tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(kept) + "\n")
    os.replace(tmp, OUT_FILE)
    print("cached {} satellites".format(len(kept) // 3))

if __name__ == "__main__":
    main()
PY
chmod +x /usr/local/bin/prepperpi-tle-update
cat > /usr/local/bin/prepperpi-satsched <<'PY'
#!/usr/bin/env python3
"""
Waits for the next overhead Meteor-M2 pass, briefly stops the OpenWebRX+
docker container (single RTL-SDR, can't be shared), captures + decodes the
pass with satdump directly against the dongle, restarts OpenWebRX+, and
files the resulting images for the web gallery.
"""
import glob
import json
import os
import shutil
import subprocess
import time
import urllib.request
from datetime import datetime, timedelta, timezone

from skyfield.api import EarthSatellite, load, wgs84

TLE_FILE = "/var/lib/prepperpi/meteor-tles.txt"
LOCATION_CACHE = "/var/lib/prepperpi/location.json"
STATUS_FILE = "/var/lib/prepperpi/next-pass.json"
OUT_DIR = "/var/www/prepperpi/data/satimages"
MANIFEST_FILE = os.path.join(OUT_DIR, "manifest.json")
WORK_DIR = "/tmp/satdump"
MIN_ELEVATION_DEG = 20
SEARCH_HORIZON_HOURS = 30
POLL_SECONDS = 300
FREQUENCY_HZ = 137900000
SAMPLERATE_HZ = 1000000
DOCKER_SETTLE_SECONDS = 4

def log(msg):
    print("[{}] {}".format(datetime.now(timezone.utc).isoformat(timespec="seconds"), msg), flush=True)

def get_location():
    try:
        req = urllib.request.Request(
            "http://ip-api.com/json?fields=lat,lon",
            headers={"User-Agent": "Mozilla/5.0 (prepperpi-satsched)"},
        )
        with urllib.request.urlopen(req, timeout=8) as resp:
            d = json.load(resp)
        lat, lon = d["lat"], d["lon"]
        os.makedirs(os.path.dirname(LOCATION_CACHE), exist_ok=True)
        tmp = LOCATION_CACHE + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"lat": lat, "lon": lon}, f)
        os.replace(tmp, LOCATION_CACHE)
        return lat, lon
    except Exception as e:
        log("location lookup failed ({}), trying cache".format(e))
        try:
            with open(LOCATION_CACHE) as f:
                d = json.load(f)
            return d["lat"], d["lon"]
        except Exception:
            log("no cached location either - defaulting to London")
            return 51.5, -0.12

def load_satellites(ts):
    sats = []
    try:
        with open(TLE_FILE) as f:
            lines = [l.rstrip("\n") for l in f if l.strip()]
    except Exception:
        return sats
    for i in range(0, len(lines) - 2, 3):
        name, l1, l2 = lines[i], lines[i + 1], lines[i + 2]
        try:
            sats.append(EarthSatellite(l1, l2, name, ts))
        except Exception:
            continue
    return sats

def find_next_pass(ts, sats, lat, lon):
    observer = wgs84.latlon(lat, lon)
    now = ts.now()
    end = ts.utc((datetime.now(timezone.utc) + timedelta(hours=SEARCH_HORIZON_HOURS)))
    best = None
    for sat in sats:
        try:
            times, events = sat.find_events(observer, now, end, altitude_degrees=MIN_ELEVATION_DEG)
        except Exception:
            continue
        aos = los = None
        for t, e in zip(times, events):
            if e == 0:
                aos = t
            elif e == 2 and aos is not None:
                los = t
                if best is None or aos.utc_datetime() < best[1].utc_datetime():
                    best = (sat, aos, los)
                aos = None
    return best

def wait_for(dt):
    while True:
        remaining = (dt - datetime.now(timezone.utc)).total_seconds()
        if remaining <= 0:
            return
        time.sleep(min(remaining, POLL_SECONDS))

def do_capture(sat_name, duration_seconds):
    safe_name = sat_name.replace(" ", "-").replace("/", "-")
    stamp = datetime.now(timezone.utc).strftime("%y%m%d-%H%M%S")
    outfolder = os.path.join(WORK_DIR, "{}-{}".format(safe_name, stamp))
    os.makedirs(outfolder, exist_ok=True)

    log("pass starting: {} for {:.0f}s -> {}".format(sat_name, duration_seconds, outfolder))
    subprocess.run(["docker", "stop", "openwebrx"], capture_output=True)
    time.sleep(DOCKER_SETTLE_SECONDS)
    try:
        subprocess.run(
            [
                "satdump", "live", "meteor_m2-x_lrpt", outfolder,
                "--source", "rtlsdr",
                "--samplerate", str(SAMPLERATE_HZ),
                "--frequency", str(FREQUENCY_HZ),
                "--finish_processing",
                "--timeout", str(int(duration_seconds)),
            ],
            timeout=duration_seconds + 90,
            capture_output=True,
        )
    except Exception as e:
        log("capture error: {}".format(e))
    finally:
        subprocess.run(["docker", "start", "openwebrx"], capture_output=True)

    os.makedirs(OUT_DIR, exist_ok=True)
    try:
        with open(MANIFEST_FILE) as f:
            manifest = json.load(f)
    except Exception:
        manifest = []
    copied = 0
    for png in sorted(glob.glob(os.path.join(outfolder, "**", "*.png"), recursive=True)):
        fname = "{}_{}_{}".format(safe_name, stamp, os.path.basename(png))
        dest = os.path.join(OUT_DIR, fname)
        try:
            shutil.copy(png, dest)
            manifest.append({
                "file": fname,
                "satellite": sat_name,
                "date": datetime.now(timezone.utc).isoformat(),
            })
            copied += 1
        except Exception:
            pass
    manifest.sort(key=lambda a: a["date"], reverse=True)
    tmp = MANIFEST_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(manifest, f)
    os.replace(tmp, MANIFEST_FILE)
    log("pass finished: {} image(s) collected".format(copied))

def write_status(status):
    os.makedirs(os.path.dirname(STATUS_FILE), exist_ok=True)
    tmp = STATUS_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(status, f)
    os.replace(tmp, STATUS_FILE)

def main():
    ts = load.timescale()
    last_tle_refresh = 0
    while True:
        if time.time() - last_tle_refresh > 12 * 3600:
            subprocess.run(["/usr/local/bin/prepperpi-tle-update"], capture_output=True)
            last_tle_refresh = time.time()

        sats = load_satellites(ts)
        if not sats:
            log("no TLE data available yet, retrying in {}s".format(POLL_SECONDS))
            write_status({"state": "no_tle", "checked": datetime.now(timezone.utc).isoformat()})
            time.sleep(POLL_SECONDS)
            continue

        lat, lon = get_location()
        nxt = find_next_pass(ts, sats, lat, lon)
        if nxt is None:
            log("no pass >= {} deg elevation in next {}h, rechecking in {}s".format(
                MIN_ELEVATION_DEG, SEARCH_HORIZON_HOURS, POLL_SECONDS))
            write_status({"state": "no_pass", "checked": datetime.now(timezone.utc).isoformat()})
            time.sleep(POLL_SECONDS)
            continue

        sat, aos, los = nxt
        aos_dt = aos.utc_datetime()
        los_dt = los.utc_datetime()
        log("next pass: {} AOS {} LOS {}".format(sat.name, aos_dt.isoformat(), los_dt.isoformat()))
        write_status({
            "state": "scheduled",
            "satellite": sat.name,
            "aos": aos_dt.isoformat(),
            "los": los_dt.isoformat(),
            "checked": datetime.now(timezone.utc).isoformat(),
        })
        wait_for(aos_dt - timedelta(seconds=20))
        write_status({
            "state": "capturing",
            "satellite": sat.name,
            "aos": aos_dt.isoformat(),
            "los": los_dt.isoformat(),
            "checked": datetime.now(timezone.utc).isoformat(),
        })
        do_capture(sat.name, (los_dt - aos_dt).total_seconds())

if __name__ == "__main__":
    main()
PY
chmod +x /usr/local/bin/prepperpi-satsched
cat > /usr/local/bin/prepperpi-elektro-capture <<'SH'
#!/usr/bin/env bash
# prepperpi-elektro-capture [minutes]
# Elektro-L is geostationary - always in the same spot, no pass timing needed.
# Needs a dish/helix + LNA pointed at it; manual/on-demand, unlike the Meteor-M2 scheduler.
set -e
MINUTES="${1:-15}"
STAMP=$(date -u +%y%m%d-%H%M%S)
OUTDIR="/tmp/satdump/ELEKTRO-${STAMP}"
mkdir -p "$OUTDIR"

echo ">> stopping OpenWebRX+ (single SDR, needs exclusive access)"
docker stop openwebrx >/dev/null 2>&1 || true
sleep 4

echo ">> capturing Elektro-L LRIT for ${MINUTES} minute(s)"
satdump live elektro_lrit "$OUTDIR" \
  --source rtlsdr \
  --samplerate 2000000 \
  --frequency 1691000000 \
  --finish_processing \
  --timeout $((MINUTES * 60)) || true

echo ">> restarting OpenWebRX+"
docker start openwebrx >/dev/null 2>&1 || true

mkdir -p /var/www/prepperpi/data/satimages
COPIED=0
while IFS= read -r -d '' png; do
  FNAME="ELEKTRO-L_${STAMP}_$(basename "$png")"
  cp "$png" "/var/www/prepperpi/data/satimages/${FNAME}"
  COPIED=$((COPIED + 1))
  python3 - "$FNAME" <<'PY'
import json, os, sys
from datetime import datetime, timezone
fname = sys.argv[1]
manifest_path = "/var/www/prepperpi/data/satimages/manifest.json"
try:
    with open(manifest_path) as f:
        manifest = json.load(f)
except Exception:
    manifest = []
manifest.append({"file": fname, "satellite": "Elektro-L", "date": datetime.now(timezone.utc).isoformat()})
manifest.sort(key=lambda a: a["date"], reverse=True)
tmp = manifest_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(manifest, f)
os.replace(tmp, manifest_path)
PY
done < <(find "$OUTDIR" -name "*.png" -print0)
echo ">> done, ${COPIED} image(s) collected -> /satimages.html"
SH
chmod +x /usr/local/bin/prepperpi-elektro-capture
cat > /var/www/prepperpi/satimages.html <<'HTML'
<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1"><title>prepperpi sat images</title><style>
body{font-family:system-ui,sans-serif;background:#0e1116;color:#e6e9ef;margin:0;padding:16px;max-width:900px;margin:auto}
h1{font-size:20px}a{color:#f59e0b}.hint{color:#98a2b3;font-size:12.5px}
.grid{display:flex;flex-wrap:wrap;gap:12px;margin-top:12px}
.c{background:#171d2b;border:1px solid #28303f;border-radius:10px;padding:8px;width:220px;cursor:pointer}
.c img{width:100%;border-radius:6px;display:block;background:#000}
.c .n{font-size:12px;color:#98a2b3;margin-top:6px}.c .d{font-size:11px;color:#5b6472}
.lb{position:fixed;inset:0;background:#000c;display:none;align-items:center;justify-content:center;z-index:5;padding:20px;cursor:zoom-out}
.lb.open{display:flex}.lb img{max-width:100%;max-height:100%;border-radius:6px}
</style></head><body>
<h1>&#128752; Satellite Images <a href="/" style="font-size:13px;float:right">&larr; home</a></h1>
<div class=hint id=st>loading&hellip;</div>
<div class=grid id=grid></div>
<div class=lb id=lb onclick="this.classList.remove('open')"><img id=lbimg></div>
<script>
fetch('/data/satimages/manifest.json').then(r=>r.json()).then(items=>{
 const st=document.getElementById('st'),grid=document.getElementById('grid');
 if(!items.length){st.textContent='no images captured yet.';return;}
 st.textContent=items.length+' image(s) captured';
 grid.innerHTML=items.map(it=>`<div class=c onclick="openImg('${it.file}')"><img loading=lazy src="/data/satimages/${it.file}"><div class=n>${it.satellite}</div><div class=d>${new Date(it.date).toLocaleString()}</div></div>`).join('');
}).catch(()=>{document.getElementById('st').textContent='no images yet - the Meteor-M2 scheduler fills this in automatically once running (see Help), or run prepperpi-elektro-capture manually.';});
function openImg(f){document.getElementById('lbimg').src='/data/satimages/'+f;document.getElementById('lb').classList.add('open');}
</script></body></html>
HTML
/usr/local/bin/prepperpi-tle-update || echo "!! initial TLE fetch skipped (no net?)"
cat > /etc/systemd/system/prepperpi-tle.service <<'EOF'
[Unit]
Description=prepperpi Meteor-M2 TLE refresh
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/prepperpi-tle-update
EOF
cat > /etc/systemd/system/prepperpi-tle.timer <<'EOF'
[Unit]
Description=daily prepperpi TLE refresh
[Timer]
OnCalendar=daily
RandomizedDelaySec=30min
Persistent=true
[Install]
WantedBy=timers.target
EOF
cat > /etc/systemd/system/prepperpi-satsched.service <<'EOF'
[Unit]
Description=prepperpi Meteor-M2 weather satellite pass scheduler
After=network-online.target docker.service
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/bin/prepperpi-satsched
Restart=on-failure
RestartSec=30
[Install]
WantedBy=multi-user.target
EOF
cat > /usr/local/bin/satgallery-server.py <<'PY'
#!/usr/bin/env python3
"""Weather satellite image gallery with a status header (next pass, last
checked, staleness warning) and an enable/disable toggle for the scheduler."""
import http.server
import json
import os
import socketserver
import subprocess
import urllib.parse
from datetime import datetime, timezone

# --- per-device config ---
PORT = 8095
STATUS_FILE = "/var/lib/prepperpi/next-pass.json"
OUT_DIR = "/var/www/prepperpi/data/satimages"
SERVICE_NAME = "prepperpi-satsched"
DEVICE_LABEL = "prepperpi"
# --- end per-device config ---

MANIFEST_FILE = os.path.join(OUT_DIR, "manifest.json")
STALE_AFTER_SECONDS = 3600

def svc_active(name):
    r = subprocess.run(["systemctl", "is-active", name], capture_output=True, text=True)
    return r.stdout.strip()

def svc_enabled(name):
    r = subprocess.run(["systemctl", "is-enabled", name], capture_output=True, text=True)
    return r.stdout.strip()

def fmt_delta(target):
    secs = (target - datetime.now(timezone.utc)).total_seconds()
    if secs < 0:
        return "in progress"
    m, s = divmod(int(secs), 60)
    h, m = divmod(m, 60)
    return (f"{h}h {m}m" if h else f"{m}m {s}s")

def status_html():
    active = svc_active(SERVICE_NAME)
    enabled = svc_enabled(SERVICE_NAME)
    badge_color = {"active": "#3fb950", "inactive": "#98a2b3", "failed": "#f85149"}.get(active, "#98a2b3")
    toggle_action = "sat_off" if enabled == "enabled" else "sat_on"
    toggle_label = "Disable auto-capture" if enabled == "enabled" else "Enable auto-capture"

    try:
        with open(STATUS_FILE) as f:
            d = json.load(f)
    except Exception:
        d = None

    if d is None:
        pass_html = '<span class=dim>No prediction yet.</span>'
        staleness = ""
    else:
        checked = datetime.fromisoformat(d["checked"])
        age = (datetime.now(timezone.utc) - checked).total_seconds()
        stale = age > STALE_AFTER_SECONDS
        staleness = (f'<span style="color:#f5a623">&#9888; last checked {int(age // 60)}m ago '
                     f'&mdash; {DEVICE_LABEL} may be offline</span>') if stale else \
                    f'<span class=dim>last checked {int(age // 60)}m ago</span>'
        state = d.get("state")
        if state == "scheduled":
            aos = datetime.fromisoformat(d["aos"])
            los = datetime.fromisoformat(d["los"])
            pass_html = (f'<b>{d["satellite"]}</b> &mdash; AOS {aos.strftime("%H:%M UTC")} '
                         f'&middot; LOS {los.strftime("%H:%M UTC")} '
                         f'<span class=dim>({fmt_delta(aos)} away)</span>')
        elif state == "capturing":
            los = datetime.fromisoformat(d["los"])
            pass_html = f'<b>{d["satellite"]}</b> &mdash; <span style="color:#3fb950;font-weight:700">capturing now</span>, done in {fmt_delta(los)}'
        elif state == "no_pass":
            pass_html = '<span class=dim>No pass above the elevation threshold right now.</span>'
        elif state == "no_tle":
            pass_html = '<span class=dim>Waiting on satellite tracking data.</span>'
        else:
            pass_html = '<span class=dim>Unknown state.</span>'

    return f"""<div class=card>
<div><b>Scheduler:</b> <span style="color:{badge_color};font-weight:700">{active}</span>
<span class=dim>({enabled})</span></div>
<div style="margin-top:6px">{pass_html}</div>
<div style="margin-top:4px">{staleness}</div>
<form method=post action=/action style="margin-top:10px">
<button name=action value={toggle_action}>{toggle_label}</button>
</form>
</div>"""

def render_page(msg=""):
    return f"""<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1"><title>{DEVICE_LABEL} sat images</title><style>
body{{font-family:system-ui,sans-serif;background:#0e1116;color:#e6e9ef;margin:0;padding:16px;max-width:900px;margin:auto}}
h1{{font-size:20px}}a{{color:#f59e0b}}.hint,.dim{{color:#98a2b3;font-size:12.5px}}
.card{{background:#171d2b;border:1px solid #28303f;border-radius:10px;padding:12px 14px;margin:10px 0;font-size:14px}}
button{{background:#f59e0b;color:#0e1116;border:0;border-radius:8px;padding:8px 14px;font-size:13px;font-weight:700;cursor:pointer}}
.msg{{background:#1c2a1c;border:1px solid #2e5c2e;border-radius:8px;padding:8px 12px;margin-bottom:10px;font-size:13px}}
.grid{{display:flex;flex-wrap:wrap;gap:12px;margin-top:12px}}
.c{{background:#171d2b;border:1px solid #28303f;border-radius:10px;padding:8px;width:220px;cursor:pointer}}
.c img{{width:100%;border-radius:6px;display:block;background:#000}}
.c .n{{font-size:12px;color:#98a2b3;margin-top:6px}}.c .d{{font-size:11px;color:#5b6472}}
.lb{{position:fixed;inset:0;background:#000c;display:none;align-items:center;justify-content:center;z-index:5;padding:20px;cursor:zoom-out}}
.lb.open{{display:flex}}.lb img{{max-width:100%;max-height:100%;border-radius:6px}}
</style></head><body>
<h1>&#128752; Satellite Images <a href="/" style="font-size:13px;float:right">&larr; refresh</a></h1>
{f'<div class=msg>{msg}</div>' if msg else ''}
{status_html()}
<div class=hint id=st>loading&hellip;</div>
<div class=grid id=grid></div>
<div class=lb id=lb onclick="this.classList.remove('open')"><img id=lbimg></div>
<script>
fetch('/data/manifest.json').then(r=>r.json()).then(items=>{{
 const st=document.getElementById('st'),grid=document.getElementById('grid');
 if(!items.length){{st.textContent='no images captured yet.';return;}}
 st.textContent=items.length+' image(s) captured';
 grid.innerHTML=items.map(it=>`<div class=c onclick="openImg('${{it.file}}')"><img loading=lazy src="/data/${{it.file}}"><div class=n>${{it.satellite}}</div><div class=d>${{new Date(it.date).toLocaleString()}}</div></div>`).join('');
}}).catch(()=>{{document.getElementById('st').textContent='no images yet.';}});
function openImg(f){{document.getElementById('lbimg').src='/data/'+f;document.getElementById('lb').classList.add('open');}}
</script></body></html>"""

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=OUT_DIR, **kwargs)

    def log_message(self, *a):
        pass

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/" or parsed.path == "/index.html":
            body = render_page().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(body)
            return
        if parsed.path.startswith("/data/"):
            self.path = parsed.path[len("/data"):] or "/"
            return super().do_GET()
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        fields = urllib.parse.parse_qs(self.rfile.read(length).decode())
        action = fields.get("action", [""])[0]
        if action == "sat_on":
            subprocess.run(["systemctl", "enable", "--now", SERVICE_NAME], capture_output=True)
            msg = "Weather satellite auto-capture enabled."
        elif action == "sat_off":
            subprocess.run(["systemctl", "disable", "--now", SERVICE_NAME], capture_output=True)
            msg = "Weather satellite auto-capture disabled."
        else:
            msg = "unknown action"
        body = render_page(msg).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(body)

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True

if __name__ == "__main__":
    os.makedirs(OUT_DIR, exist_ok=True)
    srv = Server(("0.0.0.0", PORT), Handler)
    print("sat gallery server on :{}".format(PORT), flush=True)
    srv.serve_forever()
PY
chmod +x /usr/local/bin/satgallery-server.py
cat > /etc/systemd/system/prepperpi-satgallery.service <<'EOF'
[Unit]
Description=prepperpi weather satellite image gallery
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/satgallery-server.py
Restart=always
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now prepperpi-tle.timer >/dev/null 2>&1
systemctl enable --now prepperpi-satgallery >/dev/null 2>&1
# prepperpi-satsched.service is installed but deliberately NOT enabled here - it stops/starts
# the openwebrx container around every pass, which is wasted disruption with no antenna
# connected. Once the 137MHz antenna is up: sudo systemctl enable --now prepperpi-satsched
# --- web terminal (ttyd :7681, basic-auth = control password, shell as pi) ---
curl -fsSL -o /usr/local/bin/ttyd https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.aarch64 && chmod +x /usr/local/bin/ttyd || echo "!! grab ttyd manually"
TPW=$(grep -oE 'BT_PASS="[^"]*"' /etc/prepperpi/bt.conf | cut -d'"' -f2)
cat > /etc/systemd/system/prepperpi-terminal.service <<EOF
[Unit]
Description=prepperpi web terminal (ttyd :7681)
After=network.target
[Service]
User=pi
ExecStart=/usr/local/bin/ttyd -p 7681 -W -c prepperpi:${TPW} -t titleFixed=prepperpi -t fontSize=15 bash
Restart=always
[Install]
WantedBy=multi-user.target
EOF
systemctl enable prepperpi-terminal.service >/dev/null 2>&1
# --- network/speed/geo info tool ---
cat > /usr/local/bin/prepperpi-netinfo <<'NET'
#!/usr/bin/env bash
GEO=$(curl -fsS --max-time 5 "http://ip-api.com/json?fields=query,country,regionName,city,isp,lat,lon" 2>/dev/null)
val(){ echo "$GEO" | grep -oE "\"$1\":\"?[^,\"}]*" | sed -E "s/\"$1\":\"?//"; }
echo "-- Internet / public IP --"
if [ -n "$GEO" ] && echo "$GEO" | grep -q '"query"'; then
  echo "  public IP : $(val query)"
  echo "  location  : $(val city), $(val regionName), $(val country)"
  echo "  ISP       : $(val isp)"
  echo "  coords    : $(val lat),$(val lon)"
else
  echo "  (offline - no public IP / geolocation)"
fi
echo "-- Live link speed (1s sample) --"
for i in eth0 wlan0; do
  [ -d /sys/class/net/$i ] || continue
  r1=$(cat /sys/class/net/$i/statistics/rx_bytes); t1=$(cat /sys/class/net/$i/statistics/tx_bytes); sleep 1
  r2=$(cat /sys/class/net/$i/statistics/rx_bytes); t2=$(cat /sys/class/net/$i/statistics/tx_bytes)
  printf "  %-6s down %s Mbps  up %s Mbps\n" "$i" "$(awk "BEGIN{printf \"%.2f\",($r2-$r1)*8/1e6}")" "$(awk "BEGIN{printf \"%.2f\",($t2-$t1)*8/1e6}")"
done
NET
chmod +x /usr/local/bin/prepperpi-netinfo
# --- offline video library (yt-dlp) + separate-storage helper ---
mkdir -p /data/videos
cat > /etc/prepperpi/video-topics.list <<'LIST'
# one per line: a search query (top result) OR a channel/playlist URL (latest CHANNEL_MAX)
how to start a fire without matches survival
how to purify and filter water in the wild
how to build an emergency survival shelter
wilderness first aid basics
how to stop severe bleeding tourniquet first aid
edible wild plants foraging identification
essential survival knots tutorial
how to set snares and traps for food survival
how to catch fish survival methods
land navigation without a compass
food preservation canning and drying at home
bushcraft basics for beginners
emergency signaling for rescue
CPR how to perform step by step
how to splint a broken bone
how to grow vegetables from seed beginners
off grid solar power basics explained
how to make cordage and rope from plants
how to sharpen a knife properly
basic car and engine repair maintenance

# --- prepper channels (latest CHANNEL_MAX each; verify handles at download) ---
https://www.youtube.com/@CityPrepping/videos
https://www.youtube.com/@TheUrbanPrepper/videos
https://www.youtube.com/@SensiblePrepper/videos
LIST
cat > /usr/local/bin/prepperpi-getvideos <<'GV'
#!/usr/bin/env bash
# Download survival/skills videos into /data/videos. Search-query lines -> top result;
# http(s) lines -> channel/playlist (latest CHANNEL_MAX). PER_TOPIC / CHANNEL_MAX tunable.
set -u
DIR=/data/videos; mkdir -p "$DIR"
LIST="${1:-/etc/prepperpi/video-topics.list}"; N="${PER_TOPIC:-1}"; CMAX="${CHANNEL_MAX:-8}"
LOG=/var/log/prepperpi-videos.log; exec >>"$LOG" 2>&1
YDL=/usr/local/bin/yt-dlp
COMMON=(-f "bv*[height<=720]+ba/b[height<=720]/b" --merge-output-format mp4 \
  --download-archive "$DIR/.archive.txt" --no-overwrites --ignore-errors \
  --embed-metadata --embed-thumbnail --restrict-filenames \
  -o "$DIR/%(uploader)s/%(title).70s_[%(id)s].%(ext)s")
echo "===== $(date '+%F %T') getvideos N=$N CMAX=$CMAX ====="
while IFS= read -r line; do
  [ -z "$line" ] && continue; case "$line" in \#*) continue;; esac
  if [[ "$line" == http* ]]; then echo "--- channel: $line ---"; "$YDL" "$line" --playlist-end "$CMAX" "${COMMON[@]}"
  else echo "--- search: $line ---"; "$YDL" "ytsearch${N}:${line}" "${COMMON[@]}"; fi
done < "$LIST"
echo "===== done ($(find "$DIR" -name '*.mp4' 2>/dev/null | wc -l) videos) ====="
GV
chmod +x /usr/local/bin/prepperpi-getvideos
cat > /etc/systemd/system/prepperpi-videos.service <<'VSVC'
[Unit]
Description=prepperpi video library (:8082)
After=network.target
[Service]
ExecStart=/usr/bin/python3 -m http.server 8082 --directory /data/videos --bind 0.0.0.0
Restart=always
[Install]
WantedBy=multi-user.target
VSVC
systemctl enable prepperpi-videos.service >/dev/null 2>&1
# separate-storage helper: format+mount a USB stick/card at /data (all bulk content lives there)
cat > /usr/local/bin/prepperpi-storage <<'ST'
#!/usr/bin/env bash
# sudo prepperpi-storage /dev/sdX   -> ERASE that device, mount at /data for zim/videos/maps
set -e
DEV="${1:-}"
if [ ! -b "$DEV" ]; then
  echo "usage: sudo prepperpi-storage /dev/sdX (whole disk)"; echo "attached USB disks:"
  lsblk -dno NAME,SIZE,TRAN,MODEL | awk '$3=="usb"{print "  /dev/"$1"  "$2"  "$4}'; exit 1
fi
echo "This will ERASE $DEV ($(lsblk -dno SIZE,MODEL "$DEV")) and mount it at /data."
read -rp "Type ERASE to confirm: " ok; [ "$ok" = ERASE ] || { echo aborted; exit 1; }
umount "${DEV}"* 2>/dev/null || true
parted -s "$DEV" mklabel gpt mkpart primary ext4 0% 100%; sleep 2
PART="${DEV}1"; [ -b "${DEV}p1" ] && PART="${DEV}p1"
mkfs.ext4 -F -L PREPPERDATA "$PART"
mkdir -p /mnt/pdata; mount "$PART" /mnt/pdata
[ -d /data ] && cp -an /data/. /mnt/pdata/ 2>/dev/null || true
mkdir -p /mnt/pdata/zim /mnt/pdata/videos /mnt/pdata/maps; umount /mnt/pdata
sed -i '\#[[:space:]]/data[[:space:]]#d' /etc/fstab
echo "LABEL=PREPPERDATA /data ext4 defaults,nofail,x-systemd.device-timeout=15 0 2" >> /etc/fstab
systemctl daemon-reload; mount /data; mkdir -p /data/zim /data/videos /data/maps
systemctl restart kiwix-serve prepperpi-videos 2>/dev/null || true
echo "DONE: /data on $PART -> $(df -h /data | awk 'NR==2{print $2" total, "$4" free"}')"
ST
chmod +x /usr/local/bin/prepperpi-storage
# --- content-status + power-mode tools ---
cat > /usr/local/bin/prepperpi-content <<'CT'
#!/usr/bin/env bash
echo "-- Offline library (/data) --"
if ls /data/zim/*.zim >/dev/null 2>&1; then
  for z in /data/zim/*.zim; do printf "  %-40s %6s  got %s\n" "$(basename "$z"|cut -c1-40)" "$(du -h "$z"|cut -f1)" "$(date -r "$z" '+%Y-%m-%d')"; done
else echo "  ZIMs: none downloaded yet ($(grep -vcE '^#|^$' /etc/prepperpi/zim.list) queued)"; fi
echo "  videos: $(find /data/videos -name '*.mp4' 2>/dev/null | wc -l) files, $(du -sh /data/videos 2>/dev/null|cut -f1)"
echo "  free on /data: $(df -h /data|awk 'NR==2{print $4}')"
echo "-- Last refresh --"
[ -f /var/lib/prepperpi/last_update ] && echo "  update job: $(cat /var/lib/prepperpi/last_update)" || echo "  update job: never run"
if pgrep -f 'prepperpi-update.sh|yt-dlp' >/dev/null || pgrep -x wget >/dev/null; then echo "  status: >>> DOWNLOAD IN PROGRESS <<<"; else echo "  status: idle"; fi
CT
chmod +x /usr/local/bin/prepperpi-content
cat > /usr/local/bin/prepperpi-power <<'PW'
#!/usr/bin/env bash
# prepperpi-power low|full|status  — trade battery vs performance
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
MODE="${1:-status}"; FLAG=/etc/prepperpi/power-mode
gov(){ for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo "$1" > "$c" 2>/dev/null; done; }
case "$MODE" in
  low)  gov powersave; systemctl stop ollama 2>/dev/null; docker stop openwebrx 2>/dev/null
        echo low > "$FLAG"; echo "LOW POWER: cpu=powersave, LLM + web-SDR stopped (hotspot/library stay up)";;
  full) gov ondemand;  systemctl start ollama 2>/dev/null; docker start openwebrx 2>/dev/null
        echo full > "$FLAG"; echo "FULL POWER: cpu=ondemand, LLM + web-SDR running";;
  status)
        echo "  mode        : $(cat "$FLAG" 2>/dev/null || echo full)"
        echo "  cpu governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
        echo "  cpu temp    : $(vcgencmd measure_temp 2>/dev/null | cut -d= -f2 || echo n/a)"
        echo "  LLM (ollama): $(systemctl is-active ollama 2>/dev/null || echo not-installed)"
        echo "  web-SDR     : $(docker inspect -f '{{.State.Status}}' openwebrx 2>/dev/null || echo n/a)";;
esac
PW
chmod +x /usr/local/bin/prepperpi-power
cat > /usr/local/sbin/prepperpi-update.sh <<'SCRIPT'
#!/usr/bin/env bash
set -u; exec >>/var/log/prepperpi-update.log 2>&1
echo "===== $(date '+%F %T %Z') ====="; export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get -y upgrade && apt-get -y autoremove && apt-get clean
/usr/local/bin/yt-dlp -U || true
# offline-content refresh: each line "<subdir>/<basename>" -> fetch newest dated ZIM, prune old, restart kiwix
if [ -s /etc/prepperpi/zim.list ] && [ -d /data/zim ]; then
  B=https://download.kiwix.org/zim; got=0
  grep -vE '^\s*#|^\s*$' /etc/prepperpi/zim.list | while read -r e; do
    sub=${e%%/*}; pre=${e##*/}
    new=$(curl -fsSL "$B/$sub/" | grep -oE "${pre}_[0-9]{4}-[0-9]{2}\.zim" | sort -V | tail -1)
    [ -z "$new" ] && { echo "zim: no match for $e"; continue; }
    if [ ! -f "/data/zim/$new" ]; then
      echo "zim: fetching $new"
      if wget -q -O "/data/zim/.$new.part" "$B/$sub/$new"; then
        mv "/data/zim/.$new.part" "/data/zim/$new"
        find /data/zim -maxdepth 1 -name "${pre}_*.zim" ! -name "$new" -delete   # prune older
        got=1
      else rm -f "/data/zim/.$new.part"; fi
    fi
  done
  systemctl restart kiwix-serve 2>/dev/null || true
fi
mkdir -p /var/lib/prepperpi; date '+%F %T %Z' > /var/lib/prepperpi/last_update
SCRIPT
chmod +x /usr/local/sbin/prepperpi-update.sh
cat > /etc/systemd/system/prepperpi-update.service <<'EOF'
[Unit]
Description=prepperpi self-update
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
Nice=15
IOSchedulingClass=idle
ExecStart=/usr/local/sbin/prepperpi-update.sh
EOF
cat > /etc/systemd/system/prepperpi-update.timer <<'EOF'
[Unit]
Description=prepperpi daily self-update
[Timer]
OnCalendar=*-*-* 04:00:00
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now prepperpi-update.timer >/dev/null 2>&1

log "11/11  bring hotspot up now"
systemctl reload NetworkManager || true; sleep 2
rfkill unblock wifi 2>/dev/null || true
systemctl restart systemd-networkd; sleep 2
systemctl start prepperpi-nat.service
systemctl restart hostapd; sleep 2
systemctl restart dnsmasq

#--- Tailscale (needs interactive auth — do LAST, prints a URL) -----------------
log "Tailscale — install + auth"
if ! command -v tailscale >/dev/null; then curl -fsSL https://tailscale.com/install.sh | sh; fi
systemctl enable --now tailscaled
echo ">>> Run this yourself to join your tailnet (prints a login URL to approve):"
echo ">>>   sudo tailscale up --hostname=${HOSTNAME_SET} --ssh"

#===============================================================================
# OPTIONAL MODULES (big-card add-ons) — enable per run, e.g.:
#   sudo ENABLE_MAPS=1 ENABLE_LLM=1 ENABLE_WEBSDR=1 ENABLE_OPENAIP=1 OPENAIP_API_KEY=... bash prepperpi-provision.sh
#===============================================================================
if [ "${ENABLE_MAPS:-1}" = 1 ]; then    # ON by default; BIG (~3GB UK+Poland extract, ~25min) — skip with ENABLE_MAPS=0
  log "offline maps — pmtiles (UK+Poland) + local MapLibre viewer"
  PM=$(curl -fsSL https://api.github.com/repos/protomaps/go-pmtiles/releases/latest | grep -oE 'https://[^"]+Linux_arm64\.tar\.gz' | head -1)
  [ -n "$PM" ] && curl -fsSL "$PM" | tar xz -C /usr/local/bin pmtiles 2>/dev/null; chmod +x /usr/local/bin/pmtiles
  mkdir -p /data/maps /var/www/prepperpi/vendor /var/www/prepperpi/assets
  curl -fsSL -o /var/www/prepperpi/vendor/maplibre-gl.js  https://unpkg.com/maplibre-gl@4.7.1/dist/maplibre-gl.js
  curl -fsSL -o /var/www/prepperpi/vendor/maplibre-gl.css https://unpkg.com/maplibre-gl@4.7.1/dist/maplibre-gl.css
  curl -fsSL https://github.com/protomaps/basemaps-assets/archive/refs/heads/main.tar.gz | tar xz -C /tmp
  cp -r /tmp/basemaps-assets-main/fonts /var/www/prepperpi/assets/fonts; rm -rf /tmp/basemaps-assets-main
  cat > /var/www/prepperpi/map.html <<'HTML'
<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1"><title>prepperpi maps</title>
<link href=/vendor/maplibre-gl.css rel=stylesheet><script src=/vendor/maplibre-gl.js></script>
<style>html,body{margin:0;height:100%}#map{position:absolute;inset:0}
#bar{position:absolute;z-index:1;top:8px;left:8px;background:#171d2bcc;color:#e6e9ef;font:13px system-ui;padding:6px 10px;border-radius:8px}
#bar a{color:#f59e0b;text-decoration:none;margin-right:8px;cursor:pointer}</style></head><body>
<div id=bar><a href="/">&larr; home</a><a onclick="fly([-2,53.5],5.2)">UK</a><a onclick="fly([19,52],5.4)">Poland</a><a onclick="fly([10,30],2)">World</a></div>
<div id=map></div>
<script>
const O=location.origin.replace(/:\d+$/,'')+':8081';
const glyphs=location.origin+"/assets/fonts/{fontstack}/{range}.pbf";
function L(s,detail){return [
 {id:s+"e",type:"fill",source:s,"source-layer":"earth",paint:{"fill-color":"#e6e4df"}},
 {id:s+"lu",type:"fill",source:s,"source-layer":"landuse",paint:{"fill-color":"#d7e7c8","fill-opacity":.55}},
 {id:s+"w",type:"fill",source:s,"source-layer":"water",paint:{"fill-color":"#a7d3e2"}},
 {id:s+"rmin",type:"line",source:s,"source-layer":"roads",filter:["==","kind","minor_road"],paint:{"line-color":"#fff","line-width":["interpolate",["linear"],["zoom"],11,.4,16,3]}},
 {id:s+"rmaj",type:"line",source:s,"source-layer":"roads",filter:["==","kind","major_road"],paint:{"line-color":"#f6d9a6","line-width":["interpolate",["linear"],["zoom"],7,.6,16,5]}},
 {id:s+"rhwy",type:"line",source:s,"source-layer":"roads",filter:["==","kind","highway"],paint:{"line-color":"#f4a15a","line-width":["interpolate",["linear"],["zoom"],5,.8,16,7]}},
 {id:s+"bd",type:"line",source:s,"source-layer":"boundaries",paint:{"line-color":"#9d88ab","line-dasharray":[2,2],"line-width":["interpolate",["linear"],["zoom"],3,.5,8,1.2]}},
 {id:s+"b",type:"fill",source:s,"source-layer":"buildings",minzoom:14,paint:{"fill-color":"#dcd3ca"}},
 {id:s+"pl",type:"symbol",source:s,"source-layer":"places",maxzoom:detail?24:9,layout:{"text-field":["get","name"],"text-font":["Noto Sans Regular"],"text-size":["interpolate",["linear"],["zoom"],2,10,10,15]},paint:{"text-color":"#333","text-halo-color":"#fff","text-halo-width":1.4}}
];}
const src=(n,mz)=>({type:"vector",tiles:[O+"/"+n+"/{z}/{x}/{y}.mvt"],maxzoom:mz});
const map=new maplibregl.Map({container:"map",style:{version:8,glyphs,
 sources:{world:src("world",8),uk:src("uk",14),pl:src("poland",14)},
 layers:[{id:"bg",type:"background",paint:{"background-color":"#dfe6e8"}}].concat(L("world",false),L("uk",true),L("pl",true))},
 center:[-2,53.5],zoom:5});
map.addControl(new maplibregl.NavigationControl());
function fly(c,z){map.flyTo({center:c,zoom:z});}
</script></body></html>
HTML
  cat > /etc/systemd/system/prepperpi-maps.service <<'EOF'
[Unit]
Description=prepperpi map tiles (pmtiles serve :8081)
After=network.target
[Service]
ExecStart=/usr/local/bin/pmtiles serve /data/maps --port 8081 --cors=*
Restart=always
[Install]
WantedBy=multi-user.target
EOF
  systemctl enable --now prepperpi-maps.service
  B=$(for d in $(seq 0 10); do D=$(date -d "-$d day" +%Y%m%d); [ "$(curl -s -o /dev/null -r 0-0 -w '%{http_code}' https://build.protomaps.com/$D.pmtiles)" = "206" ] && echo $D && break; done)
  if [ -n "$B" ]; then SRC="https://build.protomaps.com/$B.pmtiles"
    # rough worldwide base (z8, ~500MB, SAFE). *** NEVER extract worldwide at high maxzoom ***
    # a z14 whole-world extract = 58M tiles and WILL lock up a Pi 4 (SD I/O saturation, sshd dies).
    pmtiles extract "$SRC" /data/maps/world.pmtiles --maxzoom=8
    pmtiles extract "$SRC" /data/maps/uk.pmtiles --bbox=-8.65,49.9,1.8,60.9 --maxzoom=14
    pmtiles extract "$SRC" /data/maps/poland.pmtiles --bbox=14.1,49.0,24.2,54.9 --maxzoom=14
    systemctl restart prepperpi-maps
  else echo "!! no protomaps build found — extract regions later"; fi
  echo ">>> MAPS at http://<pi>/map.html (UK+Poland). More regions: pmtiles extract <planet> /data/maps/<name>.pmtiles --bbox=W,S,E,N --maxzoom=14"
fi

if [ "${ENABLE_LLM:-1}" = 1 ]; then    # ON by default (disable with ENABLE_LLM=0)
  log "offline LLM — Ollama + model + Assistant chat page"
  command -v ollama >/dev/null || curl -fsSL https://ollama.com/install.sh | sh
  mkdir -p /etc/systemd/system/ollama.service.d
  printf '[Service]\nEnvironment="OLLAMA_HOST=0.0.0.0"\nEnvironment="OLLAMA_ORIGINS=*"\n' > /etc/systemd/system/ollama.service.d/override.conf
  systemctl daemon-reload; systemctl enable --now ollama 2>/dev/null || true
  ollama pull "${LLM_MODEL:-llama3.2:3b}" || echo "!! model pull needs internet once"
  cat > /var/www/prepperpi/assistant.html <<'HTML'
<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1"><title>prepperpi assistant</title><style>
body{font-family:system-ui,sans-serif;background:#0e1116;color:#e6e9ef;margin:0;padding:16px;max-width:680px;margin:auto}
h1{font-size:20px}a{color:#f59e0b}#log{margin:12px 0;display:flex;flex-direction:column;gap:8px}
.msg{padding:10px 12px;border-radius:10px;white-space:pre-wrap;font-size:14px;line-height:1.5}
.you{background:#f59e0b;color:#0e1116;align-self:flex-end;max-width:85%}
.ai{background:#171d2b;border:1px solid #28303f;align-self:flex-start;max-width:90%}
form{display:flex;gap:8px;position:sticky;bottom:0;background:#0e1116;padding:8px 0}
input{flex:1;padding:12px;border-radius:8px;border:1px solid #28303f;background:#171d2b;color:#e6e9ef}
button{background:#f59e0b;color:#0e1116;border:0;border-radius:8px;padding:12px 16px;font-weight:700}.hint{color:#98a2b3;font-size:12px}</style></head><body>
<h1>&#129302; prepperpi assistant <a href="/" style="font-size:13px;float:right">&larr; home</a></h1>
<div class=hint>Offline AI (llama3.2:3b). Runs on the Pi CPU &mdash; first reply ~90s (cold load), then a few words/sec.</div>
<div id=log></div><form id=f><input id=q placeholder="ask anything&hellip;" autocomplete=off><button>send</button></form>
<script>
const host=location.hostname, log=document.getElementById('log');
function add(w,t){const d=document.createElement('div');d.className='msg '+w;d.textContent=t;log.appendChild(d);d.scrollIntoView();return d;}
document.getElementById('f').onsubmit=async e=>{e.preventDefault();
  const q=document.getElementById('q').value.trim();if(!q)return;document.getElementById('q').value='';
  add('you',q);const out=add('ai','');
  try{const r=await fetch(`http://${host}:11434/api/generate`,{method:'POST',body:JSON.stringify({model:'llama3.2:3b',prompt:q,stream:true})});
    if(!r.ok){out.textContent='(model not ready yet)';return;}
    const rd=r.body.getReader(),dec=new TextDecoder();let buf='',txt='';
    for(;;){const{done,value}=await rd.read();if(done)break;buf+=dec.decode(value,{stream:true});let i;
      while((i=buf.indexOf('\n'))>=0){const l=buf.slice(0,i);buf=buf.slice(i+1);if(!l.trim())continue;
        try{const j=JSON.parse(l);if(j.response){txt+=j.response;out.textContent=txt;out.scrollIntoView();}}catch(e){}}}
  }catch(err){out.textContent='error: '+err;}};
</script></body></html>
HTML
  echo ">>> LLM ready. Assistant at http://<pi>/assistant.html  (slow on Pi CPU: ~90s cold, then a few tok/s; use llama3.2:1b for speed)"
fi

if [ "${ENABLE_WEBSDR:-1}" = 1 ]; then    # ON by default (disable with ENABLE_WEBSDR=0)
  log "web-SDR — OpenWebRX+ via Docker (browser radio at :8073 over the hotspot)"
  # Switched 2026-07-25 from mainline jketterl/openwebrx to the OpenWebRX+ community fork
  # (slechev/openwebrxplus-softmbe) — same underlying settings.json/bookmarks.json format (this
  # is a fork of the same codebase), but bundles far more decoders/panels out of the box: DMR,
  # D-Star, YSF, NXDN, TETRA, DRM, HFDL, VDL2, ACARS, POCSAG, SSTV, FAX, a CW skimmer, a wideband
  # spectrum view, and more. "softmbe" = software AMBE vocoding for the digital voice modes
  # (DMR/D-Star/YSF/NXDN), so no AMBE hardware dongle is needed.
  command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker 2>/dev/null || true
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  mkdir -p /opt/owrx-docker/var /opt/owrx-docker/etc /opt/owrx-docker/plugins
  chown -R 1000:1000 /opt/owrx-docker
  # Seed receiver info + SDR device/profiles + frequency bookmarks from this repo before first
  # start (the container only adds files that don't already exist, so this must happen first).
  [ -f "$SCRIPT_DIR/openwebrx/settings.json" ] && cp "$SCRIPT_DIR/openwebrx/settings.json" /opt/owrx-docker/var/settings.json
  [ -f "$SCRIPT_DIR/openwebrx/bookmarks.json" ] && cp "$SCRIPT_DIR/openwebrx/bookmarks.json" /opt/owrx-docker/var/bookmarks.json
  [ -f /opt/owrx-docker/var/settings.json ] && chown 1000:1000 /opt/owrx-docker/var/settings.json /opt/owrx-docker/var/bookmarks.json
  # Touch-friendly tuning controls (step up/down, scan to next/prev signal, bookmark auto-scan
  # toggle). NOT under a literal "static" folder - OwrxAssetsController's /static/<path> route
  # strips the "static/" prefix and resolves straight against the htdocs package root, so the
  # real on-disk location for a URL of /static/plugins/receiver/init.js is htdocs/plugins/receiver/init.js.
  # The existing plugins/ bind mount below is already the right one; init.js is auto-loaded by
  # the stock htdocs/plugins.js loader (Plugins.init() fetches static/plugins/{type}/init.js).
  mkdir -p /opt/owrx-docker/plugins/receiver
  [ -f "$SCRIPT_DIR/openwebrx/plugins.js" ] && cp "$SCRIPT_DIR/openwebrx/plugins.js" /opt/owrx-docker/plugins/receiver/init.js
  chown -R 1000:1000 /opt/owrx-docker/plugins
  if ! docker ps -a --format '{{.Names}}' | grep -qx openwebrx; then
    docker run -d --name openwebrx --restart unless-stopped \
      --device /dev/bus/usb --tmpfs=/tmp -p 8073:8073 \
      -v /opt/owrx-docker/var:/var/lib/openwebrx \
      -v /opt/owrx-docker/etc:/etc/openwebrx \
      -v /opt/owrx-docker/plugins:/usr/lib/python3/dist-packages/htdocs/plugins \
      -e TZ="${TIMEZONE}" \
      -e OPENWEBRX_ADMIN_USER=admin -e OPENWEBRX_ADMIN_PASSWORD="${BT_PASS}" \
      slechev/openwebrxplus-softmbe:latest
    sleep 8
  fi
  echo ">>> WEB-SDR: http://<pi>:8073 — login admin/<your BT_PASS>. Seeded 30 SDR profiles + 55 bookmarks from this repo."
fi

if [ "${ENABLE_OPENAIP:-0}" = 1 ]; then    # OFF by default (enable with ENABLE_OPENAIP=1 OPENAIP_API_KEY=...)
  log "OpenAIP airspace/navaid/airport data — monthly refresh, feeds the offline map.html viewer"
  if [ -z "${OPENAIP_API_KEY:-}" ]; then
    warn "ENABLE_OPENAIP=1 but no OPENAIP_API_KEY set — skipping. Register free at accounts.openaip.net."
  else
    mkdir -p /etc/prepperpi
    echo "OPENAIP_API_KEY=${OPENAIP_API_KEY}" > /etc/prepperpi/openaip.conf
    chmod 600 /etc/prepperpi/openaip.conf
    cat > /usr/local/bin/prepperpi-openaip-update <<'PYEOF'
#!/usr/bin/env python3
import json
import os
import urllib.request
import urllib.parse

CONFIG_FILE = "/etc/prepperpi/openaip.conf"
OUT_DIR = "/var/www/prepperpi/data/openaip"
BASE_URL = "https://api.core.openaip.net/api"
COUNTRIES = ["GB"]
CATEGORIES = ["airspaces", "navaids", "airports"]
LIMIT = 1000


def load_api_key():
    with open(CONFIG_FILE) as f:
        for line in f:
            line = line.strip()
            if line.startswith("OPENAIP_API_KEY="):
                return line.split("=", 1)[1].strip().strip('"')
    raise RuntimeError("OPENAIP_API_KEY not found in {}".format(CONFIG_FILE))


def fetch_all(category, country, api_key):
    features = []
    page = 1
    while True:
        params = urllib.parse.urlencode({"country": country, "limit": LIMIT, "page": page})
        # NB: urllib's default User-Agent gets a 403 from Cloudflare here — a curl-like UA passes.
        req = urllib.request.Request(
            "{}/{}?{}".format(BASE_URL, category, params),
            headers={"x-openaip-api-key": api_key, "User-Agent": "curl/8.5.0"},
        )
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.load(resp)
        for item in data["items"]:
            geometry = item.pop("geometry", None)
            if geometry is None:
                continue
            features.append({"type": "Feature", "geometry": geometry, "properties": item})
        if page >= data.get("totalPages", 1):
            break
        page += 1
    return {"type": "FeatureCollection", "features": features}


def write_atomic(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f)
    os.replace(tmp, path)


def main():
    api_key = load_api_key()
    os.makedirs(OUT_DIR, exist_ok=True)
    for country in COUNTRIES:
        for category in CATEGORIES:
            fc = fetch_all(category, country, api_key)
            out_path = os.path.join(OUT_DIR, "{}-{}.geojson".format(country.lower(), category))
            write_atomic(out_path, fc)
            print("{}: {} features -> {}".format(category, len(fc["features"]), out_path))


if __name__ == "__main__":
    main()
PYEOF
    chmod +x /usr/local/bin/prepperpi-openaip-update
    cat > /etc/systemd/system/prepperpi-openaip.service <<'EOF'
[Unit]
Description=prepperpi OpenAIP data refresh
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/prepperpi-openaip-update
Nice=15
IOSchedulingClass=idle
EOF
    cat > /etc/systemd/system/prepperpi-openaip.timer <<'EOF'
[Unit]
Description=Monthly prepperpi OpenAIP data refresh

[Timer]
OnCalendar=monthly
Persistent=true
RandomizedDelaySec=3600

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now prepperpi-openaip.timer
    systemctl start prepperpi-openaip.service
    echo ">>> OPENAIP: data at /var/www/prepperpi/data/openaip/*.geojson, refreshes monthly."
  fi
fi

if [ "${ENABLE_EINK:-0}" = 1 ]; then    # OFF by default (enable with ENABLE_EINK=1) — needs a Waveshare 4.2" e-Paper wired via SPI
  log "e-ink status display (Waveshare 4.2\" e-Paper) — WiFi QR code + live status"
  raspi-config nonint do_spi 0
  apt-get install -y -qq python3-spidev python3-gpiozero python3-pil python3-qrcode >/dev/null
  mkdir -p /opt/prepperpi-eink/waveshare_epd
  curl -fsSL -o /opt/prepperpi-eink/waveshare_epd/__init__.py https://raw.githubusercontent.com/waveshare/e-Paper/master/RaspberryPi_JetsonNano/python/lib/waveshare_epd/__init__.py
  curl -fsSL -o /opt/prepperpi-eink/waveshare_epd/epdconfig.py https://raw.githubusercontent.com/waveshare/e-Paper/master/RaspberryPi_JetsonNano/python/lib/waveshare_epd/epdconfig.py
  curl -fsSL -o /opt/prepperpi-eink/waveshare_epd/epd4in2_V2.py https://raw.githubusercontent.com/waveshare/e-Paper/master/RaspberryPi_JetsonNano/python/lib/waveshare_epd/epd4in2_V2.py
  # NB: this is V2 hardware's driver (epd4in2.py / non-V2 hangs forever waiting on BUSY due to
  # inverted polarity between the two hardware revisions) — if your panel is V1, swap this import.
  cat > /usr/local/bin/prepperpi-eink-status <<'EOF'
#!/usr/bin/env python3
import sys, json, time
sys.path.insert(0, '/opt/prepperpi-eink')
from waveshare_epd import epd4in2_V2
from PIL import Image, ImageDraw, ImageFont
import qrcode

AP_SSID = '__AP_SSID__'
AP_PASS = '__AP_PASS__'

def load_status():
    try:
        return json.load(open('/var/www/prepperpi/data/status.json'))
    except Exception:
        return {}

def fmt_gb(b):
    g = b / 1073741824
    return f'{g:.0f}' if g >= 100 else f'{g:.1f}'

def main():
    epd = epd4in2_V2.EPD()
    epd.init()

    s = load_status()
    img = Image.new('1', (epd.width, epd.height), 255)
    draw = ImageDraw.Draw(img)
    try:
        f_title = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf', 22)
        f_body = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf', 15)
        f_small = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf', 12)
    except Exception:
        f_title = f_body = f_small = ImageFont.load_default()

    draw.text((10, 8), 'PrepperPi', font=f_title, fill=0)
    draw.line((10, 36, epd.width - 10, 36), fill=0)

    wifi_qr = qrcode.make('WIFI:T:WPA;S:' + AP_SSID + ';P:' + AP_PASS + ';;', box_size=4, border=1)
    wifi_qr = wifi_qr.resize((150, 150))
    img.paste(wifi_qr, (10, 46))
    draw.text((10, 200), 'Scan to join WiFi', font=f_small, fill=0)
    draw.text((10, 216), 'SSID: ' + AP_SSID, font=f_small, fill=0)
    draw.text((10, 230), 'Pass: ' + AP_PASS, font=f_small, fill=0)

    x2 = 175
    draw.text((x2, 46), 'Status', font=f_body, fill=0)
    if s:
        free = fmt_gb(s.get('free', 0))
        total = fmt_gb(s.get('total', 0))
        lines = [
            free + ' GB free of ' + total + ' GB',
            str(s.get('clients', 0)) + ' WiFi client(s)',
            'Power: ' + str(s.get('mode', '?')),
            str(s.get('zims', 0)) + ' libraries, ' + str(s.get('videos', 0)) + ' videos',
            'Temp: ' + str(s.get('temp', '?')) + 'C',
            'Updated: ' + str(s.get('lastup', '?')),
        ]
    else:
        lines = ['status unavailable']
    y = 68
    for ln in lines:
        draw.text((x2, y), ln, font=f_small, fill=0)
        y += 16

    portal_qr = qrcode.make('http://192.168.50.1/', box_size=3, border=1)
    portal_qr = portal_qr.resize((90, 90))
    img.paste(portal_qr, (x2, y + 8))
    draw.text((x2 + 100, y + 8), 'Scan for', font=f_small, fill=0)
    draw.text((x2 + 100, y + 24), 'portal once', font=f_small, fill=0)
    draw.text((x2 + 100, y + 40), 'connected', font=f_small, fill=0)

    draw.text((10, epd.height - 16), time.strftime('%Y-%m-%d %H:%M'), font=f_small, fill=0)

    epd.display(epd.getbuffer(img))
    epd.sleep()

if __name__ == '__main__':
    main()
EOF
  sed -i "s|__AP_PASS__|${AP_PASS}|; s|__AP_SSID__|${AP_SSID}|" /usr/local/bin/prepperpi-eink-status
  chmod +x /usr/local/bin/prepperpi-eink-status
  cat > /etc/systemd/system/prepperpi-eink.service <<'EOF'
[Unit]
Description=prepperpi e-ink status display refresh
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/bin/prepperpi-eink-status
EOF
  cat > /etc/systemd/system/prepperpi-eink.timer <<'EOF'
[Unit]
Description=Refresh prepperpi e-ink display every 15 min
[Timer]
OnBootSec=1min
OnUnitActiveSec=15min
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now prepperpi-eink.timer
  echo ">>> E-INK: wire the 8 SPI pins per the wiring guide, VCC to 3.3V (NOT 5V). Manual refresh"
  echo ">>>         via the control panel (:8090) or: sudo systemctl start prepperpi-eink.service"
fi

if [ "${ENABLE_OVERMESH:-1}" = 1 ]; then    # ON by default (disable with ENABLE_OVERMESH=0)
  log "LoRa mesh — OverMesh (github.com/Slofi/overmesh), combined Meshtastic + MeshCore dashboard"
  # SUPERSEDES the old hand-rolled prepperpi-mesh-meshtastic/-meshcore split web interfaces
  # (removed 2026-07-25 — OverMesh covers both radio types in one app with more features:
  # node mapping, chat, route visualisation, bot integration, offline maps). If restoring from an
  # older backup, don't resurrect the old prepperpi-mesh-* services alongside this.
  PI_UID=$(id -u pi)
  PI_HOME=$(getent passwd pi | cut -d: -f6)
  if [ ! -d "$PI_HOME/overmesh" ]; then
    sudo -u pi git clone https://github.com/Slofi/overmesh.git "$PI_HOME/overmesh"
  fi
  sudo -u pi bash -c "cd '$PI_HOME/overmesh' && ./install.sh"
  # Default config.json port (8082) clashes with this build's Videos tile — move OverMesh to 8094.
  if [ -f "$PI_HOME/overmesh/config.json" ]; then
    sed -i 's/"port": 8082,/"port": 8094,/' "$PI_HOME/overmesh/config.json"
  fi
  # OverMesh installs as a per-user systemd service (not root) — needs linger enabled so it
  # keeps running headless without an active login session (easy to miss on a headless Pi).
  loginctl enable-linger pi
  sudo -u pi XDG_RUNTIME_DIR="/run/user/${PI_UID}" systemctl --user daemon-reload
  sudo -u pi XDG_RUNTIME_DIR="/run/user/${PI_UID}" systemctl --user enable --now overmesh
  echo ">>> OVERMESH: web UI at :8094 — add your Meshtastic/MeshCore radios from its own Settings"
  echo ">>>           page once attached (does not read the old /etc/prepperpi/mesh.conf)."
fi

if false; then    # kept for reference only — the old Meshtastic+MeshCore split, replaced by OverMesh above
  log "LoRa mesh — Meshtastic + MeshCore web interfaces (2x XIAO ESP32S3 & Wio-SX1262, USB-attached)"
  # Two boards, two firmwares (mutually exclusive per-device, not concurrent):
  #   - one stock Meshtastic node  -> talked to via the official 'meshtastic' PyPI library (serial)
  #   - one 'meshcomod' node (a MeshCore fork for Xiao S3 Wio, serial+BLE+TCP) -> the official
  #     'meshcore' PyPI library (async, serial transport used here since it's USB-attached)
  # NEITHER LIBRARY HAS BEEN TESTED AGAINST REAL HARDWARE YET (kits not delivered as of 2026-07-23)
  # — this is scaffolded against the published API/docs. Re-verify field names (esp. the MeshCore
  # contact dict shape used in send_text below) once a real device is attached.
  mkdir -p /opt/prepperpi-mesh /etc/prepperpi
  python3 -m venv /opt/prepperpi-mesh/venv 2>/dev/null || true
  /opt/prepperpi-mesh/venv/bin/pip install -q --upgrade pip
  /opt/prepperpi-mesh/venv/bin/pip install -q meshtastic meshcore

  # Stable device paths: with 2 USB-serial boards plugged in, /dev/ttyACM0 vs ttyACM1 ordering
  # isn't guaranteed across reboots. Once hardware is attached, identify each board's stable
  # /dev/serial/by-id/... path (encodes the USB serial number) and set it here.
  [ -f /etc/prepperpi/mesh.conf ] || cat > /etc/prepperpi/mesh.conf <<'EOF'
# Leave blank until hardware is attached and identified (see: prepperpi-mesh-identify).
# Use the stable /dev/serial/by-id/... path, NOT /dev/ttyACM0 (enumeration order isn't stable
# with two USB-serial boards plugged in at once).
MESHTASTIC_PORT=
MESHCORE_PORT=
EOF

  cat > /usr/local/bin/prepperpi-mesh-identify <<'EOF'
#!/usr/bin/env bash
echo "Stable USB-serial device paths (use these in /etc/prepperpi/mesh.conf):"
ls -la /dev/serial/by-id/ 2>/dev/null || echo "  none found — is a board plugged in?"
echo
echo "Raw enumeration (order not stable across reboots):"
ls -la /dev/ttyACM* /dev/ttyUSB* 2>/dev/null || echo "  none found"
EOF
  chmod +x /usr/local/bin/prepperpi-mesh-identify

  # --- Meshtastic web interface (:8093) ---
  cat > /usr/local/bin/prepperpi-mesh-meshtastic.py <<'PYEOF'
#!/usr/bin/env python3
import http.server, socketserver, base64, threading, time, collections, html as _html
PORT = 8093
LOG = collections.deque(maxlen=200)
LOG_LOCK = threading.Lock()
IFACE_LOCK = threading.Lock()
iface = None
STATUS = {"connected": False, "error": "starting up", "port": None}

def load_pass():
    try:
        for ln in open("/etc/prepperpi/bt.conf"):
            if ln.strip().startswith("BT_PASS="): return ln.split("=",1)[1].strip().strip('"').strip("'")
    except Exception: pass
    return None

def load_port():
    try:
        for ln in open("/etc/prepperpi/mesh.conf"):
            if ln.strip().startswith("MESHTASTIC_PORT="):
                v = ln.split("=",1)[1].strip().strip('"').strip("'")
                return v or None
    except Exception: pass
    return None

def on_receive(packet=None, interface=None, **kw):
    try:
        dec = packet.get("decoded", {}) or {}
        if dec.get("portnum") == "TEXT_MESSAGE_APP":
            frm = packet.get("fromId", packet.get("from", "?"))
            with LOG_LOCK:
                LOG.appendleft({"t": time.strftime("%H:%M:%S"), "from": str(frm), "text": dec.get("text", "")})
    except Exception:
        pass

def connect_loop():
    global iface
    import meshtastic, meshtastic.serial_interface
    from pubsub import pub
    pub.subscribe(on_receive, "meshtastic.receive")
    port = load_port()
    while True:
        try:
            with IFACE_LOCK:
                iface = meshtastic.serial_interface.SerialInterface(devPath=port)
            STATUS.update(connected=True, error=None, port=port or "auto-detect")
        except Exception as e:
            STATUS.update(connected=False, error=str(e))
            with IFACE_LOCK:
                iface = None
        time.sleep(20)  # re-check periodically; do_GET also self-heals STATUS on failed reads

threading.Thread(target=connect_loop, daemon=True).start()

def render_nodes():
    rows = []
    try:
        with IFACE_LOCK:
            nodes = dict(iface.nodes) if iface and iface.nodes else {}
        for nid, n in nodes.items():
            user = n.get("user", {}) or {}
            name = user.get("longName") or user.get("shortName") or nid
            last = n.get("lastHeard")
            last_s = time.strftime("%H:%M:%S", time.localtime(last)) if last else "-"
            batt = (n.get("deviceMetrics", {}) or {}).get("batteryLevel", "-")
            snr = n.get("snr", "-")
            rows.append(f"<tr><td>{_html.escape(str(name))}</td><td>{_html.escape(str(nid))}</td><td>{last_s}</td><td>{batt}</td><td>{snr}</td></tr>")
    except Exception as e:
        STATUS["connected"] = False; STATUS["error"] = str(e)
    return "".join(rows) or "<tr><td colspan=5>no nodes seen yet</td></tr>"

def render_log():
    with LOG_LOCK:
        items = list(LOG)
    if not items: return "<p style='color:#98a2b3'>no messages yet</p>"
    return "".join(f"<div class=card style='margin:6px 0;padding:8px 10px'><b>{_html.escape(m['from'])}</b> <span style='color:#98a2b3;font-size:11px'>{m['t']}</span><br>{_html.escape(m['text'])}</div>" for m in items)

PAGE = """<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1"><title>prepperpi meshtastic</title><style>
body{font-family:system-ui,sans-serif;background:#0e1116;color:#e6e9ef;margin:0;padding:16px;max-width:680px;margin:auto}
h1{font-size:20px}a{color:#f59e0b}table{width:100%;border-collapse:collapse;font-size:13px}
td,th{padding:6px 8px;border-bottom:1px solid #28303f;text-align:left}
.card{background:#171d2b;border:1px solid #28303f;border-radius:10px;padding:14px}
input,button{padding:10px;border-radius:8px;border:1px solid #28303f;background:#0e1116;color:#e6e9ef;box-sizing:border-box}
button{background:#f59e0b;color:#0e1116;border:0;font-weight:700;width:100%;margin-top:6px}
</style></head><body>
<h1>&#128225; Meshtastic <a href="/" style="font-size:13px;float:right">&larr; home</a></h1>
<div class=card><b>Status:</b> __STATUS__</div>
<div class=card style="margin-top:12px"><b>Nodes</b><table><tr><th>Name</th><th>ID</th><th>Last heard</th><th>Batt%</th><th>SNR</th></tr>__NODES__</table></div>
<div class=card style="margin-top:12px"><b>Send message</b><form method=post action=/send>
<input name=text placeholder="message text" style="width:100%;margin:6px 0">
<input name=dest placeholder="dest node ID, blank = broadcast (^all)" style="width:100%;margin:6px 0">
<button>Send</button></form></div>
<div style="margin-top:12px"><b>Recent messages</b>__LOG__</div>
</body></html>"""

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def auth(self):
        pw = load_pass()
        if not pw: return True
        h = self.headers.get("Authorization", "")
        if h.startswith("Basic "):
            try:
                _, p = base64.b64decode(h[6:]).decode().split(":", 1)
                if p == pw: return True
            except Exception: pass
        self.send_response(401); self.send_header("WWW-Authenticate", 'Basic realm="prepperpi"'); self.end_headers(); return False
    def do_GET(self):
        if not self.auth(): return
        st = f"connected on {STATUS['port']}" if STATUS["connected"] else f"NOT CONNECTED ({STATUS['error']})"
        b = PAGE.replace("__STATUS__", st).replace("__NODES__", render_nodes()).replace("__LOG__", render_log()).encode()
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        if not self.auth(): return
        import urllib.parse
        n = int(self.headers.get("Content-Length", 0)); f = urllib.parse.parse_qs(self.rfile.read(n).decode())
        text = f.get("text", [""])[0]; dest = f.get("dest", [""])[0].strip() or "^all"
        msg = "sent"
        try:
            with IFACE_LOCK:
                if not iface: raise RuntimeError("not connected")
                iface.sendText(text, destinationId=dest)
        except Exception as e:
            msg = f"error: {e}"
        b = f"<!doctype html><meta charset=utf-8><body style='font-family:system-ui;background:#0e1116;color:#e6e9ef;padding:16px'><p>{_html.escape(msg)}</p><a style='color:#f59e0b' href='/'>&larr; back</a></body>".encode()
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers(); self.wfile.write(b)

srv = socketserver.ThreadingTCPServer(("0.0.0.0", PORT), H); srv.allow_reuse_address = True
print(f"prepperpi meshtastic web interface on :{PORT}", flush=True); srv.serve_forever()
PYEOF
  chmod +x /usr/local/bin/prepperpi-mesh-meshtastic.py
  cat > /etc/systemd/system/prepperpi-mesh-meshtastic.service <<EOF
[Unit]
Description=prepperpi Meshtastic web interface (:8093)
After=network.target
[Service]
ExecStart=/opt/prepperpi-mesh/venv/bin/python3 /usr/local/bin/prepperpi-mesh-meshtastic.py
Restart=always
[Install]
WantedBy=multi-user.target
EOF
  systemctl enable prepperpi-mesh-meshtastic.service >/dev/null 2>&1

  # --- MeshCore (meshcomod) web interface (:8094) ---
  cat > /usr/local/bin/prepperpi-mesh-meshcore.py <<'PYEOF'
#!/usr/bin/env python3
import http.server, socketserver, base64, threading, time, collections, asyncio, json, os, html as _html
PORT = 8094
LOG = collections.deque(maxlen=5000)
LOG_LOCK = threading.Lock()
STATE_LOCK = threading.Lock()
STATE = {"connected": False, "error": "starting up", "port": None, "contacts": [], "channels": []}
CHANNEL_SCAN_RANGE = 8  # MeshCore channel slots to check; unused slots come back with an empty name
LOOP = None
MESHCORE = None

# Message persistence: survives restarts. The "Public" channel is high-traffic/low-value long
# term (open broadcast channel) so it gets auto-wiped after PUBLIC_RETENTION_SECS; every other
# channel (Family, #emergency, custom ones) and all direct messages are kept indefinitely.
LOG_FILE = "/var/lib/prepperpi/meshcore-log.jsonl"
PUBLIC_CHANNEL_NAME = "Public"
PUBLIC_RETENTION_SECS = 7 * 86400

def _load_log():
    try:
        with open(LOG_FILE) as f:
            items = [json.loads(ln) for ln in f if ln.strip()]
        with LOG_LOCK:
            LOG.extend(reversed(items))  # file is oldest-first; LOG wants newest-first (index 0)
    except FileNotFoundError:
        pass
    except Exception:
        pass

def _append_log(entry):
    entry["ts"] = time.time()
    with LOG_LOCK:
        LOG.appendleft(entry)
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except Exception:
        pass

def _cleanup_log():
    cutoff = time.time() - PUBLIC_RETENTION_SECS
    with LOG_LOCK:
        kept = [m for m in LOG if not (m.get("from") == PUBLIC_CHANNEL_NAME and m.get("ts", 0) < cutoff)]
        LOG.clear()
        LOG.extend(kept)
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, "w") as f:
            for m in reversed(kept):
                f.write(json.dumps(m) + "\n")
    except Exception:
        pass

_load_log()

def load_pass():
    try:
        for ln in open("/etc/prepperpi/bt.conf"):
            if ln.strip().startswith("BT_PASS="): return ln.split("=",1)[1].strip().strip('"').strip("'")
    except Exception: pass
    return None

def load_port():
    try:
        for ln in open("/etc/prepperpi/mesh.conf"):
            if ln.strip().startswith("MESHCORE_PORT="):
                v = ln.split("=",1)[1].strip().strip('"').strip("'")
                return v or None
    except Exception: pass
    return None

def _channel_name(idx):
    with STATE_LOCK:
        for ch in STATE.get("channels") or []:
            if ch.get("channel_idx") == idx: return ch.get("channel_name") or f"#{idx}"
    return f"#{idx}"

async def on_msg(event):
    try:
        d = event.payload or {}
        _append_log({"t": time.strftime("%H:%M:%S"), "from": str(d.get("pubkey_prefix", "?")), "text": d.get("text", ""), "chan": None})
    except Exception:
        pass

async def on_chan_msg(event):
    try:
        d = event.payload or {}
        idx = d.get("channel_idx")
        _append_log({"t": time.strftime("%H:%M:%S"), "from": _channel_name(idx), "text": d.get("text", ""), "chan": idx})
    except Exception:
        pass

async def refresh_contacts(meshcore_mod):
    global MESHCORE
    try:
        res = await MESHCORE.commands.get_contacts()
        if res.type != meshcore_mod.EventType.ERROR:
            with STATE_LOCK:
                STATE["contacts"] = list((res.payload or {}).values()) if isinstance(res.payload, dict) else (res.payload or [])
    except Exception as e:
        with STATE_LOCK:
            STATE["error"] = str(e)

async def refresh_channels(meshcore_mod):
    global MESHCORE
    try:
        found = []
        for i in range(CHANNEL_SCAN_RANGE):
            res = await MESHCORE.commands.get_channel(i)
            if res.type == meshcore_mod.EventType.ERROR:
                continue
            payload = res.payload or {}
            if payload.get("channel_name"):
                found.append({"channel_idx": payload.get("channel_idx", i), "channel_name": payload.get("channel_name")})
        with STATE_LOCK:
            STATE["channels"] = found
    except Exception as e:
        with STATE_LOCK:
            STATE["error"] = str(e)

async def connect_and_run():
    global MESHCORE
    import meshcore as meshcore_mod
    from meshcore import MeshCore, EventType
    port = load_port()
    if not port:
        with STATE_LOCK:
            STATE.update(connected=False, error="MESHCORE_PORT not set in /etc/prepperpi/mesh.conf — run prepperpi-mesh-identify")
        return
    while True:
        try:
            MESHCORE = await MeshCore.create_serial(port, auto_reconnect=True, cx_dly=3.0)
            MESHCORE.subscribe(EventType.CONTACT_MSG_RECV, on_msg)
            MESHCORE.subscribe(EventType.CHANNEL_MSG_RECV, on_chan_msg)
            await refresh_channels(meshcore_mod)
            with STATE_LOCK:
                STATE.update(connected=True, error=None, port=port)
            while True:
                await refresh_contacts(meshcore_mod)
                await refresh_channels(meshcore_mod)
                _cleanup_log()
                await asyncio.sleep(60)
        except Exception as e:
            with STATE_LOCK:
                STATE.update(connected=False, error=str(e))
            await asyncio.sleep(15)

def start_loop():
    global LOOP
    LOOP = asyncio.new_event_loop()
    asyncio.set_event_loop(LOOP)
    LOOP.create_task(connect_and_run())
    LOOP.run_forever()

threading.Thread(target=start_loop, daemon=True).start()

def render_contacts():
    with STATE_LOCK:
        contacts = list(STATE.get("contacts") or [])
    if not contacts: return "<tr><td colspan=2>no contacts yet</td></tr>"
    if isinstance(contacts, dict): contacts = list(contacts.values())
    rows = []
    for c in contacts:
        # NOTE: field names are best-effort from the published docs, unverified against real
        # hardware yet (see header note in the provisioning script) — adjust once testable.
        name = c.get("adv_name") or c.get("name") or "?"
        pk = c.get("public_key") or c.get("pubkey_prefix") or "?"
        rows.append(f"<tr><td>{_html.escape(str(name))}</td><td>{_html.escape(str(pk))}</td></tr>")
    return "".join(rows)

def render_channels():
    with STATE_LOCK:
        channels = list(STATE.get("channels") or [])
    if not channels: return "<tr><td colspan=2>no channels configured on this device</td></tr>"
    rows = []
    for ch in channels:
        rows.append(f"<tr><td>{ch['channel_idx']}</td><td>{_html.escape(str(ch['channel_name']))}</td></tr>")
    return "".join(rows)

def render_channel_options():
    with STATE_LOCK:
        channels = list(STATE.get("channels") or [])
    return "".join(f"<option value={ch['channel_idx']}>{_html.escape(str(ch['channel_name']))}</option>" for ch in channels)

def render_log():
    with LOG_LOCK:
        items = list(LOG)
    if not items: return "<p style='color:#98a2b3'>no messages yet</p>"
    return "".join(f"<div class=card style='margin:6px 0;padding:8px 10px'><b>{_html.escape(m['from'])}</b>{' <span style=\"color:#f59e0b;font-size:11px\">[channel]</span>' if m.get('chan') is not None else ''} <span style='color:#98a2b3;font-size:11px'>{m['t']}</span><br>{_html.escape(m['text'])}</div>" for m in items)

def send_text(text, contact_name):
    async def _send():
        from meshcore import EventType
        with STATE_LOCK:
            contacts = list(STATE.get("contacts") or [])
        contact = None
        for c in contacts:
            if str(c.get("adv_name") or c.get("name") or "") == contact_name:
                contact = c; break
        if contact is None and contacts:
            contact = contacts[0]
        if contact is None:
            raise RuntimeError("no contacts known yet")
        res = await MESHCORE.commands.send_msg(contact, text)
        if res.type == EventType.ERROR:
            raise RuntimeError(str(res.payload))
    fut = asyncio.run_coroutine_threadsafe(_send(), LOOP)
    fut.result(timeout=15)

def send_channel(text, chan_idx):
    async def _send():
        from meshcore import EventType
        res = await MESHCORE.commands.send_chan_msg(int(chan_idx), text)
        if res.type == EventType.ERROR:
            raise RuntimeError(str(res.payload))
    fut = asyncio.run_coroutine_threadsafe(_send(), LOOP)
    fut.result(timeout=15)

PAGE = """<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1"><title>prepperpi meshcore</title><style>
body{font-family:system-ui,sans-serif;background:#0e1116;color:#e6e9ef;margin:0;padding:16px;max-width:680px;margin:auto}
h1{font-size:20px}a{color:#f59e0b}table{width:100%;border-collapse:collapse;font-size:13px}
td,th{padding:6px 8px;border-bottom:1px solid #28303f;text-align:left}
.card{background:#171d2b;border:1px solid #28303f;border-radius:10px;padding:14px}
input,button{padding:10px;border-radius:8px;border:1px solid #28303f;background:#0e1116;color:#e6e9ef;box-sizing:border-box}
button{background:#f59e0b;color:#0e1116;border:0;font-weight:700;width:100%;margin-top:6px}
</style></head><body>
<h1>&#128272; MeshCore <a href="/" style="font-size:13px;float:right">&larr; home</a></h1>
<div class=card><b>Status:</b> __STATUS__</div>
<div class=card style="margin-top:12px"><b>Channels</b><table><tr><th>#</th><th>Name</th></tr>__CHANNELS__</table></div>
<div class=card style="margin-top:12px"><b>Send to channel</b><form method=post action=/send_channel>
<select name=chan style="width:100%;padding:10px;margin:6px 0;border-radius:8px;border:1px solid #28303f;background:#0e1116;color:#e6e9ef">__CHANOPTS__</select>
<input name=text placeholder="message text" style="width:100%;margin:6px 0">
<button>Send to channel</button></form></div>
<div class=card style="margin-top:12px"><b>Contacts</b><table><tr><th>Name</th><th>Public key</th></tr>__CONTACTS__</table></div>
<div class=card style="margin-top:12px"><b>Send direct message</b><form method=post action=/send>
<input name=text placeholder="message text" style="width:100%;margin:6px 0">
<input name=contact placeholder="contact name, blank = first known contact" style="width:100%;margin:6px 0">
<button>Send</button></form></div>
<div style="margin-top:12px"><b>Recent messages</b>__LOG__</div>
</body></html>"""

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def auth(self):
        pw = load_pass()
        if not pw: return True
        h = self.headers.get("Authorization", "")
        if h.startswith("Basic "):
            try:
                _, p = base64.b64decode(h[6:]).decode().split(":", 1)
                if p == pw: return True
            except Exception: pass
        self.send_response(401); self.send_header("WWW-Authenticate", 'Basic realm="prepperpi"'); self.end_headers(); return False
    def do_GET(self):
        if not self.auth(): return
        st = f"connected on {STATE['port']}" if STATE["connected"] else f"NOT CONNECTED ({STATE['error']})"
        b = (PAGE.replace("__STATUS__", st).replace("__CONTACTS__", render_contacts())
             .replace("__CHANNELS__", render_channels()).replace("__CHANOPTS__", render_channel_options())
             .replace("__LOG__", render_log())).encode()
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        if not self.auth(): return
        import urllib.parse
        n = int(self.headers.get("Content-Length", 0)); f = urllib.parse.parse_qs(self.rfile.read(n).decode())
        msg = "sent"
        try:
            if self.path == "/send_channel":
                text = f.get("text", [""])[0]; chan = f.get("chan", ["0"])[0]
                send_channel(text, chan)
            else:
                text = f.get("text", [""])[0]; contact = f.get("contact", [""])[0].strip()
                send_text(text, contact)
        except Exception as e:
            msg = f"error: {e}"
        b = f"<!doctype html><meta charset=utf-8><body style='font-family:system-ui;background:#0e1116;color:#e6e9ef;padding:16px'><p>{_html.escape(msg)}</p><a style='color:#f59e0b' href='/'>&larr; back</a></body>".encode()
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers(); self.wfile.write(b)

srv = socketserver.ThreadingTCPServer(("0.0.0.0", PORT), H); srv.allow_reuse_address = True
print(f"prepperpi meshcore web interface on :{PORT}", flush=True); srv.serve_forever()
PYEOF
  chmod +x /usr/local/bin/prepperpi-mesh-meshcore.py
  cat > /etc/systemd/system/prepperpi-mesh-meshcore.service <<EOF
[Unit]
Description=prepperpi MeshCore (meshcomod) web interface (:8094)
After=network.target
[Service]
ExecStart=/opt/prepperpi-mesh/venv/bin/python3 /usr/local/bin/prepperpi-mesh-meshcore.py
Restart=always
[Install]
WantedBy=multi-user.target
EOF
  systemctl enable prepperpi-mesh-meshcore.service >/dev/null 2>&1

  echo ">>> MESH: after plugging in both boards, run 'prepperpi-mesh-identify', set MESHTASTIC_PORT/"
  echo ">>>       MESHCORE_PORT in /etc/prepperpi/mesh.conf to the stable /dev/serial/by-id/... paths,"
  echo ">>>       then: sudo systemctl restart prepperpi-mesh-meshtastic prepperpi-mesh-meshcore"
  echo ">>>       UNTESTED against real hardware — verify node/contact field names once attached."
fi

echo
log "DONE.  Verify:  prepperpi-info   |   hotspot SSID '${AP_SSID}' pass '${AP_PASS}'"
echo "Services: kiwix :8080 | (opt) maps :8081 | (opt) web-SDR :8073"
echo "512GB TODO: ZIMs auto-download from /etc/prepperpi/zim.list on the update timer; add maps to /data/maps; optionally ENABLE_MAPS/LLM/WEBSDR=1."
