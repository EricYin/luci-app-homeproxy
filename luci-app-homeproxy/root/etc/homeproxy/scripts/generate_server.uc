#!/usr/bin/ucode

'use strict';

import { cursor } from 'uci';

import {
	isEmpty, strToBool, strToInt, strToTime,
	removeBlankAttrs, atomicWrite, HP_DIR, RUN_DIR
} from 'homeproxy';

const uci = cursor();

const uciconfig = 'homeproxy';
uci.load(uciconfig);

const uciserver = 'server';

const log_level = uci.get(uciconfig, uciserver, 'log_level') || 'warn';

/* sing-box-extended FATALs with "x_padding_bytes cannot be disabled" whenever xhttp
 * padding resolves to empty: an explicit "0"/"0-0" disables it, and an absent field
 * decodes to "" which counts as disabled too. So the field must always be present
 * and non-empty on every xhttp transport. Coerce any disabling/empty value to a
 * sane default range instead of leaving it empty/omitted. */
function xhttp_padding(v) {
	return (isEmpty(v) || v === '0' || v === '0-0') ? '100-1000' : v;
}

/* Parses a DynamicList of "Key: Value" lines (as used by the xhttp_headers
 * field) into a headers object, or null if there's nothing usable. */
function parseHeaderList(list) {
	if (isEmpty(list))
		return null;

	let headers = {};
	for (let line in list) {
		let pos = index(line, ':');
		if (pos < 0)
			continue;

		let key = trim(substr(line, 0, pos));
		let val = trim(substr(line, pos + 1));
		if (!isEmpty(key))
			headers[key] = val;
	}

	return length(keys(headers)) ? headers : null;
}


const config = {};

config.log = {
	disabled: false,
	level: log_level,
	output: RUN_DIR + '/sing-box-s.log',
	timestamp: true
};

config.inbounds = [];
config.certificate_providers = [];

uci.foreach(uciconfig, uciserver, (cfg) => {
	if (cfg.enabled !== '1')
		return;

	let acme_tag = (cfg.tls === '1' && cfg.tls_acme === '1') ? 'cfg-' + cfg['.name'] + '-acme' : null;
	if (acme_tag)
		push(config.certificate_providers, {
			type: 'acme',
			tag: acme_tag,
			domain: cfg.tls_acme_domain,
			data_directory: HP_DIR + '/certs',
			default_server_name: cfg.tls_acme_dsn,
			email: cfg.tls_acme_email,
			provider: cfg.tls_acme_provider,
			disable_http_challenge: strToBool(cfg.tls_acme_dhc),
			disable_tls_alpn_challenge: strToBool(cfg.tls_acme_dtac),
			alternative_http_port: strToInt(cfg.tls_acme_ahp),
			alternative_tls_port: strToInt(cfg.tls_acme_atp),
			external_account: (cfg.tls_acme_external_account === '1') ? {
				key_id: cfg.tls_acme_ea_keyid,
				mac_key: cfg.tls_acme_ea_mackey
			} : null,
			dns01_challenge: (cfg.tls_dns01_challenge === '1') ? {
				provider: cfg.tls_dns01_provider,
				access_key_id: cfg.tls_dns01_ali_akid,
				access_key_secret: cfg.tls_dns01_ali_aksec,
				region_id: cfg.tls_dns01_ali_rid,
				api_token: cfg.tls_dns01_cf_api_token
			} : null
		});

	push(config.inbounds, {
		type: cfg.type,
		tag: 'cfg-' + cfg['.name'] + '-in',

		listen: cfg.address || '::',
		listen_port: strToInt(cfg.port),
		bind_interface: cfg.bind_interface,
		reuse_addr: strToBool(cfg.reuse_addr),
		tcp_fast_open: strToBool(cfg.tcp_fast_open),
		tcp_multi_path: strToBool(cfg.tcp_multi_path),
		udp_fragment: strToBool(cfg.udp_fragment),
		udp_timeout: strToTime(cfg.udp_timeout),
		network: cfg.network,

		padding_scheme: cfg.anytls_padding_scheme,

		up_mbps: strToInt(cfg.hysteria_up_mbps),
		down_mbps: strToInt(cfg.hysteria_down_mbps),
		obfs: cfg.hysteria_obfs_type ? {
			type: cfg.hysteria_obfs_type,
			password: cfg.hysteria_obfs_password
		} : cfg.hysteria_obfs_password,
		stream_receive_window: strToInt(cfg.hysteria_recv_window_conn),
		connection_receive_window: strToInt(cfg.hysteria_recv_window_client),
		max_concurrent_streams: strToInt(cfg.hysteria_max_conn_client),
		disable_path_mtu_discovery: strToBool(cfg.hysteria_disable_mtu_discovery),
		ignore_client_bandwidth: strToBool(cfg.hysteria_ignore_client_bandwidth),
		masquerade: cfg.hysteria_masquerade,

		method: (cfg.type === 'shadowsocks') ? cfg.shadowsocks_encrypt_method : null,
		password: (cfg.type in ['shadowsocks', 'shadowtls']) ? cfg.password : null,
		decryption: (cfg.type === 'vless') ? (cfg.vless_decryption || null) : null,

		congestion_control: cfg.tuic_congestion_control,
		auth_timeout: strToTime(cfg.tuic_auth_timeout),
		zero_rtt_handshake: strToBool(cfg.tuic_enable_zero_rtt),
		heartbeat: strToTime(cfg.tuic_heartbeat),

		users: (cfg.type !== 'shadowsocks') ? [
			{
				name: !(cfg.type in ['http', 'mixed', 'naive', 'socks']) ? 'cfg-' + cfg['.name'] + '-server' : null,
				username: cfg.username,
				password: cfg.password,

				auth: (cfg.hysteria_auth_type === 'base64') ? cfg.hysteria_auth_payload : null,
				auth_str: (cfg.hysteria_auth_type === 'string') ? cfg.hysteria_auth_payload : null,

				uuid: cfg.uuid,

				flow: cfg.vless_flow,
				alterId: strToInt(cfg.vmess_alterid)
			}
		] : null,

		multiplex: (cfg.multiplex === '1') ? {
			enabled: true,
			padding: strToBool(cfg.multiplex_padding),
			brutal: (cfg.multiplex_brutal === '1') ? {
				enabled: true,
				up_mbps: strToInt(cfg.multiplex_brutal_up),
				down_mbps: strToInt(cfg.multiplex_brutal_down)
			} : null
		} : null,

		tls: (cfg.tls === '1') ? {
			enabled: true,
			server_name: cfg.tls_sni,
			alpn: cfg.tls_alpn,
			min_version: cfg.tls_min_version,
			max_version: cfg.tls_max_version,
			cipher_suites: cfg.tls_cipher_suites,
			certificate_path: cfg.tls_cert_path,
			key_path: cfg.tls_key_path,
			certificate_provider: acme_tag,
			ech: (cfg.tls_ech_key) ? {
				enabled: true,
				key: split(cfg.tls_ech_key, '\n'),
			} : null,
			reality: (cfg.tls_reality === '1') ? {
				enabled: true,
				private_key: cfg.tls_reality_private_key,
				short_id: cfg.tls_reality_short_id,
				max_time_difference: strToTime(cfg.tls_reality_max_time_difference),
				handshake: {
					server: cfg.tls_reality_server_addr,
					server_port: strToInt(cfg.tls_reality_server_port)
					}
			} : null
		} : null,

		transport: !isEmpty(cfg.transport) ? {
			type: cfg.transport,
			host: cfg.http_host || cfg.httpupgrade_host || cfg.xhttp_host,
			path: cfg.http_path || cfg.ws_path || cfg.xhttp_path,
			headers: cfg.ws_host ? {
				Host: cfg.ws_host
			} : ((cfg.transport === 'xhttp') ? parseHeaderList(cfg.xhttp_headers) : null),
			/* "method" is only a real field on the plain http transport;
			 * xhttp has no server-side equivalent at all (uplink_http_method
			 * is client-only - sing-box-extended's dialer picks it, the
			 * server just reads whatever method the client sent). Emitting
			 * "method" under xhttp isn't a field the schema recognizes. */
			method: (cfg.transport === 'http') ? cfg.http_method : null,
			max_early_data: strToInt(cfg.websocket_early_data),
			early_data_header_name: cfg.websocket_early_data_header,
			service_name: cfg.grpc_servicename,
			idle_timeout: strToTime(cfg.http_idle_timeout),
			ping_timeout: strToTime(cfg.http_ping_timeout),

			mode: (cfg.transport === 'xhttp') ? (cfg.xhttp_mode || null) : null,
			x_padding_bytes: (cfg.transport === 'xhttp') ? xhttp_padding(cfg.xhttp_padding_bytes) : null,
			no_sse_header: (cfg.transport === 'xhttp') ? strToBool(cfg.xhttp_no_sse_header) : null,
			sc_max_each_post_bytes: (cfg.transport === 'xhttp') ? strToInt(cfg.xhttp_sc_max_each_post_bytes) : null,
			sc_max_buffered_posts: (cfg.transport === 'xhttp') ? strToInt(cfg.xhttp_sc_max_buffered_posts) : null,
			sc_stream_up_server_secs: (cfg.transport === 'xhttp') ? cfg.xhttp_sc_stream_up_server_secs : null,
			server_max_header_bytes: (cfg.transport === 'xhttp') ? strToInt(cfg.xhttp_server_max_header_bytes) : null,
			trusted_x_forwarded_for: (cfg.transport === 'xhttp') ? (cfg.xhttp_trusted_x_forwarded_for || null) : null,
			congestion_controller: (cfg.transport === 'xhttp') ? (cfg.xhttp_congestion_controller || null) : null,
			cwnd: (cfg.transport === 'xhttp') ? strToInt(cfg.xhttp_cwnd) : null,

			x_padding_obfs_mode: (cfg.transport === 'xhttp') ? strToBool(cfg.xhttp_x_padding_obfs_mode) : null,
			x_padding_placement: (cfg.transport === 'xhttp') ? (cfg.xhttp_x_padding_placement || null) : null,
			x_padding_key: (cfg.transport === 'xhttp') ? (cfg.xhttp_x_padding_key || null) : null,
			x_padding_header: (cfg.transport === 'xhttp') ? (cfg.xhttp_x_padding_header || null) : null,
			x_padding_method: (cfg.transport === 'xhttp') ? (cfg.xhttp_x_padding_method || null) : null,

			session_placement: (cfg.transport === 'xhttp') ? (cfg.xhttp_session_placement || null) : null,
			session_key: (cfg.transport === 'xhttp') ? (cfg.xhttp_session_key || null) : null,

			seq_placement: (cfg.transport === 'xhttp') ? (cfg.xhttp_seq_placement || null) : null,
			seq_key: (cfg.transport === 'xhttp') ? (cfg.xhttp_seq_key || null) : null,

			uplink_data_placement: (cfg.transport === 'xhttp') ? (cfg.xhttp_uplink_data_placement || null) : null,
			uplink_data_key: (cfg.transport === 'xhttp') ? (cfg.xhttp_uplink_data_key || null) : null,
			uplink_chunk_size: (cfg.transport === 'xhttp') ? (cfg.xhttp_uplink_chunk_size || null) : null
			/* "download" is intentionally omitted here: sing-box-extended's
			 * xhttp server (transport/v2rayxhttp/server.go) never reads
			 * options.Download - it's a client-only field (used to dial a
			 * separate stream-down leg, e.g. a different CDN). Emitting it
			 * on the inbound side would be dead configuration. */
		} : null
	});
});

if (length(config.inbounds) === 0)
	exit(1);

if (length(config.certificate_providers) === 0)
	config.certificate_providers = null;

system('mkdir -p ' + RUN_DIR);
atomicWrite(RUN_DIR + '/sing-box-s.json', sprintf('%.J\n', removeBlankAttrs(config)));
