#!/bin/sh

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="$REPO_ROOT/luci-app-homeproxy/root/etc/homeproxy/cache"

GH_API="https://api.github.com"

log() {
	printf '[homeproxy] %s\n' "$*"
}

skip() {
	log "[cache_db] Skip: $1"
	exit 0
}

curl_get() {
	if [ -n "$GITHUB_TOKEN" ]; then
		curl -fsSL --connect-timeout 8 --max-time 20 --retry 2 --retry-delay 2 \
			-H "Authorization: Bearer $GITHUB_TOKEN" "$1"
	else
		curl -fsSL --connect-timeout 8 --max-time 20 --retry 2 --retry-delay 2 "$1"
	fi
}

mkdir -p "$CACHE_DIR" 2>"/dev/null"

release_info="$(curl_get "$GH_API/repos/SagerNet/sing-box/releases?per_page=30")"
[ -n "$release_info" ] || skip "Failed to access API, keeping local cache.db"

singbox_tag=""
if command -v jq >"/dev/null" 2>&1; then
	singbox_tag="$(printf '%s' "$release_info" \
		| jq -r '[.[] | select(.draft == false and .prerelease == false)][0].tag_name // empty' 2>"/dev/null")"
fi
[ -n "$singbox_tag" ] || skip "Failed to parse latest sing-box tag, keeping local cache.db"

singbox_ver_num="${singbox_tag#v}"
tmp_dir="$(mktemp -d)"

curl -fsSL --connect-timeout 8 --max-time 60 --retry 2 --retry-delay 2 \
	"https://github.com/SagerNet/sing-box/releases/download/$singbox_tag/sing-box-$singbox_ver_num-linux-amd64.tar.gz" \
	-o "$tmp_dir/sing-box.tar.gz"
[ -s "$tmp_dir/sing-box.tar.gz" ] || { rm -rf "$tmp_dir"; skip "Failed to download sing-box binary, keeping local cache.db"; }

tar -xzf "$tmp_dir/sing-box.tar.gz" -C "$tmp_dir" || { rm -rf "$tmp_dir"; skip "Failed to extract sing-box archive, keeping local cache.db"; }

singbox_bin="$tmp_dir/sing-box-$singbox_ver_num-linux-amd64/sing-box"
[ -x "$singbox_bin" ] || { rm -rf "$tmp_dir"; skip "sing-box executable not found, keeping local cache.db"; }

cat >"$tmp_dir/config.json" <<-'EOF'
{
  "log": { "level": "warn", "timestamp": true },
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rule_set": [
      {
        "type": "remote",
        "tag": "geoip-cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs"
      },
      {
        "type": "remote",
        "tag": "geosite-cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs"
      },
      {
        "type": "remote",
        "tag": "geosite-noncn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs"
      },
      {
        "type": "remote",
        "tag": "gfw-list",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/gfw.srs"
      },
      {
        "type": "remote",
        "tag": "app-rule-youtube-domain",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/youtube.srs"
      },
      {
        "type": "remote",
        "tag": "app-rule-tiktok-domain",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/tiktok.srs"
      },
      {
        "type": "remote",
        "tag": "app-rule-telegram-domain",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/telegram.srs"
      },
      {
        "type": "remote",
        "tag": "app-rule-telegram-ip",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/telegram.srs"
      },
      {
        "type": "remote",
        "tag": "app-rule-twitter-domain",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/twitter.srs"
      },
      {
        "type": "remote",
        "tag": "app-rule-twitter-ip",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/twitter.srs"
      },
      {
        "type": "remote",
        "tag": "app-rule-google-domain",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/google.srs"
      },
      {
        "type": "remote",
        "tag": "app-rule-google-ip",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/google.srs"
      },
      {
        "type": "remote",
        "tag": "app-rule-cloudflare-domain",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/cloudflare.srs"
      },
      {
        "type": "remote",
        "tag": "app-rule-cloudflare-ip",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/cloudflare.srs"
      },
      {
        "type": "remote",
        "tag": "app-rule-github-domain",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/github.srs"
      },
      {
        "type": "remote",
        "tag": "app-rule-ai_noncn-domain",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/category-ai-!cn.srs"
      }
    ],
    "rules": [
      { "rule_set": "geoip-cn", "outbound": "direct" },
      { "rule_set": "geosite-cn", "outbound": "direct" },
      { "rule_set": "geosite-noncn", "outbound": "direct" },
      { "rule_set": "gfw-list", "outbound": "direct" },
      { "rule_set": "app-rule-youtube-domain", "outbound": "direct" },
      { "rule_set": "app-rule-tiktok-domain", "outbound": "direct" },
      { "rule_set": "app-rule-telegram-domain", "outbound": "direct" },
      { "rule_set": "app-rule-telegram-ip", "outbound": "direct" },
      { "rule_set": "app-rule-twitter-domain", "outbound": "direct" },
      { "rule_set": "app-rule-twitter-ip", "outbound": "direct" },
      { "rule_set": "app-rule-google-domain", "outbound": "direct" },
      { "rule_set": "app-rule-google-ip", "outbound": "direct" },
      { "rule_set": "app-rule-cloudflare-domain", "outbound": "direct" },
      { "rule_set": "app-rule-cloudflare-ip", "outbound": "direct" },
      { "rule_set": "app-rule-github-domain", "outbound": "direct" },
      { "rule_set": "app-rule-ai_noncn-domain", "outbound": "direct" }
    ],
    "final": "direct"
  },
  "experimental": {
    "cache_file": {
      "enabled": true,
      "path": "cache.db"
    }
  }
}
EOF

rm -f "$tmp_dir/cache.db"

(
	cd "$tmp_dir" || exit 1
	"$singbox_bin" run -c config.json >"/dev/null" 2>&1 &
	echo $! >"$tmp_dir/singbox.pid"
)
singbox_pid="$(cat "$tmp_dir/singbox.pid" 2>"/dev/null")"

i=0
while [ "$i" -lt 30 ]; do
	sleep 1
	if [ -s "$tmp_dir/cache.db" ]; then
		sleep 5
		break
	fi
	i=$((i + 1))
done

[ -n "$singbox_pid" ] && kill "$singbox_pid" 2>"/dev/null"
[ -n "$singbox_pid" ] && wait "$singbox_pid" 2>"/dev/null"

[ -s "$tmp_dir/cache.db" ] || { rm -rf "$tmp_dir"; skip "cache.db was not generated, keeping local cache.db"; }

rm -f "$CACHE_DIR/cache.db"
mv -f "$tmp_dir/cache.db" "$CACHE_DIR/cache.db"
chmod 644 "$CACHE_DIR/cache.db"
log "[cache_db] Generated cache.db using sing-box $singbox_tag"

rm -rf "$tmp_dir"
exit 0
