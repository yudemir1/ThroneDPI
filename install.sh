#!/usr/bin/env bash
# ThroneDPI kurulumu.
#
#   ./install.sh
#
# Yaptıkları:
#   1. sing-box yoksa Homebrew ile kurar
#   2. tun.json  -> /usr/local/etc/thronedpi/tun.json   (varsa korur)
#   3. dpi.sh    -> /usr/local/bin/dpi                  (her yerden çağrılır)
#
# Yapılandırmayı /usr/local/etc altına kopyalıyoruz ki bu depo klasörünü
# silsen bile kurulum çalışmaya devam etsin.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="/usr/local/bin"
ETC_DIR="/usr/local/etc/thronedpi"

log()  { printf '\033[1;34m[kurulum]\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[kurulum]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "Bu araç yalnızca macOS içindir."

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    die "Bunu sudo ile çalıştırmayın. Gerektiğinde kendisi sudo soracak."
fi

# ---------------------------------------------------------------- 1. sing-box
log "1/3  sing-box"
if command -v sing-box >/dev/null 2>&1; then
    ok "zaten kurulu: $(sing-box version 2>/dev/null | head -1)"
else
    command -v brew >/dev/null 2>&1 \
        || die "Homebrew gerekiyor: https://brew.sh"
    log "Homebrew ile kuruluyor (biraz sürebilir)..."
    brew install sing-box || die "sing-box kurulamadı."
    ok "kuruldu: $(sing-box version 2>/dev/null | head -1)"
fi

# TUN için gvisor desteği şart; bottled formülde var ama doğrulayalım.
if ! sing-box version 2>/dev/null | grep -q 'with_gvisor'; then
    warn "sing-box 'with_gvisor' olmadan derlenmiş; TUN çalışmayabilir."
fi

# --------------------------------------------------------------- 2. yapılandırma
log "2/3  Yapılandırma -> ${ETC_DIR}/tun.json"
[[ -f "${HERE}/tun.json" ]] || die "tun.json bulunamadı: ${HERE}"
sing-box check -c "${HERE}/tun.json" >/dev/null 2>&1 \
    || die "Depodaki tun.json geçersiz; kurulum durduruldu."

sudo mkdir -p "$ETC_DIR"
if [[ -f "${ETC_DIR}/tun.json" ]]; then
    # Kullanıcının istisna listesini ezmiyoruz.
    warn "mevcut yapılandırma korundu: ${ETC_DIR}/tun.json"
    warn "yenisini istiyorsanız:  sudo cp ${HERE}/tun.json ${ETC_DIR}/tun.json"
else
    sudo cp "${HERE}/tun.json" "${ETC_DIR}/tun.json"
    sudo chmod 0644 "${ETC_DIR}/tun.json"
    ok "kopyalandı"
fi

# ------------------------------------------------------------------- 3. komut
log "3/3  Komut -> ${BIN_DIR}/dpi"
sudo mkdir -p "$BIN_DIR"
sudo cp "${HERE}/dpi.sh" "${BIN_DIR}/dpi"
sudo chmod 0755 "${BIN_DIR}/dpi"
ok "kuruldu"

case ":${PATH}:" in
    *":${BIN_DIR}:"*) ok "${BIN_DIR} PATH'te" ;;
    *) warn "${BIN_DIR} PATH'te değil; kabuk ayarınıza ekleyin." ;;
esac

echo
log "Kurulum tamam."
cat <<EOF

  Aç     :  sudo dpi on
  Kapat  :  sudo dpi off
  Durum  :  dpi status
  Test   :  dpi test

  Yapılandırma: ${ETC_DIR}/tun.json
  Bir site ThroneDPI açıkken bozulursa, alan adını oradaki
  "domain_suffix" istisna listesine ekleyip  sudo dpi off && sudo dpi on  yapın.
EOF
