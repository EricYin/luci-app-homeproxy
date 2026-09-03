#!/bin/sh

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
RESOURCES_DIR="$REPO_ROOT/luci-app-homeproxy/root/etc/homeproxy/resources"
DASHBOARD_DIR="$REPO_ROOT/luci-app-homeproxy/root/etc/homeproxy/dashboard"

GH_API="https://api.github.com"

log() {
	printf '[homeproxy] %s\n' "$*"
}

skip() {
	log "[$1] 跳过 $2"
}

curl_get() {
	if [ -n "$GITHUB_TOKEN" ]; then
		curl -fsSL --connect-timeout 8 --max-time 20 --retry 2 --retry-delay 2 \
			-H "Authorization: Bearer $GITHUB_TOKEN" "$1"
	else
		curl -fsSL --connect-timeout 8 --max-time 20 --retry 2 --retry-delay 2 "$1"
	fi
}

json_first_sha() {
	if command -v jq >"/dev/null" 2>&1; then
		jq -r '.[0].sha // empty' 2>"/dev/null"
	else
		grep -o '"sha"[[:space:]]*:[[:space:]]*"[0-9a-f]*"' | head -n1 | sed -E 's/.*"([0-9a-f]+)"$/\1/'
	fi
}

json_first_message() {
	if command -v jq >"/dev/null" 2>&1; then
		jq -r '.[0].commit.message // empty' 2>"/dev/null"
	else
		grep -o '"message"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed -E 's/.*:[[:space:]]*"//;s/"$//'
	fi
}

mkdir -p "$RESOURCES_DIR" "$DASHBOARD_DIR" 2>"/dev/null"

update_list() {
	listtype="$1"
	listrepo="$2"
	listref="$3"
	listname="$4"

	list_info="$(curl_get "$GH_API/repos/$listrepo/commits?sha=$listref&path=$listname&per_page=1")"
	[ -n "$list_info" ] || { skip "$listtype" "无法访问 GitHub API，保留仓库内的版本"; return 0; }

	list_sha="$(printf '%s' "$list_info" | json_first_sha)"
	list_ver="$(printf '%s' "$list_info" | json_first_message | grep -Eo '[0-9-]+' | tr -d '-' | head -n1)"
	[ -n "$list_sha" ] && [ -n "$list_ver" ] || { skip "$listtype" "未能解析最新版本号，保留仓库内的版本"; return 0; }

	local_ver="$(cat "$RESOURCES_DIR/$listtype.ver" 2>"/dev/null")"
	[ "$local_ver" != "$list_ver" ] || { skip "$listtype" "已是最新版本 $list_ver"; return 0; }

	tmpfile="$(mktemp)"
	curl -fsSL --connect-timeout 8 --max-time 30 --retry 2 --retry-delay 2 \
		"https://fastly.jsdelivr.net/gh/$listrepo@$list_sha/$listname" -o "$tmpfile"
	[ -s "$tmpfile" ] || { rm -f "$tmpfile"; skip "$listtype" "下载失败，保留仓库内的版本"; return 0; }

	chmod 644 "$tmpfile"
	mv -f "$tmpfile" "$RESOURCES_DIR/$listtype.${listname##*.}"
	printf '%s\n' "$list_ver" >"$RESOURCES_DIR/$listtype.ver"
	log "[$listtype] 已更新到版本 $list_ver。"

	if [ "$listtype" = "china_list" ]; then
		sed -i -e 's/full://g' -e '/:/d' "$RESOURCES_DIR/china_list.txt"
	fi
}

update_dashboard() {
	repo="SagerNet/sing-box-dashboard"
	branch="gh-pages"

	commit_info="$(curl_get "$GH_API/repos/$repo/commits?sha=$branch&per_page=1")"
	[ -n "$commit_info" ] || { skip "dashboard" "无法访问 GitHub API，保留仓库内的版本"; return 0; }

	commit_sha="$(printf '%s' "$commit_info" | json_first_sha)"
	[ -n "$commit_sha" ] || { skip "dashboard" "未能解析最新版本号，保留仓库内的版本"; return 0; }
	dashboard_ver="$(printf '%.7s' "$commit_sha")"

	local_ver="$(cat "$RESOURCES_DIR/dashboard.ver" 2>"/dev/null")"
	if [ "$local_ver" = "$dashboard_ver" ] && [ -s "$DASHBOARD_DIR/index.html" ]; then
		skip "dashboard" "已是最新版本 $dashboard_ver"
		return 0
	fi

	tmp_zip="$(mktemp)"
	tmp_extract="$(mktemp -d)"

	curl -fsSL --connect-timeout 8 --max-time 60 --retry 2 --retry-delay 2 \
		"https://codeload.github.com/$repo/zip/$commit_sha" -o "$tmp_zip"
	if [ ! -s "$tmp_zip" ]; then
		rm -f "$tmp_zip"; rm -rf "$tmp_extract"
		skip "dashboard" "下载失败，保留仓库内的版本"
		return 0
	fi

	if ! unzip -q -o "$tmp_zip" -d "$tmp_extract"; then
		rm -f "$tmp_zip"; rm -rf "$tmp_extract"
		skip "dashboard" "解压失败，保留仓库内的版本"
		return 0
	fi

	index_file="$(find "$tmp_extract" -maxdepth 2 -name 'index.html' | head -n1)"
	if [ -z "$index_file" ]; then
		rm -f "$tmp_zip"; rm -rf "$tmp_extract"
		skip "dashboard" "压缩包内容异常，保留仓库内的版本"
		return 0
	fi
	src_dir="$(dirname "$index_file")"

	rm -rf "$DASHBOARD_DIR"
	mkdir -p "$DASHBOARD_DIR"
	cp -a "$src_dir"/. "$DASHBOARD_DIR"/
	find "$DASHBOARD_DIR" -type d -exec chmod 755 {} \;
	find "$DASHBOARD_DIR" -type f -exec chmod 644 {} \;

	printf '%s\n' "$dashboard_ver" >"$RESOURCES_DIR/dashboard.ver"
	log "[dashboard] 已更新到版本 $dashboard_ver。"

	rm -f "$tmp_zip"
	rm -rf "$tmp_extract"
}

update_list "china_ip4" "gaoyifan/china-operator-ip" "ip-lists" "china.txt"
update_list "china_ip6" "gaoyifan/china-operator-ip" "ip-lists" "china6.txt"
update_list "gfw_list" "Loyalsoldier/v2ray-rules-dat" "release" "gfw.txt"
update_list "china_list" "Loyalsoldier/v2ray-rules-dat" "release" "direct-list.txt"
update_dashboard

sh "$SCRIPT_DIR/update-cache.sh"

log "全部检查完成。"
exit 0
