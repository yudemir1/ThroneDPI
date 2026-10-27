#!/usr/bin/env bash
# sing-box TUN modunu aç / kapa / durumunu gör.
#
# Windows'taki GoodbyeDPI gibi davranır: tek yerden açılır ve istisnasız TÜM
# uygulamaları kapsar (Discord, Roblox, oyunlar, terminal). Uygulama başına
# proxy ayarı gerekmez, çünkü trafik sanal bir ağ arayüzünden (TUN) geçer.
#
# Neden SOCKS proxy değil: macOS'ta sistem SOCKS ayarını yalnızca onu okumayı
# seçen uygulamalar kullanır. Roblox kendi libcurl yığınıyla doğrudan bağlanır,
# terminal araçları ayarı hiç okumaz. TUN'da böyle bir seçim yok.
#
# Gereksinim:  brew install sing-box
#
# Kullanım:
#   sudo ./dpi.sh on       # aç
#   sudo ./dpi.sh off      # kapa
#        ./dpi.sh status   # durum (sudo gerekmez)
#        ./dpi.sh test     # engelli siteleri dene (sudo gerekmez)

set -uo pipefail

# Script'in gerçek bulunduğu dizin. Kurulumda /usr/local/bin/dpi olarak
# kopyalandığı ya da symlink'lendiği için dirname tek başına yetmez.
resolve_self() {
    local src="${BASH_SOURCE[0]}" dir
    while [[ -L "$src" ]]; do
        dir="$(cd -P "$(dirname "$src")" && pwd)"
        src="$(readlink "$src")"
        [[ "$src" != /* ]] && src="${dir}/${src}"
    done
    printf '%s/%s' "$(cd -P "$(dirname "$src")" && pwd)" "$(basename "$src")"
}
SELF="$(resolve_self)"
HERE="$(dirname "$SELF")"

# Yapılandırmayı sırayla ara: açık env > script'in yanı > kurulum yeri.
# Böylece hem depodan doğrudan çalıştırılabilir hem de kurulduktan sonra
# depo klasörü silinse bile çalışmaya devam eder.
CONFIG=""
for _c in "${THRONEDPI_CONFIG:-}" "${HERE}/tun.json" "/usr/local/etc/thronedpi/tun.json"; do
    if [[ -n "$_c" && -f "$_c" ]]; then CONFIG="$_c"; break; fi
done
[[ -n "$CONFIG" ]] || CONFIG="/usr/local/etc/thronedpi/tun.json"

LABEL="dpi.singbox.tun"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
LOG="/var/log/singbox-dpi.log"

# Watchdog: sing-box uyku/uyanma ve ağ değişimlerinde varsayılan rotayı
# kaybedebiliyor ("network: missing default interface"). Süreç ayakta kalır,
# utun arayüzü de durur, ama varsayılan rota fiziksel arayüze döner ve bypass
# sessizce devre dışı kalır. Periyodik bir kontrol bunu yakalayıp onarır.
WD_LABEL="dpi.singbox.watchdog"
WD_PLIST="/Library/LaunchDaemons/${WD_LABEL}.plist"
WD_INTERVAL="${WD_INTERVAL:-60}"
SINGBOX="${SINGBOX:-$(command -v sing-box || echo /opt/homebrew/bin/sing-box)}"

log()  { printf '\033[1;34m[dpi]\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[dpi]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

need_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Bunun için root gerekiyor:  sudo $0 $1"
}

# Etkin ağ servisleri (başlık satırı ve "*" ile devre dışı olanlar hariç).
services() {
    /usr/sbin/networksetup -listallnetworkservices 2>/dev/null \
        | tail -n +2 | grep -v '^\*' || true
}

flush_dns() {
    /usr/bin/dscacheutil -flushcache 2>/dev/null || true
    /usr/bin/killall -HUP mDNSResponder 2>/dev/null || true
}

# TUN tek başına DNS'i kurtarmaya yetmiyor.
#
# macOS, DHCP'den gelen IPv6 link-local resolver'ı (fe80::...%en0) tercih
# ediyor. Link-local trafik tanımı gereği yönlendirilmez — doğrudan fiziksel
# arayüzden çıkar, TUN'a hiç uğramaz. Dolayısıyla hijack-dns o sorguları
# göremez ve ISS'in sinkhole cevabı (195.175.254.2) geri döner.
#
# Çözüm: DNS'i TUN üzerinden giden bir IPv4 adrese sabitlemek. Oraya giden
# sorgu TUN'a girer, hijack-dns yakalar, sing-box DoH ile cevaplar.
# 1.1.1.1 seçildi çünkü sing-box bir şekilde ölürse düz DNS olarak da
# çalışmaya devam eder (engelli adlar hariç) — internet tamamen kesilmez.
DNS_PIN="${DNS_PIN:-1.1.1.1}"

install_watchdog() {
    cat > "$WD_PLIST" <<WD_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${WD_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${SELF}</string>
        <string>_watchdog</string>
    </array>
    <key>StartInterval</key>
    <integer>${WD_INTERVAL}</integer>
    <key>RunAtLoad</key>
    <false/>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
WD_EOF
    chown root:wheel "$WD_PLIST"; chmod 0644 "$WD_PLIST"
    launchctl bootout "system/${WD_LABEL}" 2>/dev/null || true
    if launchctl bootstrap system "$WD_PLIST" 2>/dev/null; then
        ok "watchdog açık (her ${WD_INTERVAL}s kontrol)"
    else
        warn "watchdog kurulamadı; TUN kendini onarmaz"
    fi
}

remove_watchdog() {
    if launchctl print "system/${WD_LABEL}" >/dev/null 2>&1; then
        launchctl bootout "system/${WD_LABEL}" 2>/dev/null || true
    fi
    if [[ -f "$WD_PLIST" ]]; then
        rm -f "$WD_PLIST"
        ok "watchdog kaldırıldı"
    fi
    return 0
}

# launchd tarafından periyodik çağrılır. Sessizdir; yalnızca onarım yaparsa
# sistem günlüğüne yazar (Console.app'te "thronedpi" aratın).
cmd_watchdog() {
    # dpi off yapılmışsa plist yoktur: kullanıcının kararına karışma.
    [[ -f "$PLIST" ]] || exit 0
    tun_up && exit 0

    # Ağ tamamen yoksa (Wi-Fi kapalı, uyanma anı) yeniden başlatmanın anlamı
    # yok; bir sonraki turda zaten tekrar bakacak.
    local iface
    iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
    [[ -n "$iface" ]] || exit 0

    logger -t thronedpi "TUN rotasi kayip (rota: ${iface}) - sing-box yeniden baslatiliyor"
    launchctl kickstart -k "system/${LABEL}" 2>/dev/null || exit 0

    local waited=0
    while (( waited < 20 )); do
        tun_up && break
        sleep 0.5
        waited=$(( waited + 1 ))
    done

    if tun_up; then
        pin_dns >/dev/null 2>&1
        logger -t thronedpi "TUN onarildi"
    else
        logger -t thronedpi "TUN onarilamadi"
    fi
    exit 0
}

pin_dns() {
    local svc n=0
    while IFS= read -r svc; do
        [[ -n "$svc" ]] || continue
        /usr/sbin/networksetup -setdnsservers "$svc" "$DNS_PIN" >/dev/null 2>&1 && n=$(( n + 1 ))
    done <<< "$(services)"
    flush_dns
    ok "DNS ${DNS_PIN} olarak sabitlendi (${n} servis)"
}

unpin_dns() {
    local svc n=0
    while IFS= read -r svc; do
        [[ -n "$svc" ]] || continue
        /usr/sbin/networksetup -setdnsservers "$svc" Empty >/dev/null 2>&1 && n=$(( n + 1 ))
    done <<< "$(services)"
    flush_dns
    ok "DNS DHCP'ye döndürüldü (${n} servis)"
}

is_loaded() { launchctl print "system/${LABEL}" >/dev/null 2>&1; }

# TUN arayüzü gerçekten ayakta mı? launchd'nin "yüklü" demesi yetmez.
tun_up() { route -n get 1.1.1.1 2>/dev/null | grep -q 'interface: utun'; }

preflight() {
    [[ -x "$SINGBOX" ]] || die "sing-box bulunamadı. Kurmak için:  brew install sing-box"
    [[ -f "$CONFIG" ]]  || die "Yapılandırma yok: $CONFIG"
    # Bozuk bir config'le başlatıp yarı kurulu bir ağ bırakmaktan iyidir.
    # Not: `check` her şeyi yakalamaz (bazı hatalar yalnızca çalışırken çıkar),
    # bu yüzden aşağıda TUN'un gerçekten kalktığını ayrıca doğruluyoruz.
    "$SINGBOX" check -c "$CONFIG" || die "Yapılandırma geçersiz (yukarıya bakın)."
}

cmd_on() {
    need_root on
    preflight

    if is_loaded; then
        log "Zaten açık. Yeniden başlatılıyor..."
        launchctl bootout "system/${LABEL}" 2>/dev/null || true
        sleep 1
    fi

    cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${SINGBOX}</string>
        <string>run</string>
        <string>-c</string>
        <string>${CONFIG}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>${LOG}</string>
    <key>StandardErrorPath</key>
    <string>${LOG}</string>
</dict>
</plist>
PLIST_EOF
    chown root:wheel "$PLIST"; chmod 0644 "$PLIST"

    launchctl bootstrap system "$PLIST" 2>/dev/null || die "Hizmet başlatılamadı."

    # Ayağa kalkmasını bekle; kalkmazsa logu göster ve geri al.
    local waited=0
    while (( waited < 30 )); do
        tun_up && break
        sleep 0.5
        waited=$(( waited + 1 ))
    done

    if tun_up; then
        # DNS'i TUN kalktıktan SONRA sabitliyoruz: TUN kalkmazsa aşağıdaki
        # geri alma yolunda sistemi değiştirilmiş DNS'le bırakmayalım.
        pin_dns
        install_watchdog
        log "AÇIK — tüm uygulamalar kapsanıyor."
        ok "TUN arayüzü: $(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}')"
        ok "log: $LOG"
        echo
        log "Kapatmak için:  sudo $0 off"
    else
        err "TUN ayağa kalkmadı. Son log satırları:"
        tail -15 "$LOG" 2>/dev/null | sed 's/^/    /'
        launchctl bootout "system/${LABEL}" 2>/dev/null || true
        rm -f "$PLIST"
        exit 1
    fi
}

cmd_off() {
    need_root off

    # Önce watchdog: aksi halde biz hizmeti durdururken o araya girip
    # yeniden başlatabilir.
    remove_watchdog

    if is_loaded; then
        # bootout SIGTERM gönderir, gerekirse SIGKILL'e yükseltir. sing-box
        # SIGTERM'i düzgün karşılar ve TUN arayüzünü kendisi kaldırır.
        launchctl bootout "system/${LABEL}" 2>/dev/null || true
        ok "hizmet durduruldu"
    else
        ok "hizmet zaten yüklü değildi"
    fi

    # Açılışta kendiliğinden başlamasın: plist'i bırakmıyoruz.
    [[ -f "$PLIST" ]] && { rm -f "$PLIST"; ok "plist silindi"; }

    # Arta kalan bir süreç varsa bitir.
    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        kill -9 "$pid" 2>/dev/null && warn "arta kalan süreç öldürüldü: PID $pid"
    done <<< "$(pgrep -f "sing-box run -c ${CONFIG}" 2>/dev/null || true)"

    unpin_dns

    sleep 1
    if tun_up; then
        warn "Varsayılan rota hâlâ bir utun arayüzünde. Başka bir VPN açık olabilir."
    else
        ok "varsayılan rota normale döndü"
    fi
    log "KAPALI"
}

cmd_status() {
    if is_loaded; then log "Hizmet: YÜKLÜ"; else log "Hizmet: yüklü değil"; fi
    if tun_up; then
        ok "TUN aktif -> $(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}')"
    else
        warn "TUN aktif değil (trafik doğrudan gidiyor)"
    fi
    if launchctl print "system/${WD_LABEL}" >/dev/null 2>&1; then
        ok "watchdog açık (her ${WD_INTERVAL}s)"
    else
        warn "watchdog kapalı"
    fi
    printf '  süreç : %s\n' "$(pgrep -f 'sing-box run' | tr '\n' ' ' || echo yok)"
    printf '  rota  : %s\n' "$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}')"
    # Tek bir servise bakmak yanıltıcı olur (ilk servis aktif olan olmayabilir),
    # bu yüzden hepsinin ayarını toplayıp benzersiz değerleri gösteriyoruz.
    local svc dns seen=""
    while IFS= read -r svc; do
        [[ -n "$svc" ]] || continue
        dns=$(/usr/sbin/networksetup -getdnsservers "$svc" 2>/dev/null | tr '\n' ' ')
        [[ "$dns" == *"aren't any"* ]] && dns="(DHCP)"
        case "$seen" in *"[$dns]"*) ;; *) seen="${seen}[$dns]" ;; esac
    done <<< "$(services)"
    printf '  DNS   : %s\n' "$seen"
    # En kritik tek gösterge: engelli bir ad sinkhole'a mı çözülüyor?
    # dig, zaman aşımında hata metnini de stdout'a basar; "boş değil" demek
    # cevap geldi demek DEĞİL. Bu yüzden IPv4 biçimi arıyoruz.
    local probe; probe=$(dig +short +time=4 discord.com A 2>/dev/null | grep -m1 -E '^[0-9]+(\.[0-9]+){3}$')
    if [[ -z "$probe" ]]; then
        warn "DNS cevap vermiyor (discord.com çözülemedi)"
    elif [[ "$probe" == "195.175.254.2" ]]; then
        warn "DNS sinkhole'a düşüyor ($probe) — DoH devrede değil"
    else
        ok "DNS temiz (discord.com -> $probe)"
    fi
    [[ -f "$LOG" ]] && printf '  log   : %s (son: %s)\n' "$LOG" "$(tail -1 "$LOG" 2>/dev/null | cut -c1-60)"
}

cmd_test() {
    log "Engelli siteler deneniyor (doğrudan bağlantı, TUN varsa oradan geçer)"
    local ok_count=0 total=0
    for h in discord.com updates.discord.com cdn.discordapp.com \
             www.roblox.com clientsettingscdn.roblox.com apis.roblox.com; do
        total=$(( total + 1 ))
        local c
        # `|| echo 000` KULLANMAYIN: curl başarısız olduğunda -w çıktısı zaten
        # "000" basar, echo da ekleyince "000000" olur ve karşılaştırma tutmaz.
        c=$(curl -sS -o /dev/null -m 12 -w '%{http_code}' --noproxy '*' "https://$h/" 2>/dev/null)
        [[ -n "$c" ]] || c=000
        if [[ "$c" == "000" ]]; then
            printf '  \033[31m✗\033[0m %-32s %s\n' "$h" "$c"
        else
            printf '  \033[32m✓\033[0m %-32s %s\n' "$h" "$c"
            ok_count=$(( ok_count + 1 ))
        fi
    done
    echo
    log "${ok_count}/${total} erişilebilir"
    if (( ok_count < total )); then
        warn "Hepsi açılmadıysa:  sudo $0 status  ve  tail -30 $LOG"
    fi
}

case "${1:-status}" in
    on)     cmd_on ;;
    off)    cmd_off ;;
    status) cmd_status ;;
    test)   cmd_test ;;
    _watchdog) cmd_watchdog ;;
    *)      echo "kullanım: $0 {on|off|status|test}" >&2; exit 1 ;;
esac
