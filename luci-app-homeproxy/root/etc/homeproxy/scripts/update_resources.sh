#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2022-2025 ImmortalWrt.org

NAME="homeproxy"

RESOURCES_DIR="/etc/$NAME/resources"
DASHBOARD_DIR="/etc/$NAME/dashboard"
mkdir -p "$RESOURCES_DIR" "$DASHBOARD_DIR"

RUN_DIR="/var/run/$NAME"
LOG_PATH="$RUN_DIR/$NAME.log"
mkdir -p "$RUN_DIR"

log() {
	echo -e "$(date "+%Y-%m-%d %H:%M:%S") $*" >> "$LOG_PATH"
}

to_upper() {
	echo -e "$1" | tr "[a-z]" "[A-Z]"
}

check_list_update() {
	local listtype="$1"
	local listrepo="$2"
	local listref="$3"
	local listname="$4"
	local lock="$RUN_DIR/update_resources-$listtype.lock"
	local github_token="$(uci -q get homeproxy.config.github_token)"
	local wget="wget --timeout=10 -q"

	exec 200>"$lock"
	if ! flock -n 200 &> "/dev/null"; then
		log "[$(to_upper "$listtype")] A task is already running."
		return 2
	fi

	[ -z "$github_token" ] || github_token="--header=Authorization: Bearer $github_token"
	local list_info="$($wget "${github_token:--q}" -O- "https://api.github.com/repos/$listrepo/commits?sha=$listref&path=$listname&per_page=1")"
	local list_sha="$(echo -e "$list_info" | jsonfilter -qe "@[0].sha")"
	local list_ver="$(echo -e "$list_info" | jsonfilter -qe "@[0].commit.message" | grep -Eo "[0-9-]+" | tr -d '-')"
	if [ -z "$list_sha" ] || [ -z "$list_ver" ]; then
		log "[$(to_upper "$listtype")] Failed to get the latest version, please retry later."
		return 1
	fi

	local local_list_ver="$(cat "$RESOURCES_DIR/$listtype.ver" 2>"/dev/null" || echo "NOT FOUND")"
	if [ "$local_list_ver" = "$list_ver" ]; then
		log "[$(to_upper "$listtype")] Current version: $list_ver."
		log "[$(to_upper "$listtype")] You're already at the latest version."
		return 3
	else
		log "[$(to_upper "$listtype")] Local version: $local_list_ver, latest version: $list_ver."
	fi

	if ! $wget "https://fastly.jsdelivr.net/gh/$listrepo@$list_sha/$listname" -O "$RUN_DIR/$listname" || [ ! -s "$RUN_DIR/$listname" ]; then
		rm -f "$RUN_DIR/$listname"
		log "[$(to_upper "$listtype")] Update failed."
		return 1
	fi

	mv -f "$RUN_DIR/$listname" "$RESOURCES_DIR/$listtype.${listname##*.}"
	echo -e "$list_ver" > "$RESOURCES_DIR/$listtype.ver"
	log "[$(to_upper "$listtype")] Successfully updated."

	return 0
}

check_dashboard_update() {
	local repo="SagerNet/sing-box-dashboard"
	local branch="gh-pages"
	local lock="$RUN_DIR/update_resources-dashboard.lock"
	local github_token="$(uci -q get homeproxy.config.github_token)"
	local wget="wget --timeout=10 -q"

	exec 201>"$lock"
	if ! flock -n 201 &> "/dev/null"; then
		log "[DASHBOARD] A task is already running."
		return 2
	fi

	[ -z "$github_token" ] || github_token="--header=Authorization: Bearer $github_token"
	local commit_info="$($wget "${github_token:--q}" -O- "https://api.github.com/repos/$repo/commits?sha=$branch&per_page=1")"
	local commit_sha="$(echo -e "$commit_info" | jsonfilter -qe "@[0].sha")"
	if [ -z "$commit_sha" ]; then
		log "[DASHBOARD] Failed to get the latest version, please retry later."
		return 1
	fi
	# The dashboard's gh-pages history doesn't carry a clean version
	# number like the other resources' commit messages do, so use the
	# short commit hash as the version string instead. (Using cut here
	# instead of ${var:0:7} - not every busybox ash build has
	# CONFIG_ASH_BASH_COMPAT enabled for that substring syntax.)
	local dashboard_ver="$(echo -e "$commit_sha" | cut -c1-7)"

	local local_dashboard_ver="$(cat "$RESOURCES_DIR/dashboard.ver" 2>"/dev/null" || echo "NOT FOUND")"
	if [ "$local_dashboard_ver" = "$dashboard_ver" ] && [ -s "$DASHBOARD_DIR/index.html" ]; then
		log "[DASHBOARD] Current version: $dashboard_ver."
		log "[DASHBOARD] You're already at the latest version."
		return 3
	else
		log "[DASHBOARD] Local version: $local_dashboard_ver, latest version: $dashboard_ver."
	fi

	local tmp_zip="$RUN_DIR/dashboard.zip"
	local tmp_extract="$RUN_DIR/dashboard-extract"
	rm -rf "$tmp_zip" "$tmp_extract"

	if ! $wget "https://codeload.github.com/$repo/zip/$commit_sha" -O "$tmp_zip" || [ ! -s "$tmp_zip" ]; then
		rm -f "$tmp_zip"
		log "[DASHBOARD] Update failed while downloading the dashboard."
		return 1
	fi

	mkdir -p "$tmp_extract"
	if ! unzip -q -o "$tmp_zip" -d "$tmp_extract"; then
		rm -rf "$tmp_zip" "$tmp_extract"
		log "[DASHBOARD] Update failed while extracting the dashboard."
		return 1
	fi

	# The archive unpacks into a single "<repo>-<sha>" top-level folder.
	# NB: busybox find has no GNU -printf, so locate index.html and strip
	# the filename off with plain parameter expansion instead.
	local index_file="$(find "$tmp_extract" -maxdepth 2 -name "index.html" | head -n1)"
	local src_dir="${index_file%/index.html}"
	if [ -z "$src_dir" ]; then
		rm -rf "$tmp_zip" "$tmp_extract"
		log "[DASHBOARD] Update failed: invalid dashboard archive."
		return 1
	fi

	local dashboard_stage="$DASHBOARD_DIR.new.$$"
	rm -rf "$dashboard_stage"
	if ! cp -a "$src_dir" "$dashboard_stage"; then
		rm -rf "$tmp_zip" "$tmp_extract" "$dashboard_stage"
		log "[DASHBOARD] Update failed while staging the dashboard."
		return 1
	fi

	# Pin known-good permissions on the staged tree before it goes
	# anywhere near $DASHBOARD_DIR. Doing it here (rather than after
	# copying into place) means every file that lands in $DASHBOARD_DIR
	# below - via mkdir -p for new subdirs or the per-file rename - is
	# already 644/755, so the sing-box user (ujail bind-mounts this
	# directory) can always traverse/read it regardless of what
	# permissions busybox cp preserved from the zip/umask.
	chmod 755 "$dashboard_stage"
	find "$dashboard_stage" -type d -exec chmod 755 {} +
	find "$dashboard_stage" -type f -exec chmod 644 {} +

	# Replace files IN PLACE one at a time rather than rm+mv'ing the
	# whole directory or truncate-overwriting existing files with a
	# single recursive cp -a.
	#
	# $DASHBOARD_DIR itself must never be deleted/recreated: it's
	# bind-mounted into the sing-box ujail (procd_add_jail_mount), and
	# sing-box normally keeps running and serving the panel from a
	# long-lived handle on this directory while this update happens.
	# Recreating the directory invalidates both of those (surfaces as
	# "readdirent: no such file or directory" until sing-box/HP is
	# restarted), so every new subdirectory below is created with
	# mkdir -p instead of copying the directory node itself.
	#
	# Each individual file is also replaced atomically: it's copied to
	# a temp name inside $DASHBOARD_DIR first, then renamed over the
	# real path. rename(2) within the same filesystem is atomic and
	# doesn't touch the destination directory's inode, so:
	#   - a request that already has e.g. the old index.html or the
	#     old JS bundle open keeps reading a complete, consistent old
	#     version to the end - no torn/truncated reads mid-update.
	#   - any request that arrives after the rename sees a complete
	#     new file, never a partially-written one.
	# <(...) process substitution is bash-only, not available in
	# busybox ash, so materialize the file list first - same approach
	# already used for stale_list below.
	local new_list="$RUN_DIR/dashboard-new.list"
	find "$dashboard_stage" -type f > "$new_list"
	while read -r src; do
		rel="${src#$dashboard_stage/}"
		dest="$DASHBOARD_DIR/$rel"
		destdir="$(dirname "$dest")"
		if ! mkdir -p "$destdir"; then
			rm -f "$new_list"
			rm -rf "$tmp_zip" "$tmp_extract" "$dashboard_stage"
			log "[DASHBOARD] Update failed: unable to create $destdir."
			return 1
		fi
		tmp="$dest.new.$$"
		if ! cp -a "$src" "$tmp"; then
			rm -f "$tmp" "$new_list"
			rm -rf "$tmp_zip" "$tmp_extract" "$dashboard_stage"
			log "[DASHBOARD] Update failed: unable to stage $rel."
			return 1
		fi
		if ! mv -f "$tmp" "$dest"; then
			rm -f "$tmp" "$new_list"
			rm -rf "$tmp_zip" "$tmp_extract" "$dashboard_stage"
			log "[DASHBOARD] Update failed: unable to place $rel."
			return 1
		fi
	done < "$new_list"
	rm -f "$new_list"

	# Files that are stale as of THIS update are not deleted yet - they
	# are deleted at the START of the NEXT update instead (one update
	# cycle later). This exists because of how the dashboard's service
	# worker (workbox, self.skipWaiting()+clientsClaim()) behaves: a
	# browser tab that begins loading under the OLD service worker can
	# have control handed to the NEW service worker mid-load, after it
	# already resolved index.html to the OLD hashed asset filenames but
	# before it finished requesting them. The new service worker's
	# precache manifest doesn't list those old filenames, so the
	# request falls through to the server - if this update had already
	# deleted them, that's a 404 for a JS/CSS chunk the page needs,
	# which renders as a blank panel until the browser cache is
	# cleared. Keeping last-generation files around for one extra
	# cycle means that request still resolves.
	#
	# Pending list is stored in $RUN_DIR (tmpfs): it doesn't need to
	# survive a reboot, since a reboot restarts sing-box and hands
	# every browser a fresh load anyway.
	local pending_delete="$RUN_DIR/dashboard-pending-delete.list"

	# Consume last run's pending list first: those files have now sat
	# stale for a full cycle and are safe to remove - unless this
	# update happened to reintroduce the same relative path, in which
	# case it's current again and must be kept.
	if [ -s "$pending_delete" ]; then
		while read -r f; do
			rel="${f#$DASHBOARD_DIR/}"
			[ -e "$dashboard_stage/$rel" ] || rm -rf "$f"
		done < "$pending_delete"
	fi

	# Compute this run's stale files (present on disk, absent from the
	# new stage) and save them as the pending list for next time,
	# rather than deleting them now. The listing is materialized to a
	# file first rather than piped straight into the while loop above
	# reused here, so busybox find finishes walking $DASHBOARD_DIR
	# before anything is read back out of it.
	find "$DASHBOARD_DIR" -mindepth 1 > "$pending_delete.tmp"
	: > "$pending_delete"
	while read -r f; do
		rel="${f#$DASHBOARD_DIR/}"
		[ -e "$dashboard_stage/$rel" ] || echo -e "$f" >> "$pending_delete"
	done < "$pending_delete.tmp"
	rm -f "$pending_delete.tmp"

	rm -rf "$dashboard_stage"

	rm -rf "$tmp_zip" "$tmp_extract"
	echo -e "$dashboard_ver" > "$RESOURCES_DIR/dashboard.ver"
	log "[DASHBOARD] Successfully updated."

	return 0
}

case "$1" in
"china_ip4")
	check_list_update "$1" "1715173329/IPCIDR-CHINA" "master" "ipv4.txt"
	;;
"china_ip6")
	check_list_update "$1" "1715173329/IPCIDR-CHINA" "master" "ipv6.txt"
	;;
"gfw_list")
	check_list_update "$1" "Loyalsoldier/v2ray-rules-dat" "release" "gfw.txt"
	;;
"china_list")
	check_list_update "$1" "Loyalsoldier/v2ray-rules-dat" "release" "direct-list.txt" && \
		sed -i -e "s/full://g" -e "/:/d" "$RESOURCES_DIR/china_list.txt"
	;;
"dashboard")
	check_dashboard_update
	;;
*)
	echo -e "Usage: $0 <china_ip4 / china_ip6 / gfw_list / china_list / dashboard>"
	exit 1
	;;
esac
