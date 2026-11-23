#!/bin/sh
# Builds a Linux package of Salaat First from its Windows release. The Windows app is a JVM
# Compose Desktop app, so we reuse its jars, add the Linux native libraries Conveyor strips
# from them, and bundle a Linux JRE.
# Usage: port.sh [-f deb|rpm|pacman|appimage] [-o OUTDIR] [MSIXBUNDLE_OR_MSIX]
#        sudo port.sh -i [-f deb|rpm|pacman] [MSIXBUNDLE_OR_MSIX]
#        port.sh -u [MSIXBUNDLE_OR_MSIX]
#   No file: downloads the latest release from the Microsoft Store (via store.rg-adguard.net).
#   No -f: builds the format your distro installs, or an AppImage if it's not recognised.
#   -i: adds a local repository that your package manager updates Salaat First from. A daily job
#       (salaat-first-update.timer) builds each new release into /var/lib/salaat-first/repo and
#       downloads only the 64 KB blocks that changed. A file given here seeds the first download.
#   -r DIR: what that job runs: builds into the repository in DIR, unless it has the latest release.
#   -u: installs it in your home folder, for you only and without sudo. Run it again to update. If curl,
#       python3 or openssl is missing, it builds in Docker.
# The packages start the app hidden at login and ship a panel widget with the countdown and an
# Open/Quit menu. To show it, log out and back in, then run `gnome-extensions enable salaat-first@local`
# (GNOME), or add "Salaat First" with "Add Widgets…" (KDE Plasma 6).
set -eu
fmt= outdir=. src= repo= setup= here=$(dirname "$0")
while getopts f:o:r:iuh opt; do case $opt in
  f) fmt=$OPTARG ;; o) outdir=$OPTARG ;; r) repo=$OPTARG outdir=$OPTARG/repo ;; i) setup=1 ;; u) fmt=home ;;
  *) sed -n '5,15p' "$0"; exit 2 ;; esac; done
shift $((OPTIND - 1)); src=${1:-}
die() { echo "$*" >&2; exit 1; }
# This architecture's names at Debian, Adoptium, Skiko and LWJGL, and its AppImage runtime's checksum.
m=$(uname -m)
case $m in
  x86_64) deb=amd64 jdk=x64 skiko=linux-x64 lwjgl=natives-linux rt=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d ;;
  aarch64) deb=arm64 jdk=aarch64 skiko=linux-arm64 lwjgl=natives-linux-arm64 rt=00cbdfcf917cc6c0ff6d3347d59e0ca1f7f45a6df1a428a0d6d8a78664d87444 ;;
  *) die "only x86_64 and aarch64 are supported" ;;
esac
[ -z "$src" ] || [ -f "$src" ] || die "no such file: $src"

if [ -z "$fmt" ]; then
  ids=" $(. /etc/os-release 2>/dev/null; echo "${ID:-} ${ID_LIKE:-}") "
  case $ids in
    *" debian "*|*" ubuntu "*) fmt=deb ;;
    *" fedora "*|*" rhel "*|*" suse "*) fmt=rpm ;;
    *" arch "*) fmt=pacman ;;
    *) fmt=appimage ;;
  esac
  echo "Building a $fmt package (pick another with -f)."
fi
need() { command -v "$1" >/dev/null || die "$1 not found: install $2"; }
docker=
# Without sudo, a computer that lacks these can still build in Docker.
[ "$fmt" != home ] || for t in curl python3 openssl; do command -v $t >/dev/null || docker=1; done
if [ -n "$docker" ]; then need docker "curl, python3 and openssl, or Docker"
else need curl curl; need python3 "python3 (Arch: python)"; need openssl openssl; fi
case $fmt in
  deb) need dpkg-deb dpkg ;;
  rpm) need rpmbuild "rpm-build (Debian/Ubuntu: rpm)"; [ -z "$setup$repo" ] || need createrepo_c createrepo_c ;;
  pacman) need makepkg pacman; need fakeroot base-devel ;;
  appimage) need mksquashfs squashfs-tools; [ -z "$setup$repo" ] || die "the repository needs deb, rpm or pacman" ;;
  home) [ "$(id -u)" != 0 ] || die "-u installs for you only; run it without sudo"
    [ -z "$setup$repo" ] || die "the repository needs deb, rpm or pacman" ;;
  *) die "unknown format: $fmt (use deb, rpm, pacman or appimage)" ;;
esac

# Creates the user salaat-first, /var/lib/salaat-first, the salaat-first-update units and the repository entry.
if [ -n "$setup" ]; then
  [ "$(id -u)" = 0 ] || die "-i needs root"
  [ "$fmt" != rpm ] || [ -d /etc/yum.repos.d ] || die "-i supports rpm with dnf only"
  d=/var/lib/salaat-first
  id -u salaat-first >/dev/null 2>&1 || useradd -r -d "$d" -s /usr/sbin/nologin salaat-first
  mkdir -p "$d"; chown salaat-first: "$d"
  # The job runs this copy of the script; run -i again to update it.
  rm -rf "$d/port"; mkdir "$d/port"; cp -r "$here/port.sh" "$here/msix-fetch.py" "$here/widgets" "$d/port/"
  if [ -n "$src" ]; then
    rm -rf "$d/msix"; python3 -I "$here/msix-fetch.py" "$src" "" "$d/msix" || die "couldn't read $src"
    chown -R salaat-first: "$d/msix"
  fi
  echo "Building the first package into $d/repo"
  (cd / && runuser -u salaat-first -- env HOME="$d" "$d/port/port.sh" -f "$fmt" -r "$d") || die "the first build failed"
  case $fmt in
    deb) echo "deb [trusted=yes] file:$d/repo ./" > /etc/apt/sources.list.d/salaat-first.list
      upd="apt update && sudo apt install salaat-first" ;;
    rpm) printf '[salaat-first]\nname=Salaat First (built locally)\nbaseurl=file://%s/repo\ngpgcheck=0\nmetadata_expire=0\n' "$d" \
        > /etc/yum.repos.d/salaat-first.repo
      upd="dnf install salaat-first" ;;
    pacman) grep -q '^\[salaat-first\]' /etc/pacman.conf \
        || printf '\n[salaat-first]\nSigLevel = Optional TrustAll\nServer = file://%s/repo\n' "$d" >> /etc/pacman.conf
      upd="pacman -Syu salaat-first" ;;
  esac
  cat > /etc/systemd/system/salaat-first-update.service <<EOF
[Unit]
Description=Build new Salaat First releases into its local package repository
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
User=salaat-first
ExecStart=$d/port/port.sh -f $fmt -r $d
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=$d
EOF
  cat > /etc/systemd/system/salaat-first-update.timer <<EOF
[Unit]
Description=Check daily for a new Salaat First release
[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload && systemctl enable --now salaat-first-update.timer
  echo "Done. Install it with: sudo $upd"
  exit
fi
mkdir -p "$outdir"; outdir=$(cd "$outdir" && pwd)
# /tmp is often RAM-backed; this needs about 1 GB.
w=$(mktemp -d -p "${TMPDIR:-/var/tmp}" salaat-first.XXXXXX); trap 'rm -rf "$w"' EXIT

get() { # url file sum-command expected-sum
  # A repository keeps its last build's downloads and reuses those whose checksum still matches.
  if [ -n "$repo" ] && echo "$4  $repo/cache/${2##*/}" | $3 -c --quiet >/dev/null 2>&1; then cp "$repo/cache/${2##*/}" "$2"
  else
    echo "Downloading ${2##*/}"
    curl -fL --progress-bar "$1" -o "$2" && echo "$4  $2" | $3 -c --quiet || die "download failed or checksum mismatch: $1"
  fi
  [ -z "$repo" ] || cp "$2" "$w/cache/"
}
[ -z "$repo" ] || mkdir "$w/cache"

# -u: puts the built files in your home folder: the app in ~/.local/opt, and its menu and login entries,
# icon and widgets where your desktop looks for them.
install_home() {
  [ -d "$w/root/opt/salaat-first" ] || die "the build failed"
  l=$HOME/.local d=${XDG_DATA_HOME:-$HOME/.local/share} a=${XDG_CONFIG_HOME:-$HOME/.config}/autostart
  rm -rf "$l/opt/salaat-first" "$d/gnome-shell/extensions/salaat-first@local" "$d/plasma/plasmoids/local.salaatfirst"
  mkdir -p "$l/opt" "$l/bin" "$d" "$a"
  mv "$w/root/opt/salaat-first" "$l/opt/"; ln -sf ../opt/salaat-first/salaat-first "$l/bin/salaat-first"
  cp -r "$w/root/usr/share/." "$d/"
  # ~/.local/bin may not be on the desktop's PATH, so the menu and login entries get the full path.
  sed -i "s|^Exec=salaat-first|Exec=$l/bin/salaat-first|" "$d/applications/salaat-first.desktop"
  sed "s|^Exec=salaat-first|Exec=$l/bin/salaat-first|" "$w/root/etc/xdg/autostart/salaat-first.desktop" > "$a/salaat-first.desktop"
  echo "Installed in $l/opt/salaat-first. To show the panel widget, log out and back in (see README.md)."
  exit
}
if [ -n "$docker" ]; then
  echo "curl, python3 or openssl is missing, so building in Docker"
  mkdir "$w/root"
  # The files come out as a tar, so none of them belong to Docker's root.
  docker run --rm -v "$(cd "$here" && pwd):/src:ro" ${src:+-v "$(readlink -f "$src"):/in:ro"} debian:trixie sh -c \
    "apt-get update -qq && apt-get install -y -qq curl ca-certificates python3 openssl >/dev/null &&
     /src/port.sh -f deb -o /out ${src:+/in} >&2 && dpkg-deb --fsys-tarfile /out/*.deb" \
    | tar -x -C "$w/root" || die "the build in Docker failed"
  install_home
fi

if [ -z "$src" ]; then
  echo "Looking up the latest release"
  # Cloudflare rejects requests that don't look like they come from the site's own page.
  curl -sSf https://store.rg-adguard.net/api/GetFiles -o "$w/files.html" \
    -H 'origin: https://store.rg-adguard.net' -H 'referer: https://store.rg-adguard.net/' \
    -A 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36' \
    --data 'type=url&url=https%3A%2F%2Fapps.microsoft.com%2Fdetail%2F9pksnkt5dfsp&ring=RP&lang=en-US' \
    || die "store.rg-adguard.net refused the request; download the .msixbundle there by hand and pass it to this script"
  # One table row per file: link, name, date, SHA-1, size. Keep the newest .msixbundle as "name url".
  set -f; set -- $(sed 's/<tr/\n<tr/g' "$w/files.html" | grep '\.msixbundle<' \
    | sed -E 's/.*href="([^"]+)"[^>]*>([^<]+)<.*/\2 \1/; s/&amp;/\&/g' | sort -V | tail -1); set +f
  [ $# -eq 2 ] || die "no .msixbundle in the store.rg-adguard.net listing; download it there by hand and pass it to this script"
  name=$1 src=$2
  [ -z "$repo" ] || [ "$(cat "$repo/last" 2>/dev/null)" != "$name" ] || { echo "$name is already in the repository"; exit; }
fi

# Takes the x64 MSIX's app files and checks Microsoft's signature on them (the Store CDN is plain HTTP).
# ARM builds use it too: the arm64 MSIX differs only in Windows libraries, which are dropped or replaced below.
# Only blocks missing from the repository's last build are downloaded.
python3 -I "$here/msix-fetch.py" "$src" "${repo:+$repo/msix}" "$w/msix" || die "couldn't get Salaat First from $src"
opt=$w/root/opt/salaat-first app=$w/root/opt/salaat-first/app
mkdir -p "$opt"; cp -r "$w/msix/." "$opt/"
exe=$(ls "$opt"/bin/*.exe)

# The Windows launcher embeds the classpath (in load order) and the app's -D options.
tr -c '[:print:]' '\n' < "$exe" > "$w/exe.txt"
grep -oP '^-Djava.class.path=\K.*' "$w/exe.txt" | tr ';' '\n' | sed 's/^&&\\//' | grep . \
  | grep -v -- '-runtime-windows-' | sed "s/^skiko-awt-runtime-linux-x64-/skiko-awt-runtime-$skiko-/; s/-natives-windows\.jar\$/-$lwjgl.jar/" \
  > "$opt/classpath.txt"
opts=$(grep -E '^-Dapp\.(displayName|fsname|version|revision|repositoryUrl)=' "$w/exe.txt" | sort -u | sed "s/.*/  '&' \\\\/")
ver=$(grep -oP '^-Dapp\.version=\K[0-9.]+$' "$w/exe.txt") || die "no app version in $exe"
rm -r "$opt/bin"

# The app's "Native desktop notifications" (Settings > Advanced) are Windows toasts, which the helper below shows
# with notify-send. Make them the default, in place of the app's own popup windows, and have the settings that
# depend on them take Windows' branch on Linux, where they throw "We don't know yet".
python3 -I - "$app" <<'EOF' || echo "Couldn't make native notifications the default; the app keeps its own popups." >&2
import os, re, struct, sys, zipfile
def only_a_string(b, text):  # the class's constant `text` is used only as a string literal
    n, p, i, found, refs = struct.unpack('>H', b[8:10])[0], 10, 1, [], []
    while i < n:
        t = b[p]
        if t == 1:
            l = struct.unpack('>H', b[p+1:p+3])[0]
            if b[p+3:p+3+l] == text: found.append(i)
            p += 3 + l
        else:
            l = {3: 4, 4: 4, 5: 8, 6: 8, 7: 2, 8: 2, 9: 4, 10: 4, 11: 4, 12: 4, 15: 3, 16: 2, 17: 4, 18: 4, 19: 2, 20: 2}[t]
            if t in (7, 12, 16, 19, 20): refs += struct.unpack('>%dH' % (l // 2), b[p+1:p+1+l])  # names, types
            p += 1 + l; i += t in (5, 6)
        i += 1
    return len(found) == 1 and found[0] not in refs
edits = [  # jar, class, bytes, replacement, count
    # getExperience()'s default: localStore.getString("windows_events_experience", "BuiltIn")
    ('events-desktop.jar', 'org/hicham/salaat/events/DesktopEventsExperienceHelper.class',
     rb'\x01\x00\x07BuiltIn', b'\x01\x00\x06Native', 1),
    # supportsCustomTones/Adhan: isWindows(); ifeq THROW; iconst_0; goto  ->  isWindows(); pop; nop; nop; iconst_0; goto
    ('settings-desktop.jar', 'org/hicham/salaat/ui/settings/util/PlatformExts_desktopKt.class',
     rb'(\xb8..)\x99\x00\x07(\x03\xa7)', b'\\1\x57\x00\x00\\2', 2),
]
new = {}
for jar, cls, old, rep, count in edits:
    b = zipfile.ZipFile(f'{sys.argv[1]}/{jar}').read(cls)
    new[jar], k = re.subn(old, rep, b, flags=re.S)
    assert k == count and (rep != b'\x01\x00\x06Native' or only_a_string(b, b'BuiltIn')), f'{cls} has changed'
for jar, cls, *_ in edits:
    path = f'{sys.argv[1]}/{jar}'
    with zipfile.ZipFile(path) as src, zipfile.ZipFile(path + '.tmp', 'w') as dst:
        for i in src.infolist(): dst.writestr(i, new[jar] if i.filename == cls else src.read(i))
    os.replace(path + '.tmp', path)
EOF

# The app runs this Windows helper to update its live tile, every 5 minutes and when the times change.
# On Linux it saves the day's times, in the app's language and numerals, for the panel widgets instead.
cat > "$app/salaat-first-helper" <<'EOF'
#!/bin/sh
# With native notifications, the app also schedules its toasts here, and cancels them before re-scheduling:
#   notifications schedule --id ID --time ISO-8601 --title T --body B --launch-arg ARG
#     [--sound ms-appx:///app/Adhans//NAME.mp3 --toast-scenario Reminder --alert-action STOP-LABEL:dismiss]
#   notifications cancel --id ID | notifications cancel-all
# Each toast gets a user timer that shows it with notify-send. A click opens the app with ARG, like a toast's.
if [ "${1:-}" = notifications ]; then
  self=$(readlink -f "$0") u=salaat-first-notification cmd=$2; shift 2
  for a; do case ${p:-} in --id) id=$a ;; --time) t=$a ;; --title) title=$a ;; --body) body=$a ;; --launch-arg) arg=$a ;;
    --sound) sound=$a ;; --toast-scenario) urgency=critical ;; --alert-action) stop=${a%:*} ;; esac; p=$a; done
  case $cmd in
    cancel-all) exec systemctl --user stop "$u-*.timer" ;;
    cancel) exec systemctl --user stop "$u-$id-*.timer" ;;
    schedule) exec systemd-run --user --quiet --collect --unit="$u-$id-$(date +%s%N)" \
      --on-calendar="$(date -u -d "$t" '+%F %T UTC')" --timer-property=AccuracySec=1s --timer-property=RemainAfterElapse=no \
      -- "$self" notifications show "$@" ;;
    show) here=${self%/*} host=$(uname -n)
      # The adhan plays until it ends or the notification is closed; other toasts get the desktop's sound.
      if [ "${host#c3}" != "$host" ]; then
        hint=boolean:suppress-sound:true
      elif [ -n "${sound:-}" ]; then
        "$(command -v pw-play || echo paplay)" "$here/Adhans/${sound##*/}" & player=$! hint=boolean:suppress-sound:true
      else hint=string:sound-name:message-new-instant; fi
      a=$(notify-send -w -a "Salaat First" -i salaat-first -h string:desktop-entry:salaat-first -h "$hint" \
        -u "${urgency:-normal}" -A default=Open ${stop:+-A "stop=$stop"} -- "$title" "$body")
      [ -z "${player:-}" ] || kill "$player" 2>/dev/null
      [ "$a" != default ] || exec "$here/../salaat-first" "$arg" ;;
  esac
  exit
fi
# Called as: --language L update-tile --location NAME --times FAJR SUNRISE DHUHR ASR MAGHRIB ISHAA --next-prayer ID
lang=en; [ "${1:-}" = --language ] && lang=$2
while [ $# -gt 0 ] && [ "$1" != --times ]; do shift; done
[ $# -ge 7 ] || exit 0
shift
f=${XDG_CACHE_HOME:-$HOME/.cache}/SalaatFirst/widget.json
# The app's own short prayer names; like the app, Fridays show Jumua for Dhuhr.
case $lang in
  ar*) names='الفجر|الشروق|الظهر|العصر|المغرب|العشاء' jumua='الجمعة' until='{p} بعد {t}' since='{p} منذ {t}' ;;
  fr*) names='Fajr|Chorouq|Dohr|Asr|Maghrib|Ichaa' jumua=Jomoua until='{p} dans {t}' since='{p} il y a {t}' ;;
  es*) names="Fajr|Amanecer|Dhuhr|Asr|Maghrib|Isha'a" jumua=Jumua until='{p} en {t}' since='{p} hace {t}' ;;
  *) names='Fajr|Sunrise|Dhuhr|Asr|Maghrib|Ishaa' jumua=Jumuaa until='{p} in {t}' since='{p} {t} ago' ;;
esac
# The app shows Arabic-Indic digits only in Arabic, when its Numerals setting is "١,٢,٣". Until the user picks
# one, that setting follows Java 21's default for the system locale: Arabic-Indic, except in Maghreb and UAE locales.
digits=0123456789
if [ "${lang%%[-_]*}" = ar ]; then
  n=$(grep -o '"numerals_system": *"[a-z]*"' "${XDG_DATA_HOME:-$HOME/.local/share}/SalaatFirst/prefs/prefs.json" 2>/dev/null | cut -d'"' -f4)
  [ -n "$n" ] || case ${LC_ALL:-${LC_CTYPE:-${LANG:-}}} in
    ar_MA*|ar_DZ*|ar_TN*|ar_LY*|ar_EH*|ar_AE*) n=arab ;;
    ar|ar[._@]*) n=hindu ;;
  esac
  [ "$n" != hindu ] || digits='٠١٢٣٤٥٦٧٨٩'
fi
# In Arabic the times come with Arabic-Indic digits, whatever the Numerals setting.
# 12-hour times ("05:28 PM", "05:28 p. m.", "05:28 م") have a second field. The times rise through
# the day, so one that goes back is afternoon.
# shortcut: an Ishaa after midnight in 12-hour mode comes out 12 hours late; it only happens far north.
printf '%s\n' "$1" "$2" "$3" "$4" "$5" "$6" | sed 's/٠/0/g; s/١/1/g; s/٢/2/g; s/٣/3/g; s/٤/4/g; s/٥/5/g; s/٦/6/g; s/٧/7/g; s/٨/8/g; s/٩/9/g' \
  | awk -v day="$(date +%F)" -v z="$(date +%z)" -v friday="$(date +%u | grep -x 5)" \
  -v names="$names" -v jumua="$jumua" -v until="$until" -v since="$since" -v digits="$digits" '
  { split($1, t, ":"); m = t[1] * 60 + t[2]; if (NF > 1) { m %= 720; if (m < p) m += 720 }; p = m
    s = s (NR > 1 ? "," : "") sprintf("\"%02d:%02d\"", m / 60, m % 60) }
  END { split(names, n, "|"); if (friday) n[3] = jumua
    for (i = 1; i <= 6; i++) ns = ns (i > 1 ? "," : "") "\"" n[i] "\""
    printf "{\"date\":\"%s\",\"offset\":%d,\"times\":[%s],\"names\":[%s],\"until\":\"%s\",\"since\":\"%s\",\"digits\":\"%s\"}\n", day,
      (substr(z, 1, 1) "1") * (substr(z, 2, 2) * 3600 + substr(z, 4, 2) * 60), s, ns, until, since, digits }' > "$f.tmp" && mv "$f.tmp" "$f"
EOF
chmod +x "$app/salaat-first-helper"

# Conveyor strips the Linux .so files from these jars; fetch the originals.
maven() { # group artifact version [classifier]
  f=$2-$3${4:+-$4}.jar u=https://repo1.maven.org/maven2/$(echo "$1" | tr . /)/$2/$3/$f
  get "$u" "$app/$f" sha1sum "$(curl -sfL "$u.sha1" | cut -d' ' -f1)"
}
while read -r j; do
  case $j in
    skiko-awt-runtime-$skiko-*.jar) v=${j#skiko-awt-runtime-"$skiko"-}; maven org.jetbrains.skiko "skiko-awt-runtime-$skiko" "${v%.jar}" ;;
    sqlite-jdbc-*.jar) v=${j#sqlite-jdbc-}; maven org.xerial sqlite-jdbc "${v%.jar}" ;;
    jna-[0-9]*.jar) v=${j#jna-}; maven net.java.dev.jna jna "${v%.jar}" ;;
    lwjgl*-$lwjgl.jar) a=${j%%-[0-9]*} v=${j#"$a"-}; maven org.lwjgl "$a" "${v%-"$lwjgl".jar}" "$lwjgl" ;;
  esac
done < "$opt/classpath.txt"
while read -r j; do [ -f "$app/$j" ] || die "missing from the port: $j"; done < "$opt/classpath.txt"

# The Windows build bundles a Java 21 runtime; bundle the Linux one.
jre=$(curl -sSfI https://api.adoptium.net/v3/binary/latest/21/ga/linux/$jdk/jre/hotspot/normal/eclipse \
  | sed -n 's/^location: *//Ip' | tr -d '\r')
get "$jre" "$w/jre.tar.gz" sha256sum "$(curl -sfL "$jre.sha256.txt" | cut -d' ' -f1)"
mkdir "$opt/jre"; tar -xzf "$w/jre.tar.gz" --strip-components=1 -C "$opt/jre"

cat > "$opt/salaat-first" <<EOF
#!/bin/sh
here=\$(dirname "\$(readlink -f "\$0")")
# The app assumes these exist (the MSIX installer creates them on Windows).
mkdir -p "\${XDG_DATA_HOME:-\$HOME/.local/share}/SalaatFirst" "\${XDG_CONFIG_HOME:-\$HOME/.config}/SalaatFirst" "\${XDG_CACHE_HOME:-\$HOME/.cache}/SalaatFirst"
exec "\$here/jre/bin/java" -Dfile.encoding=UTF-8 -Djava.net.useSystemProxies=true --enable-native-access=ALL-UNNAMED \\
  -Dapp.dir="\$here/app" \\
$opts
  -cp "\$(sed "s|^|\$here/app/|" "\$here/classpath.txt" | paste -sd:)" org.hicham.salaat.MainKt "\$@"
EOF
chmod +x "$opt/salaat-first"
mkdir -p "$w/root/usr/bin" "$w/root/usr/share/applications" "$w/root/usr/share/icons/hicolor/scalable/apps"
# AWT names every Compose window's class after the thread that opened it.
cat > "$w/root/usr/share/applications/salaat-first.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Salaat First
Comment=Prayer times
Exec=salaat-first
Icon=salaat-first
Categories=Utility;
StartupWMClass=java-lang-Thread
EOF
cp "$app/icon.svg" "$w/root/usr/share/icons/hicolor/scalable/apps/salaat-first.svg"
# Start hidden at login, as the Windows app does, so prayer notifications fire.
mkdir -p "$w/root/etc/xdg/autostart"
sed 's/^Exec=.*/& autostart/' "$w/root/usr/share/applications/salaat-first.desktop" > "$w/root/etc/xdg/autostart/salaat-first.desktop"
# Panel widgets: the countdown, and the Open/Quit menu that GNOME has no tray for. Each user enables them once.
mkdir -p "$w/root/usr/share/gnome-shell/extensions" "$w/root/usr/share/plasma/plasmoids"
cp -r "$here/widgets/gnome" "$w/root/usr/share/gnome-shell/extensions/salaat-first@local"
cp -r "$here/widgets/kde" "$w/root/usr/share/plasma/plasmoids/local.salaatfirst"
ln -s ../../opt/salaat-first/salaat-first "$w/root/usr/bin/salaat-first"
chmod -R u+w,go-w,a+rX "$w/root"

desc="Prayer times (unofficial Linux port of the Salaat First Windows app)"
# Only notify-send is declared, as minimal desktops can lack it.
# shortcut: the bundled JRE and Skia need X11, OpenGL, fontconfig and ALSA, and the adhan pw-play or paplay,
# which every desktop install has. Declare them if minimal installs matter.
case $fmt in
home) install_home ;;
deb)
  mkdir "$w/root/DEBIAN"
  printf 'Package: salaat-first\nVersion: %s\nArchitecture: %s\nDepends: libnotify-bin\nMaintainer: Salaat First Linux port <noreply@localhost>\nDescription: %s\n' \
    "$ver" "$deb" "$desc" > "$w/root/DEBIAN/control"
  out=$outdir/salaat-first_${ver}_$deb.deb
  dpkg-deb --root-owner-group -Zgzip --build "$w/root" "$out" >/dev/null ;;
rpm)
  cat > "$w/salaat-first.spec" <<EOF
Name: salaat-first
Version: $ver
Release: 1
Summary: $desc
License: Proprietary
AutoReqProv: no
Requires: /usr/bin/notify-send
%global debug_package %{nil}
%global source_date_epoch_from_changelog 0
%global __os_install_post %{nil}
%description
$desc
%install
mkdir -p %{buildroot}
cp -a "$w/root/." %{buildroot}/
%files
/etc/xdg/autostart/salaat-first.desktop
/opt/salaat-first
/usr/bin/salaat-first
/usr/share/gnome-shell/extensions/salaat-first@local
/usr/share/plasma/plasmoids/local.salaatfirst
/usr/share/applications/salaat-first.desktop
/usr/share/icons/hicolor/scalable/apps/salaat-first.svg
EOF
  out=$outdir/salaat-first-$ver-1.$m.rpm
  rpmbuild --quiet -bb --target "$m" --define "_topdir $w/rpmbuild" --define "_rpmdir $outdir" \
    --define '_build_name_fmt %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm' "$w/salaat-first.spec" ;;
pacman)
  mkdir "$w/arch"
  cat > "$w/arch/PKGBUILD" <<EOF
pkgname=salaat-first
pkgver=$ver
pkgrel=1
pkgdesc="$desc"
arch=($m)
license=(custom)
depends=(libnotify)
options=(!strip !debug)
package() { cp -a "$w/root/." "\$pkgdir/"; }
EOF
  # -d: the dependencies are for installing, not building.
  (cd "$w/arch" && PKGDEST=$outdir PKGEXT=.pkg.tar.zst makepkg -fd >/dev/null)
  out=$outdir/salaat-first-$ver-1-$m.pkg.tar.zst ;;
appimage)
  # AppDir: the app at its root, run through AppRun, with the desktop file and icon beside it.
  # shortcut: no login entry or panel widgets, which need a system install; use a package for those.
  a=$w/AppDir; mv "$opt" "$a"
  ln -s salaat-first "$a/AppRun"
  cp "$w/root/usr/share/applications/salaat-first.desktop" "$w/root/usr/share/icons/hicolor/scalable/apps/salaat-first.svg" "$a/"
  ln -s salaat-first.svg "$a/.DirIcon"
  mksquashfs "$a" "$w/app.squashfs" -root-owned -noappend -comp zstd -no-progress >/dev/null
  get https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-$m "$w/runtime" sha256sum "$rt"
  out=$outdir/Salaat_First-$ver-$m.AppImage
  cat "$w/runtime" "$w/app.squashfs" > "$out"; chmod +x "$out" ;;
esac
echo "Built $out"

if [ -n "$repo" ]; then
  # Swap the new package in and index it for the package manager.
  for f in "$outdir"/salaat-first[-_]*; do [ "$f" = "$out" ] || rm -f "$f"; done
  case $fmt in
    deb) { dpkg-deb -f "$out"; printf 'Filename: ./%s\nSize: %s\nSHA256: %s\n' "${out##*/}" "$(wc -c < "$out")" \
      "$(sha256sum "$out" | cut -d' ' -f1)"; } > "$outdir/Packages" ;;
    rpm) createrepo_c -q "$outdir" ;;
    pacman) repo-add -q "$outdir/salaat-first.db.tar.gz" "$out" ;;
  esac
  # Keep this build's app files and downloads for the next one.
  rm -rf "$repo/msix" "$repo/cache"; mv "$w/msix" "$w/cache" "$repo/"
  echo "${name:-${src##*/}}" > "$repo/last"
fi
