#!/usr/bin/ucode -S

'use strict';

/*
 * Auto-update scheduler for "Core Config" subscriptions (custom_profile).
 *
 * This is intentionally a separate script from update_subscriptions.uc,
 * which only handles the regular node subscriptions under the
 * "Subscriptions" tab. The two subscription systems store their data in
 * different UCI sections (custom_profile vs. subscription/node), fetch
 * different content (a full core config file vs. a list of proxy nodes),
 * and are updated through different code paths end to end:
 *
 *   Regular node subscriptions : update_crond.sh -> update_subscriptions.uc
 *   Core Config subscriptions  : this script      -> update_custom_config.uc
 *
 * Keep it that way - do not merge this logic into update_subscriptions.uc
 * or update_crond.sh.
 */

import { lstat } from 'fs';
import { cursor } from 'uci';

import { shellQuote, HP_DIR, RUN_DIR } from 'homeproxy';

const uci = cursor();
const uciconfig = 'homeproxy';
uci.load(uciconfig);

const SUB_DIR = `${HP_DIR}/custom/.subscriptions`;
const now_minute = int(time() / 60);

/* Only restart the service if the subscription being refreshed is the one
 * actually in use right now (main_node = core_only + this profile
 * selected). Restarting for a profile that isn't active would just
 * interrupt whatever config IS currently running, for no benefit. */
const main_node = uci.get(uciconfig, 'config', 'main_node');
const main_core_profile = uci.get(uciconfig, 'config', 'main_core_profile');

uci.foreach(uciconfig, 'custom_profile', (s) => {
	/* profile_id must be the persistent 'id' option, not s['.name'] - the
	 * uci section name is anonymous and gets reassigned by UCI on reload
	 * whenever any custom_profile section is added/removed/reordered, but
	 * main_core_profile and the .subscriptions/*.json cache filename are
	 * both keyed by 'id'. See node.js for where 'id' is generated. */
	const profile_id = s.id;
	const url = s.url;

	if (!profile_id || !url || s.auto_update_enabled !== '1')
		return;

	/* Minutes between auto-updates for this subscription, default 1440 (24h). */
	let interval_min = int(s.auto_update_interval);
	if (!interval_min || interval_min < 1)
		interval_min = 1440;

	const json_path = `${SUB_DIR}/${profile_id}.json`;
	const filestat = lstat(json_path);

	/* Compare by whole minute buckets, not raw elapsed seconds. The fetch
	 * itself takes a few seconds, so the file's mtime always lands a
	 * little after the minute this cron tick fired on; comparing raw
	 * seconds against interval_min*60 then needs one extra full tick
	 * before it clears the threshold (e.g. a 1-minute interval would
	 * only actually fire every 2 minutes). Bucketing by minute removes
	 * that fetch-time skew. */
	const last_minute = filestat ? int(filestat.mtime / 60) : 0;

	if ((now_minute - last_minute) < interval_min)
		return;

	/* Same effect as pressing the "Update" button on this subscription. */
	const exitcode = system(`/usr/bin/ucode -S ${HP_DIR}/scripts/update_custom_config.uc ${shellQuote(profile_id)} >>${RUN_DIR}/homeproxy.log 2>&1`);
	if (exitcode !== 0)
		return;

	const is_active = (main_node === 'core_only') && (main_core_profile === `sub:${profile_id}`);
	if (!is_active)
		return;

	/* Update succeeded and this profile is the one actually running -
	 * restart the service in the background so the new config takes
	 * effect, without blocking this cron run. */
	system(`/etc/init.d/homeproxy restart >>${RUN_DIR}/homeproxy.log 2>&1 &`);
});
