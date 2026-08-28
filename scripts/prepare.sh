#!/usr/bin/env bash
set -Eeuo pipefail

workspace="${1:?source directory is required}"
enable_adguardhome="${2:-true}"
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$enable_adguardhome" in
  true|false) ;;
  *)
    echo "ENABLE_ADGUARDHOME must be true or false." >&2
    exit 1
    ;;
esac

cd "$workspace"

rm -f .config

# QModem is not part of the standard OpenWrt feeds. Register its
# official source before updating feeds so luci-app-qmodem-next is available.
if ! grep -Eq '^src-git(-full)?[[:space:]]+qmodem[[:space:]]' feeds.conf.default; then
  printf '%s\n' 'src-git qmodem https://github.com/FUjr/QModem.git;main' >> feeds.conf.default
fi

./scripts/feeds update -a
./scripts/feeds install -a
./scripts/feeds install -a -f -p qmodem
test -f package/feeds/qmodem/luci-app-qmodem-next/Makefile || {
  echo 'QModem feed did not install luci-app-qmodem-next.' >&2
  exit 1
}

# Clean up obsolete theme and config packages from feeds and package tree
find feeds/luci feeds/packages -maxdepth 3 -type d \
  \( -name 'luci-theme-argon' -o -name 'luci-app-argon-config' \) \
  -prune -exec rm -rf {} + 2>/dev/null || true
rm -rf package/luci-theme-argon package/luci-app-argon-config

# Use the OpenWrt 24.10 Argon style, which has the preferred squarer layout.
argon_tmp="$(mktemp -d)"
git clone --branch openwrt-24.10 --depth 1 \
  https://github.com/sbwml/luci-theme-argon.git "$argon_tmp"
mv "$argon_tmp/luci-theme-argon" package/luci-theme-argon
mv "$argon_tmp/luci-app-argon-config" package/luci-app-argon-config
rm -rf "$argon_tmp"

# Keep the 24.10 visuals while using dependencies that are safe with the
# OpenWrt 25 APK package manager. In particular, do not pull in wget-nossl,
# which can replace apk's HTTPS-capable downloader.
sed -i 's/^LUCI_DEPENDS:=.*/LUCI_DEPENDS:=+curl +jsonfilter/' \
  package/luci-theme-argon/Makefile

# OpenWrt 25 renamed the LuCI software page from opkg to package-manager.
# Apply the existing 24.10 styling to both page identifiers.
for stylesheet in \
  package/luci-theme-argon/htdocs/luci-static/argon/css/cascade.css \
  package/luci-theme-argon/htdocs/luci-static/argon/css/dark.css; do
  sed -i 's/\[data-page="admin-system-opkg"\]/:is([data-page="admin-system-opkg"],[data-page="admin-system-package-manager"])/g' \
    "$stylesheet"
done

# Validate argon-config package
argon_config_makefile='package/luci-app-argon-config/Makefile'
test -f "$argon_config_makefile"
argon_config_version="$(sed -n 's/^PKG_VERSION:=//p' \
  "$argon_config_makefile" | head -n 1)"
test -n "$argon_config_version"
case "$argon_config_version" in
  0.9*)
    echo "Obsolete luci-app-argon-config was selected: $argon_config_version" >&2
    exit 1
    ;;
esac

# Copy the complete H5000M overlay, including LuCI temperature status files.
mkdir -p files
cp -a "$project_root/overlay/." files/
chmod +x files/etc/uci-defaults/99-h5000m-zh-tw
chmod +x files/etc/init.d/h5000m-temperature-links

cp "$project_root/config/h5000m.config" .config

if [ "$enable_adguardhome" != 'true' ]; then
  sed -i \
    -e '/^CONFIG_PACKAGE_adguardhome=y$/d' \
    -e '/^CONFIG_PACKAGE_luci-app-adguardhome=y$/d' \
    .config
fi
make defconfig

for required in \
  'CONFIG_PACKAGE_luci-app-qmodem-next=y' \
  'CONFIG_PACKAGE_qmodem=y' \
  'CONFIG_PACKAGE_ndisc6=y' \
  'CONFIG_TARGET_mediatek_filogic_DEVICE_hiveton_h5000m=y' \
  'CONFIG_PACKAGE_luci-ssl-openssl=y'; do
  grep -Fqx "$required" .config || {
    echo "Required build setting is missing: $required" >&2
    exit 1
  }
done

if [ "$enable_adguardhome" = 'true' ]; then
  for required in \
    'CONFIG_PACKAGE_adguardhome=y' \
    'CONFIG_PACKAGE_luci-app-adguardhome=y'; do
    grep -Fqx "$required" .config || {
      echo "Required AdGuard Home setting is missing: $required" >&2
      exit 1
    }
  done
elif grep -Eq '^CONFIG_PACKAGE_(adguardhome|luci-app-adguardhome)=y$' .config; then
  echo 'AdGuard Home was selected even though it was disabled.' >&2
  exit 1
fi

for forbidden in \
  'CONFIG_PACKAGE_luci-app-modem=y' \
  'CONFIG_PACKAGE_luci-app-qmodem=y' \
  'CONFIG_PACKAGE_luci-app-qmodem-sms=y' \
  'CONFIG_PACKAGE_luci-app-qmodem-mwan=y' \
  'CONFIG_PACKAGE_luci-app-qmodem-ttl=y' \
  'CONFIG_PACKAGE_luci-app-qmodem-hc=y' \
  'CONFIG_PACKAGE_wget-nossl=y' \
  'CONFIG_PACKAGE_libustream-mbedtls=y' \
  'CONFIG_PACKAGE_libustream-mbedtls20201210=y'; do
  if grep -Fqx "$forbidden" .config; then
    echo "Conflicting build setting was selected: $forbidden" >&2
    exit 1
  fi
done

if [ "$enable_adguardhome" = 'true' ]; then
  printf 'AdGuard Home: official OpenWrt feeds\n' > .adguardhome-buildinfo
else
  printf 'AdGuard Home: disabled by workflow input\n' > .adguardhome-buildinfo
fi

printf 'Argon theme source: sbwml/luci-theme-argon openwrt-24.10\nArgon config: %s (24.10 visuals with OpenWrt 25/APK compatibility; 0.9.x rejected)\n' \
  "$argon_config_version" > .argon-buildinfo

echo 'Build configuration is ready.'
