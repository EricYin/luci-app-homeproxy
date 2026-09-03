#!/bin/sh

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="$REPO_ROOT/luci-app-homeproxy/root/etc/homeproxy/cache"

GH_API="https://api.github.com"

log() {
	printf '[homeproxy] %s\n' "$*"
}

curl_get() {
	if [ -n "$GITHUB_TOKEN" ]; then
		curl -fsSL --connect-timeout 8 --max-time 20 --retry 2 --retry-delay 2 \
			-H "Authorization: Bearer $GITHUB_TOKEN" "$1"
	else
		curl -fsSL --connect-timeout 8 --max-time 20 --retry 2 --retry-delay 2 "$1"
	fi
}

if ! command -v curl >"/dev/null" 2>&1; then
	log "[cache_db] 未检测到 curl，跳过 cache.db 预热，使用仓库内已提交的版本。"
	exit 0
fi
if ! command -v tar >"/dev/null" 2>&1; then
	log "[cache_db] 未检测到 tar，跳过 cache.db 预热，使用仓库内已提交的版本。"
	exit 0
fi

mkdir -p "$CACHE_DIR" 2>"/dev/null"

update_cache_db() {
	release_info="$(curl_get "$GH_API/repos/SagerNet/sing-box/releases?per_page=30")"
	if [ -z "$release_info" ]; then
		log "[cache_db] 无法访问 GitHub API，保留仓库内的兜底版本。"
		return 0
	fi

	singbox_tag=""
	if command -v jq >"/dev/null" 2>&1; then
		singbox_tag="$(printf '%s' "$release_info" \
			| jq -r '[.[] | select(.draft == false and .prerelease == false)][0].tag_name // empty' 2>"/dev/null")"
	fi
	if [ -z "$singbox_tag" ]; then
		log "[cache_db] 未能解析 sing-box 最新版本号，保留仓库内的兜底版本。"
		return 0
	fi

	singbox_ver_num="${singbox_tag#v}"
	tmp_dir="$(mktemp -d)"

	if ! curl -fsSL --connect-timeout 8 --max-time 60 --retry 2 --retry-delay 2 \
		"https://github.com/SagerNet/sing-box/releases/download/$singbox_tag/sing-box-$singbox_ver_num-linux-amd64.tar.gz" \
		-o "$tmp_dir/sing-box.tar.gz" || [ ! -s "$tmp_dir/sing-box.tar.gz" ]; then
		log "[cache_db] sing-box 二进制下载失败，保留仓库内的兜底版本。"
		rm -rf "$tmp_dir"
		return 0
	fi

	if ! tar -xzf "$tmp_dir/sing-box.tar.gz" -C "$tmp_dir"; then
		log "[cache_db] sing-box 压缩包解压失败，保留仓库内的兜底版本。"
		rm -rf "$tmp_dir"
		return 0
	fi

	singbox_bin="$tmp_dir/sing-box-$singbox_ver_num-linux-amd64/sing-box"
	if [ ! -x "$singbox_bin" ]; then
		log "[cache_db] 未找到 sing-box 可执行文件，保留仓库内的兜底版本。"
		rm -rf "$tmp_dir"
		return 0
	fi

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
	        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/cn.srs"
	      },
	      {
	        "type": "remote",
	        "tag": "geosite-cn",
	        "format": "binary",
	        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/cn.srs"
	      },
	      {
	        "type": "remote",
	        "tag": "geosite-noncn",
	        "format": "binary",
	        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/geolocation-!cn.srs"
	      }
	    ],
	    "rules": [
	      { "rule_set": "geoip-cn", "outbound": "direct" },
	      { "rule_set": "geosite-cn", "outbound": "direct" },
	      { "rule_set": "geosite-noncn", "outbound": "direct" }
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

	if [ ! -s "$tmp_dir/cache.db" ]; then
		log "[cache_db] cache.db 未生成，保留仓库内的兜底版本。"
		rm -rf "$tmp_dir"
		return 0
	fi

	mv -f "$tmp_dir/cache.db" "$CACHE_DIR/cache.db"
	chmod 644 "$CACHE_DIR/cache.db"
	log "[cache_db] 已使用 sing-box $singbox_tag 生成 cache.db。"

	rm -rf "$tmp_dir"
}

update_cache_db
exit 0
