#!/usr/bin/env bash
# ThroneDPI'yi tamamen kaldırır ve ağ ayarlarını normale döndürür.
#
#   ./uninstall.sh
#
# sing-box'ı kaldırmaz (başka işler için kullanıyor olabilirsiniz).
# İsterseniz:  brew uninstall sing-box

set -uo pipefail

BIN="/usr/local/bin/dpi"
ETC_DIR="/usr/local/etc/thronedpi"
PLIST="/Library/LaunchDaemons/dpi.singbox.tun.plist"
LOG="/var/log/singbox-dpi.log"
LABEL="dpi.singbox.tun"

log()  { printf '\033[1;34m[kaldir]\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

[[ "$(uname -s)" == "Darwin" ]] || { echo "Yalnızca macOS." >&2; exit 1; }

log "1/4  Hizmet durduruluyor"
if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
    sudo launchctl bootout "system/${LABEL}" 2>/dev/null && ok "durduruldu" || warn "durdurulamadı"
else
    ok "zaten çalışmıyordu"
fi
sudo rm -f "$PLIST" 2>/dev/null && ok "plist silindi" || true

# Arta kalan süreç
while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    sudo kill -9 "$pid" 2>/dev/null && warn "arta kalan süreç öldürüldü: $pid"
done <<< "$(pgrep -f 'sing-box run -c .*thronedpi\|sing-box run -c .*tun.json' 2>/dev/null || true)"

log "2/4  DNS DHCP'ye döndürülüyor"
# Kurulum DNS'i 1.1.1.1'e sabitliyor; bırakmadan temizliyoruz, yoksa
# ThroneDPI kapalıyken engelli adlar çözülemez.
n=0
while IFS= read -r svc; do
    [[ -n "$svc" ]] || continue
    sudo /usr/sbin/networksetup -setdnsservers "$svc" Empty >/dev/null 2>&1 && n=$(( n + 1 ))
done <<< "$(/usr/sbin/networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | grep -v '^\*' || true)"
sudo /usr/bin/dscacheutil -flushcache 2>/dev/null || true
sudo /usr/bin/killall -HUP mDNSResponder 2>/dev/null || true
ok "${n} servis DHCP'ye döndürüldü"

log "3/4  Dosyalar siliniyor"
for p in "$BIN" "$ETC_DIR" "$LOG"; do
    [[ -e "$p" ]] && { sudo rm -rf "$p" && ok "silindi: $p"; }
done

log "4/4  Doğrulama"
fail=0
[[ -e "$BIN" ]]   && { warn "hâlâ var: $BIN"; fail=1; }   || ok "komut kaldırıldı"
[[ -e "$PLIST" ]] && { warn "hâlâ var: $PLIST"; fail=1; } || ok "plist yok"
if route -n get 1.1.1.1 2>/dev/null | grep -q 'interface: utun'; then
    warn "varsayılan rota hâlâ utun üzerinde (başka bir VPN olabilir)"
else
    ok "varsayılan rota normal: $(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}')"
fi
r=$(dig +short +time=5 example.com A 2>/dev/null | head -1)
[[ "$r" =~ ^[0-9]+\. ]] && ok "DNS çalışıyor ($r)" || { warn "DNS cevap vermiyor"; fail=1; }

echo
if (( fail == 0 )); then
    printf '\033[1;32m[kaldir] ThroneDPI kaldırıldı.\033[0m\n'
else
    printf '\033[1;31m[kaldir] Bazı maddeler kaldı, yukarıya bakın.\033[0m\n'; exit 1
fi
echo "sing-box duruyor. Onu da silmek isterseniz:  brew uninstall sing-box"
