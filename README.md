# ThroneDPI

macOS'ta DPI engellerini tüm uygulamalar için aşan tek komutluk bir araç.
[sing-box](https://sing-box.sagernet.org) TUN modu üzerine kurulu.

```bash
sudo dpi on     # aç
sudo dpi off    # kapa
```

Discord, Roblox, tarayıcılar, oyunlar, terminal — hepsi kapsanır. Uygulama
başına proxy ayarı yoktur.

## Neden proxy değil de TUN

Windows'ta GoodbyeDPI, **WinDivert** adlı bir çekirdek sürücüsüyle paketleri
ağ katmanında yakalar; uygulamaların bundan haberi bile olmaz. macOS'ta böyle
bir sürücü yok, bu yüzden macOS portları genellikle bir SOCKS proxy kurup
`networksetup` ile sistem geneli proxy ayarını değiştirir.

Sorun şu: macOS'ta sistem proxy ayarını yalnızca **onu okumayı seçen**
uygulamalar kullanır.

| | Sistem SOCKS ayarını kullanır mı? |
|---|---|
| Safari, Chrome, Discord (CFNetwork / Chromium) | evet |
| Roblox (kendi libcurl yığını) | **hayır** — doğrudan bağlanır |
| `curl`, `git`, `npm` ve çoğu terminal aracı | **hayır** |

Roblox proxy açıkken bile doğrudan bağlanır ve logunda şunu verir:

```
Error [FLog::Error] fetch flag exception: HttpError: SslConnectFail
Failed to access version URL https://clientsettingscdn.roblox.com/...
```

TUN'da böyle bir seçim yoktur: trafik sanal bir ağ arayüzünden geçer, uygulama
ne yaparsa yapsın yakalanır. WinDivert'in macOS'taki gerçek karşılığı budur.

## Nasıl çalışıyor

İki ayrı engelleme var ve ikisi de çözülmek zorunda.

**1. SNI tabanlı TLS engeli.** DPI, TLS ClientHello içindeki açık SNI alanını
okuyup engelli alan adlarında bağlantıyı düşürür. sing-box'ın
`tls_record_fragment` seçeneği el sıkışmayı birden fazla TLS kaydına bölerek
bunu aşar.

> Bu, byedpi'deki `--tlsrec` ile aynı tekniktir. Bir TTNet hattında yapılan
> ölçümde `--tlsrec` içeren her kombinasyon çalıştı, içermeyen hiçbiri
> çalışmadı — asıl iş yapan parça bu. TCP seviyesinde parçalama (`--split`,
> `--disorder`) ise bazı sunucuları bozuyordu.

**2. DNS engeli.** ISS'in resolver'ı engelli adları sinkhole adresine çözüyor
(`discord.com` → `195.175.254.2`). Harici bir resolver'a gönderilen **düz DNS**
sorguları ise, sorulan ad engel listesindeyse DPI tarafından düşürülüyor —
UDP/53 de TCP/53 de. Engelli olmayan adlar sorunsuz geçtiği için sonuç kafa
karıştırıcı olur: resolver "çalışır" ama tam da istediğiniz siteler için zaman
aşımına düşer.

Kendi hattınızda şöyle görebilirsiniz:

```bash
dig +short @8.8.8.8 example.com      # cevap gelir
dig +short @8.8.8.8 discord.com      # zaman aşımı
```

Çözüm DNS-over-HTTPS: sıradan HTTPS trafiğinden ayırt edilemediği için geçer.
sing-box DNS'i DoH üzerinden çözer ve `hijack-dns` ile sistemin tüm DNS
sorgularını kendi üzerine alır.

**DNS'in sabitlenmesi gerekiyor.** macOS, DHCP'den gelen IPv6 link-local
resolver'ı (`fe80::...%en0`) tercih eder. Link-local trafik tanımı gereği
yönlendirilmez; doğrudan fiziksel arayüzden çıkar ve TUN'a hiç uğramaz, yani
`hijack-dns` onu göremez. Bu yüzden `dpi on`, TUN kalktıktan sonra sistem
DNS'ini `1.1.1.1`'e sabitler — oraya giden sorgu IPv4 olduğu için TUN'a girer
ve hijack edilir. `dpi off` ayarı DHCP'ye geri döndürür.

`1.1.1.1` bilinçli bir seçim: sing-box bir şekilde ölürse düz DNS olarak
çalışmaya devam eder (engelli adlar hariç), yani internet tamamen kesilmez.

### Watchdog

sing-box uyku/uyanma ve ağ değişimlerinde varsayılan rotayı kaybedebiliyor.
Logda şöyle görünür:

```
ERROR network: missing default interface
```

Bu olduğunda süreç ayakta kalır, `utun` arayüzü de durur, ama varsayılan rota
fiziksel arayüze döner ve **bypass sessizce devre dışı kalır** — hiçbir hata
görmezsiniz, siteler yine açılmaz.

`dpi on` bu yüzden ikinci bir launchd işi kurar: dakikada bir varsayılan
rotaya bakar, `utun` üzerinde değilse sing-box'ı yeniden başlatıp DNS'i tekrar
sabitler. `dpi off` yapıldığında ana plist silindiği için watchdog hiçbir şeye
karışmaz; ağ tamamen yoksa (Wi-Fi kapalı) da boşuna uğraşmaz.

Onarım yaptığında sistem günlüğüne yazar — Console.app'te `thronedpi` aratın:

```bash
log show --last 1h --predicate 'eventMessage CONTAINS "thronedpi"' --info
```

Kontrol aralığını değiştirmek için `WD_INTERVAL=30 sudo -E ./dpi.sh on`.

## Kurulum

```bash
git clone https://github.com/yudemir1/ThroneDPI.git
cd ThroneDPI
./install.sh
```

Kurulum sing-box'ı (yoksa Homebrew ile) kurar, yapılandırmayı
`/usr/local/etc/thronedpi/tun.json` altına kopyalar ve `dpi` komutunu
`/usr/local/bin` içine yerleştirir. Bundan sonra depo klasörünü silebilirsiniz.

Gereksinimler: macOS 12+, [Homebrew](https://brew.sh), yönetici şifresi.

## Kullanım

```bash
sudo dpi on       # TUN'u aç, DNS'i sabitle
sudo dpi off      # kapat, DNS'i DHCP'ye döndür
     dpi status   # TUN, rota, DNS ve sinkhole kontrolü
     dpi test     # engelli siteleri dene
```

`dpi test` beklenen çıktı:

```
  ✓ discord.com                      200
  ✓ updates.discord.com              404
  ✓ cdn.discordapp.com               403
  ✓ www.roblox.com                   200
  ✓ clientsettingscdn.roblox.com     404
  ✓ apis.roblox.com                  404

[dpi] 6/6 erişilebilir
```

(`403`/`404` de başarıdır — sunucudan gerçek bir HTTP cevabı geldiği anlamına
gelir. Başarısızlık `000`'dır: bağlantı hiç kurulamamış.)

## Bir site bozulursa

TLS kaydı parçalama her sunucuyla uyumlu değil. Örneğin `sahibinden.com` bunu
reddediyor ve `sslv3 alert illegal parameter` veriyor. Böyle siteler için
yapılandırmadaki istisna listesi var:

```json
{
  "domain_suffix": [
    "sahibinden.com"
  ],
  "outbound": "direct"
}
```

`/usr/local/etc/thronedpi/tun.json` içinde bu listeye alan adını ekleyin, sonra:

```bash
sudo dpi off && sudo dpi on
```

Parçalama varsayılan olarak **tüm** trafiğe uygulanır, yani yeni engellenen bir
site kendiliğinden çalışır; listeye yalnızca *bozulan* siteleri eklersiniz.

## Sorun giderme

İlk bakılacak yer `dpi status`. İki olası arıza ayrı ayrı raporlanır:

```
! DNS sinkhole'a düşüyor (195.175.254.2) — DoH devrede değil
```

DNS sabitlenmemiş demektir. `sudo dpi off && sudo dpi on` deneyin.

```
! TUN aktif değil (trafik doğrudan gidiyor)
! watchdog kapalı
```

sing-box ayağa kalkmamış ya da rotasını kaybetmiş. Watchdog açıksa bunu bir
dakika içinde kendisi onarır; kapalıysa `sudo dpi off && sudo dpi on`. Logda
sebebi yazar:

```bash
tail -30 /var/log/singbox-dpi.log
```

Başka notlar:

- **ProtonVPN veya başka bir VPN ile birlikte kullanmayın** — ikisi de TUN
  arayüzü kurar, rotalar çakışır. `dpi status` hangisinin aktif olduğunu
  gösterir.
- `dpi off` plist'i siler, yani açılışta kendiliğinden başlamaz.
- sing-box `SIGTERM`'i düzgün karşılar ve TUN'u kendisi kaldırır. Süreç
  zorla öldürülse bile TUN arayüzü kaybolur ve trafik doğrudan akmaya devam
  eder; internet kesilmez, yalnızca bypass durur.

## Kaldırma

```bash
./uninstall.sh
```

Hizmeti durdurur, DNS'i DHCP'ye döndürür, `dpi` komutunu ve yapılandırmayı
siler, sonunda doğrulama basar. sing-box'a dokunmaz; onu da silmek için
`brew uninstall sing-box`.

## Teşekkür

- [sing-box](https://github.com/SagerNet/sing-box) — TUN ve TLS parçalama
- [GoodbyeDPI](https://github.com/ValdikSS/GoodbyeDPI) ve
  [GoodbyeDPI-Turkey](https://github.com/cagritaskn/GoodbyeDPI-Turkey) — Windows
  tarafındaki asıl fikir
- [byedpi](https://github.com/hufrea/byedpi) — `--tlsrec` tekniğinin kaynağı

## Lisans

MIT
