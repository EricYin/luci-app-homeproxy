
'use strict';
'require form';
'require fs';
'require network';
'require poll';
'require rpc';
'require uci';
'require ui';
'require validation';
'require view';

'require homeproxy as hp';
'require tools.firewall as fwtool';
'require tools.widgets as widgets';

const callReadDomainList = rpc.declare({
	object: 'luci.homeproxy',
	method: 'acllist_read',
	params: ['type'],
	expect: { '': {} }
});

const callWriteDomainList = rpc.declare({
	object: 'luci.homeproxy',
	method: 'acllist_write',
	params: ['type', 'content'],
	expect: { '': {} }
});

const callCurrentNode = rpc.declare({
	object: 'luci.homeproxy',
	method: 'current_node_get',
	expect: { '': {} }
});

function parseDomainList(value) {
	let suffixes = [], keywords = [], normalized = [], seen = Object.create(null);
	for (let item of (value || '').replace(/\r\n?/g, '\n').split('\n')) {
		item = item.trim().toLowerCase();
		if (!item)
			continue;
		item = item.replace(/^\.+|\.+$/g, '');
		if (!item)
			return { error: _('Expecting: %s').format(_('valid hostname')) };
		if (!stubValidator.apply('hostname', item))
			return { error: _('Expecting: %s').format(_('valid hostname')) };
		if (seen[item])
			continue;

		seen[item] = true;
		normalized.push(item);
		(item.includes('.') ? suffixes : keywords).push(item);
	}

	return {
		content: normalized.length ? normalized.join('\n') + '\n' : '',
		suffixes,
		keywords
	};
}

function domainSuffixOverlap(left, right) {
	const endsWithDomain = (value, suffix) =>
		value === suffix || value.endsWith('.' + suffix);
	return endsWithDomain(left, right) || endsWithDomain(right, left);
}

/*
 * Cross-list conflict check, ported from a comparison fork. Fixed one asymmetry
 * bug found in the original: when comparing a keyword entry against a suffix
 * entry, only one direction (suffix.includes(keyword)) was checked there, so a
 * keyword that is a superstring of a suffix (rare, but possible) went
 * undetected. Both directions are now checked for every keyword/suffix pairing.
 */
function findDomainListConflict(groups) {
	let entries = [];
	for (let group of groups) {
		for (let value of group.suffixes)
			entries.push({ group, type: 'suffix', value });
		for (let value of group.keywords)
			entries.push({ group, type: 'keyword', value });
	}

	for (let i = 0; i < entries.length; i++) {
		for (let j = 0; j < i; j++) {
			const left = entries[i], right = entries[j];
			if (left.group.id === right.group.id)
				continue;

			let overlap;
			if (left.type === 'keyword' || right.type === 'keyword') {
				overlap = left.value.includes(right.value) || right.value.includes(left.value);
			} else {
				overlap = domainSuffixOverlap(left.value, right.value);
			}

			if (overlap)
				return { left, right };
		}
	}

	return null;
}

function renderStatus(isRunning, version, currentNodeLabel, currentUdpNodeLabel) {
	let spanTemp = '<em><span style="color:%s"><strong>%s (sing-box v%s) %s</strong></span></em>';
	let renderHTML;
	if (isRunning)
		renderHTML = spanTemp.format('green', _('HomeProxy'), version, _('RUNNING'));
	else
		renderHTML = spanTemp.format('red', _('HomeProxy'), version, _('NOT RUNNING'));

	if (isRunning && currentNodeLabel)
		renderHTML += '<div><em><span style="color:%s"><strong>%s</strong></span></em></div>'.format('#1e90ff', '%h'.format(currentNodeLabel));

	if (isRunning && currentUdpNodeLabel)
		renderHTML += '<div><em><span style="color:%s"><strong>%s</strong></span></em></div>'.format('#1e90ff', '%h'.format(currentUdpNodeLabel));

	return renderHTML;
}

let stubValidator = {
	factory: validation,
	apply(type, value, args) {
		if (value != null)
			this.value = value;

		return validation.types[type].apply(this, args);
	},
	assert(condition) {
		return !!condition;
	}
};

function isNormalModeActive() {
	let main_node = uci.get('homeproxy', 'config', 'main_node');
	return main_node !== 'nil';
}

function noopFeedback() {
	return new Promise((resolve) => setTimeout(resolve, 400));
}

return view.extend({
	load() {
		return Promise.all([
			uci.load('homeproxy'),
			hp.getBuiltinFeatures(),
			network.getHostHints()
		]);
	},

	render(data) {
		let m, s, o, ss, so;

		let features = data[1],
		    hosts = data[2]?.hosts;

		let proxy_nodes = {};
		uci.sections(data[0], 'node', (res) => {
			let nodeaddr = res.address || '',
			    nodeport = res.port || '';

			proxy_nodes[res['.name']] =
				String.format('[%s] %s', res.type, res.label || ((stubValidator.apply('ip6addr', nodeaddr) ?
					String.format('[%s]', nodeaddr) : nodeaddr) + ':' + nodeport));
		});

		function formatDelay(delay) {
			if (delay === null || delay === undefined)
				return '';
			if (delay === 0)
				return ' (%s)'.format(_('timeout'));
			return ' (%dms)'.format(delay);
		}

		function refreshStatus() {
			return L.resolveDefault(hp.getServiceStatus('sing-box-c'), false).then((isRunning) => {
				if (!isRunning)
					return [false, null];
				return L.resolveDefault(callCurrentNode(), null).then((current) => [true, current]);
			}).then((res) => {
				let isRunning = res[0],
				    current = res[1],
				    currentNodeLabel = null,
				    currentUdpNodeLabel = null;

				if (current?.mode === 'urltest') {
					let active = current.active || {};
					let nodeName = (active?.id && active.id !== 'urltest') ?
						(proxy_nodes[active.id] || active.label || active.id) : _('Invalid node');
					currentNodeLabel = _('URLTest: %s').format(nodeName) + formatDelay(current.delay);
				}

				if (current?.udp_mode === 'urltest') {
					let udpActive = current.udp_active || {};
					let udpNodeName = (udpActive?.id && udpActive.id !== 'urltest') ?
						(proxy_nodes[udpActive.id] || udpActive.label || udpActive.id) : _('Invalid node');
					currentUdpNodeLabel = _('UDP URLTest: %s').format(udpNodeName) + formatDelay(current.udp_delay);
				}

				let view = document.getElementById('service_status');
				if (view) view.innerHTML = renderStatus(isRunning, features.version, currentNodeLabel, currentUdpNodeLabel);

				return isRunning;
			});
		}

		m = new form.Map('homeproxy', _('HomeProxy'),
			_('The modern ImmortalWrt proxy platform for ARM64/AMD64.'));

		m.handleSaveApply = function (ev, mode) {
			return form.Map.prototype.handleSaveApply.call(this, ev, mode).then((res) => {
				refreshStatus();
				return res;
			});
		};

		/* Proxy/Direct Domain List content lives outside UCI (RPC-backed files), so it
		 * needs its own load/pending-edit cache to be included in cross-list validation
		 * even for tabs the user never opened this session. */
		let domainListCache = Object.create(null),
		    pendingDomainLists = Object.create(null);

		function loadDomainList(type) {
			if (Object.prototype.hasOwnProperty.call(pendingDomainLists, type))
				return Promise.resolve(pendingDomainLists[type]);

			return L.resolveDefault(callReadDomainList(type), {}).then((res) => {
				domainListCache[type] = res.content || '';
				return domainListCache[type];
			});
		}

		function stageDomainList(type, value) {
			const parsed = parseDomainList(value);
			if (parsed.error)
				throw new TypeError(parsed.error);

			pendingDomainLists[type] = parsed.content;
			domainListCache[type] = parsed.content;
		}

		function domainListContent(type) {
			return Object.prototype.hasOwnProperty.call(pendingDomainLists, type) ?
				pendingDomainLists[type] : (domainListCache[type] || '');
		}

		/* Cross-list conflict check: Proxy/Direct Domain List plus every enabled Proxy
		 * Rules entry that uses a custom inline "Domain list". Throws to block saving. */
		function validateDomainLists() {
			let groups = [
				{ id: 'proxy_list', label: _('Proxy Domain List') },
				{ id: 'direct_list', label: _('Direct Domain List') }
			];

			uci.sections('homeproxy', 'app_rule', (section) => {
				if (section.enabled === '0')
					return;
				if (section.source !== 'custom' || section.custom_mode !== 'domains')
					return;
				const name = (section.custom_service_name || '').trim();
				groups.push({
					id: section['.name'],
					label: name || _('Custom'),
					content: section.custom_domains
				});
			});

			for (let group of groups) {
				const content = Object.prototype.hasOwnProperty.call(group, 'content') ?
					group.content : domainListContent(group.id);
				const parsed = parseDomainList(content);
				if (parsed.error)
					throw new TypeError(_('%s contains an invalid domain.').format(group.label));
				Object.assign(group, parsed);
			}

			const conflict = findDomainListConflict(groups);
			if (conflict)
				throw new TypeError(
					_('Domain %s in %s conflicts with %s in %s.').format(
						conflict.left.value, conflict.left.group.label,
						conflict.right.value, conflict.right.group.label
					)
				);
		}

		function configureDomainListSave(map) {
			const saveMap = map.save;
			map.save = function(cb, silent) {
				return saveMap.call(this, () => Promise.resolve(
					typeof cb === 'function' ? cb() : null
				).then(() => {
					/* Include the Proxy/Direct Domain List tabs even if never opened. */
					return Promise.all(['proxy_list', 'direct_list'].map(loadDomainList));
				}).then(() => {
					validateDomainLists();
					const types = Object.keys(pendingDomainLists);
					if (!types.length)
						return null;

					const lists = Object.assign({}, pendingDomainLists);
					return Promise.all(Object.keys(lists).map((type) =>
						callWriteDomainList(type, lists[type])
					)).then(() => {
						pendingDomainLists = Object.create(null);
					});
				}), silent).catch((error) => {
					if (silent)
						ui.addNotification(null, E('p', {}, error.message), 'error');
					throw error;
				});
			};
		}
		configureDomainListSave(m);

		s = m.section(form.TypedSection);
		s.render = function () {
			poll.add(refreshStatus);

			return E('div', { class: 'cbi-section', id: 'status_bar' }, [
					E('p', { id: 'service_status' }, _('Collecting data...'))
			]);
		}

		s = m.section(form.NamedSection, 'config', 'homeproxy');

		s.tab('routing', _('Routing Settings'));
		s.tab('dashboard', _('Dashboard'));

		o = s.taboption('routing', form.ListValue, 'main_node', _('Main node'));
		o.value('nil', _('Disable'));
		o.value('urltest', _('URLTest'));
		for (let i in proxy_nodes)
			o.value(i, proxy_nodes[i]);
		o.default = 'nil';
		o.rmempty = false;

		o = s.taboption('routing', hp.CBIStaticList, 'main_urltest_nodes', _('URLTest nodes'),
			_('List of nodes to test.'));
		for (let i in proxy_nodes)
			o.value(i, proxy_nodes[i]);
		o.depends('main_node', 'urltest');
		o.rmempty = false;
		o.retain = true;

		o = s.taboption('routing', form.Value, 'main_urltest_interval', _('Test interval'),
			_('The test interval in seconds.'));
		o.datatype = 'uinteger';
		o.placeholder = '180';
		o.depends('main_node', 'urltest');
		o.retain = true;

		o = s.taboption('routing', form.Value, 'main_urltest_tolerance', _('Test tolerance'),
			_('The test tolerance in milliseconds.'));
		o.datatype = 'uinteger';
		o.placeholder = '50';
		o.depends('main_node', 'urltest');
		o.retain = true;

		o = s.taboption('routing', form.Flag, 'main_urltest_interrupt_exist_connections', _('Interrupt existing connections'));
		o.default = o.enabled;
		o.rmempty = false;
		o.depends('main_node', 'urltest');
		o.retain = true;

		o = s.taboption('routing', form.ListValue, 'main_udp_node', _('Main UDP node'));
		o.value('nil', _('Disable'));
		o.value('same', _('Same as main node'));
		o.value('urltest', _('URLTest'));
		for (let i in proxy_nodes)
			o.value(i, proxy_nodes[i]);
		o.default = 'same';
		o.rmempty = false;

		o = s.taboption('routing', hp.CBIStaticList, 'main_udp_urltest_nodes', _('URLTest nodes'),
			_('List of nodes to test.'));
		for (let i in proxy_nodes)
			o.value(i, proxy_nodes[i]);
		o.depends({'main_udp_node': 'urltest'});
		o.rmempty = false;
		o.retain = true;

		o = s.taboption('routing', form.Value, 'main_udp_urltest_interval', _('Test interval'),
			_('The test interval in seconds.'));
		o.datatype = 'uinteger';
		o.placeholder = '180';
		o.depends({'main_udp_node': 'urltest'});
		o.retain = true;

		o = s.taboption('routing', form.Value, 'main_udp_urltest_tolerance', _('Test tolerance'),
			_('The test tolerance in milliseconds.'));
		o.datatype = 'uinteger';
		o.placeholder = '50';
		o.depends({'main_udp_node': 'urltest'});
		o.retain = true;

		o = s.taboption('routing', form.Flag, 'main_udp_urltest_interrupt_exist_connections', _('Interrupt existing connections'));
		o.default = o.enabled;
		o.rmempty = false;
		o.depends({'main_udp_node': 'urltest'});
		o.retain = true;

		o = s.taboption('routing', form.Value, 'dns_server', _('DNS server'),
			_('Support UDP, TCP, DoH, DoQ, DoT. TCP protocol will be used if not specified.'));
		o.value('wan', _('WAN DNS (read from interface)'));
		o.value('1.1.1.1', _('CloudFlare Public DNS (1.1.1.1)'));
		o.value('9.9.9.9', _('Quad9 Public DNS (9.9.9.9)'));
		o.value('8.8.8.8', _('Google Public DNS (8.8.8.8)'));
		o.value('', '---');
		o.value('223.5.5.5', _('Aliyun Public DNS (223.5.5.5)'));
		o.value('180.184.1.1', _('ByteDance Public DNS (180.184.1.1)'));
		o.value('119.29.29.29', _('Tencent Public DNS (119.29.29.29)'));
		o.default = '8.8.8.8';
		o.rmempty = false;
		o.depends({'routing_mode': 'bypass_mainland_china'});
		o.depends({'routing_mode': 'global'});
		o.retain = true;
		o.validate = function(section_id, value) {
			if (section_id && !['wan'].includes(value)) {
				if (!value)
					return _('Expecting: %s').format(_('non-empty value'));

				let ipv6_support = this.section.formvalue(section_id, 'ipv6_support');
				try {
					let url = new URL(value.replace(/^.*:\/\//, 'http://'));
					if (stubValidator.apply('hostname', url.hostname))
						return true;
					else if (stubValidator.apply('ip4addr', url.hostname))
						return true;
					else if ((ipv6_support === '1') && stubValidator.apply('ip6addr', url.hostname.match(/^\[(.+)\]$/)?.[1]))
						return true;
					else
						return _('Expecting: %s').format(_('valid DNS server address'));
				} catch(e) {}

				if (!stubValidator.apply((ipv6_support === '1') ? 'ipaddr' : 'ip4addr', value))
					return _('Expecting: %s').format(_('valid DNS server address'));
			}

			return true;
		}

		o = s.taboption('routing', form.Value, 'china_dns_server', _('China DNS server'),
			_('The dns server for resolving China domains. Support UDP, TCP, DoH, DoQ, DoT.'));
		o.value('wan', _('WAN DNS (read from interface)'));
		o.value('223.5.5.5', _('Aliyun Public DNS (223.5.5.5)'));
		o.value('180.184.1.1', _('ByteDance Public DNS (180.184.1.1)'));
		o.value('119.29.29.29', _('Tencent Public DNS (119.29.29.29)'));
		o.depends({'routing_mode': 'bypass_mainland_china'});
		o.default = '223.5.5.5';
		o.rmempty = false;
		o.retain = true;
		o.validate = function(section_id, value) {
			if (section_id && !['wan'].includes(value)) {
				if (!value)
					return _('Expecting: %s').format(_('non-empty value'));

				try {
					let url = new URL(value.replace(/^.*:\/\//, 'http://'));
					if (stubValidator.apply('hostname', url.hostname))
						return true;
					else if (stubValidator.apply('ip4addr', url.hostname))
						return true;
					else if (stubValidator.apply('ip6addr', url.hostname.match(/^\[(.+)\]$/)?.[1]))
						return true;
					else
						return _('Expecting: %s').format(_('valid DNS server address'));
				} catch(e) {}

				if (!stubValidator.apply('ipaddr', value))
					return _('Expecting: %s').format(_('valid DNS server address'));
			}

			return true;
		}

		o = s.taboption('routing', form.ListValue, 'routing_mode', _('Routing mode'));
		o.value('bypass_mainland_china', _('Bypass mainland China'));
		o.value('global', _('Global'));
		o.default = 'bypass_mainland_china';
		o.rmempty = false;

		o = s.taboption('routing', form.Value, 'routing_port', _('Routing ports'),
			_('Specify target ports to be proxied. Multiple ports must be separated by commas.'));
		o.value('', _('All ports'));
		o.value('common', _('Common ports only (bypass P2P traffic)'));
		o.validate = function(section_id, value) {
			if (section_id && value && value !== 'common') {

				let ports = [];
				for (let i of value.split(',')) {
					if (!stubValidator.apply('port', i) && !stubValidator.apply('portrange', i))
						return _('Expecting: %s').format(_('valid port value'));
					if (ports.includes(i))
						return _('Port %s already exists!').format(i);
					ports = ports.concat(i);
				}
			}

			return true;
		}

		o = s.taboption('routing', form.ListValue, 'proxy_mode', _('Proxy mode'));
		if (features.hp_has_tun) {
			o.value('tun', _('Tun TCP/UDP'));
		} else {
			o.description = _('To enable Tun support, you need to install <code>kmod-tun</code>');
		}
		o.default = 'tun';
		o.rmempty = false;

		o = s.taboption('routing', form.ListValue, 'tcpip_stack', _('TCP/IP stack'),
			_('TCP/IP stack.'));
		if (features.with_gvisor) {
			o.value('mixed', _('Mixed'));
			o.value('gvisor', _('gVisor'));
		}
		o.value('system', _('System'));
		o.default = 'mixed';
		o.depends({'proxy_mode': 'tun'});
		o.rmempty = false;
		o.retain = true;
		o.onchange = function(ev, section_id, value) {
			let desc = ev.target.nextElementSibling;
			if (value === 'mixed')
				desc.innerHTML = _('Mixed <code>system</code> TCP stack and <code>gVisor</code> UDP stack.')
			else if (value === 'gvisor')
				desc.innerHTML = _('Based on google/gvisor.');
			else if (value === 'system')
				desc.innerHTML = _('Less compatibility and sometimes better performance.');
		}

		o = s.taboption('routing', form.Flag, 'ipv6_support', _('IPv6 support'));
		o.default = o.enabled;
		o.rmempty = false;

		s.tab('app_rules', _('Proxy Rules'));
		o = s.taboption('app_rules', form.SectionValue, '_app_rules', form.GridSection, 'app_rule');
		o.depends({'routing_mode': 'bypass_mainland_china', 'proxy_mode': 'tun'});

		ss = o.subsection;
		ss.addremove = true;
		ss.anonymous = true;
		ss.sortable = true;
		ss.nodescriptions = true;

		so = ss.option(form.Flag, 'enabled', _('Enable'));
		so.default = so.enabled;
		so.rmempty = false;
		so.editable = true;

		so = ss.option(form.Value, 'custom_service_name', _('Service name'));
		so.placeholder = _('e.g. My Service');
		so.depends('source', 'custom');
		so.modalonly = true;
		so.retain = true;

		so = ss.option(form.ListValue, 'source', _('Service'));
		so.value('youtube', _('YouTube'));
		so.value('tiktok', _('TikTok'));
		so.value('telegram', _('Telegram'));
		so.value('twitter', _('Twitter/X'));
		so.value('google', _('Google'));
		so.value('cloudflare', _('Cloudflare'));
		so.value('github', _('GitHub'));
		so.value('ai_noncn', _('AI Services (Non-Mainland China)'));
		so.value('custom', _('Custom'));
		so.rmempty = false;

		so.textvalue = function(section_id) {
			if (this.cfgvalue(section_id) === 'custom') {
				const name = (uci.get('homeproxy', section_id, 'custom_service_name') || '').trim();
				return name ? '%h'.format(name) : _('Custom');
			}
			return form.ListValue.prototype.textvalue.apply(this, arguments);
		};
		so.validate = function(section_id, value) {
			if (value === 'custom')
				return true;
			for (const sid of ss.cfgsections()) {
				if (sid !== section_id && this.cfgvalue(sid) === value)
					return _('Duplicate service — only the first rule will take effect');
			}
			return true;
		};

		so = ss.option(form.ListValue, 'custom_mode', _('Custom rule type'));
		so.value('url_domain', _('Domain rule-set'));
		so.value('url_ip', _('IP rule-set'));
		so.value('url_mixed', _('Mixed rule-set (domain + IP)'));
		so.value('domains', _('Domain list'));
		so.default = 'url_domain';
		so.rmempty = false;
		so.depends('source', 'custom');
		so.modalonly = true;
		so.retain = true;

		so = ss.option(form.DynamicList, 'custom_url', _('Domain rule-set URL'));
		so.placeholder = 'https://example.com/rule-set.srs';
		so.depends({'source': 'custom', 'custom_mode': 'url_domain'});
		so.depends({'source': 'custom', 'custom_mode': 'url_mixed'});
		so.modalonly = true;
		so.retain = true;
		so.validate = function(section_id, value) {
			if (section_id && value && !/^https?:\/\/.+/.test(value))
				return _('Expecting: %s').format(_('a valid URL starting with http:// or https://'));
			return true;
		};

		so = ss.option(form.DynamicList, 'custom_url_ip', _('IP rule-set URL'));
		so.placeholder = 'https://example.com/rule-set.srs';
		so.depends({'source': 'custom', 'custom_mode': 'url_ip'});
		so.depends({'source': 'custom', 'custom_mode': 'url_mixed'});
		so.modalonly = true;
		so.retain = true;
		so.validate = function(section_id, value) {
			if (section_id && value && !/^https?:\/\/.+/.test(value))
				return _('Expecting: %s').format(_('a valid URL starting with http:// or https://'));
			return true;
		};

		so = ss.option(form.ListValue, 'custom_format', _('Rule-set format'));
		so.value('binary', _('Binary (.srs)'));
		so.value('source', _('JSON (.json)'));
		so.default = 'binary';
		so.rmempty = false;
		so.depends({'source': 'custom', 'custom_mode': 'url_domain'});
		so.depends({'source': 'custom', 'custom_mode': 'url_ip'});
		so.depends({'source': 'custom', 'custom_mode': 'url_mixed'});
		so.modalonly = true;
		so.retain = true;

		so = ss.option(form.TextValue, 'custom_domains', _('Custom domains'),
			_('One domain (or domain keyword) per line. Matches as a substring, same as the Proxy/Direct Domain List tabs.'));
		so.rows = 5;
		so.monospace = true;
		so.datatype = 'hostname';
		so.depends({'source': 'custom', 'custom_mode': 'domains'});
		so.modalonly = true;
		so.retain = true;
		so.validate = function(section_id, value) {
			if (section_id && value)
				for (let i of value.split('\n')) {
					i = i.trim();
					if (i && !stubValidator.apply('hostname', i))
						return _('Expecting: %s').format(_('valid hostname'));
				}
			return true;
		};

		so = ss.option(form.ListValue, 'node', _('Node'));
		so.value('main-out', _('Same as main node'));
		so.value('urltest', _('Separate URLTest'));
		so.value('direct-out', _('Direct'));
		so.value('reject-out', _('Reject'));
		for (let i in proxy_nodes)
			so.value(i, proxy_nodes[i]);
		so.default = 'main-out';
		so.rmempty = false;
		so.editable = true;

		so = ss.option(hp.CBIStaticList, 'urltest_nodes', _('URLTest nodes'),
			_('List of nodes to test.'));
		for (let i in proxy_nodes)
			so.value(i, proxy_nodes[i]);
		so.depends('node', 'urltest');
		so.rmempty = false;
		so.modalonly = true;
		so.retain = true;

		so = ss.option(form.Value, 'urltest_interval', _('Test interval'),
			_('The test interval in seconds.'));
		so.datatype = 'uinteger';
		so.placeholder = '120';
		so.depends('node', 'urltest');
		so.modalonly = true;
		so.retain = true;

		so = ss.option(form.Value, 'urltest_tolerance', _('Test tolerance'),
			_('The test tolerance in milliseconds.'));
		so.datatype = 'uinteger';
		so.placeholder = '40';
		so.depends('node', 'urltest');
		so.modalonly = true;
		so.retain = true;

		so = ss.option(form.Flag, 'urltest_interrupt_exist_connections', _('Interrupt existing connections'));
		so.default = so.enabled;
		so.rmempty = false;
		so.depends('node', 'urltest');
		so.modalonly = true;
		so.retain = true;

		o = s.taboption('dashboard', form.Value, 'dashboard_port', _('Listen port'));
		o.default = '9096';
		o.datatype = 'port';
		o.rmempty = false;

		o = s.taboption('dashboard', form.Value, 'dashboard_secret', _('API secret'));
		o.password = true;
		o.rmempty = true;

		o = s.taboption('dashboard', form.Button, '_open_dashboard_normal', _('sing-box dashboard'));
		o.inputtitle = _('Open dashboard');
		o.inputstyle = 'apply';
		o.onclick = function() {
			if (!isNormalModeActive())
				return noopFeedback();

			let host = window.location.hostname,
			    port = uci.get('homeproxy', 'config', 'dashboard_port') || '9096';
			if (host.includes(':') && !host.startsWith('['))
				host = '[' + host + ']';
			window.open('http://' + host + ':' + port + '/dashboard/', '_blank', 'noopener,noreferrer');
		};

		s.tab('control', _('Access Control'));

		o = s.taboption('control', form.SectionValue, '_control', form.NamedSection, 'control', 'homeproxy');
		ss = o.subsection;

		ss.tab('interface', _('Interface Control'));

		so = ss.taboption('interface', widgets.DeviceSelect, 'listen_interfaces', _('Listen interfaces'),
			_('Only process traffic from specific interfaces. Leave empty for all.'));
		so.multiple = true;
		so.noaliases = true;

		so = ss.taboption('interface', widgets.DeviceSelect, 'bind_interface', _('Bind interface'),
			_('Bind outbound traffic to specific interface. Leave empty to auto detect.'));
		so.multiple = false;
		so.noaliases = true;

		ss.tab('lan_ip_policy', _('LAN IP Policy'));

		so = ss.taboption('lan_ip_policy', form.ListValue, 'lan_proxy_mode', _('Proxy filter mode'));
		so.value('disabled', _('Disable'));
		so.value('listed_only', _('Proxy listed only'));
		so.value('except_listed', _('Proxy all except listed'));
		so.default = 'disabled';
		so.rmempty = false;

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_direct_ipv4_ips', _('Direct IPv4 IP-s'), null, 'ipv4', hosts, true);
		so.depends({'lan_proxy_mode': 'except_listed'});
		so.retain = true;

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_direct_ipv6_ips', _('Direct IPv6 IP-s'), null, 'ipv6', hosts, true);
		so.depends({'lan_proxy_mode': 'except_listed', 'homeproxy.config.ipv6_support': '1'});
		so.retain = true;

		so = fwtool.addMACOption(ss, 'lan_ip_policy', 'lan_direct_mac_addrs', _('Direct MAC-s'), null, hosts);
		so.depends({'lan_proxy_mode': 'except_listed'});
		so.retain = true;

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_proxy_ipv4_ips', _('Proxy IPv4 IP-s'), null, 'ipv4', hosts, true);
		so.depends({'lan_proxy_mode': 'listed_only'});
		so.retain = true;

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_proxy_ipv6_ips', _('Proxy IPv6 IP-s'), null, 'ipv6', hosts, true);
		so.depends({'lan_proxy_mode': 'listed_only', 'homeproxy.config.ipv6_support': '1'});
		so.retain = true;

		so = fwtool.addMACOption(ss, 'lan_ip_policy', 'lan_proxy_mac_addrs', _('Proxy MAC-s'), null, hosts);
		so.depends({'lan_proxy_mode': 'listed_only'});
		so.retain = true;

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_gaming_mode_ipv4_ips', _('Gaming mode IPv4 IP-s'), null, 'ipv4', hosts, true);

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_gaming_mode_ipv6_ips', _('Gaming mode IPv6 IP-s'), null, 'ipv6', hosts, true);
		so.depends({'homeproxy.config.ipv6_support': '1'});
		so.retain = true;

		so = fwtool.addMACOption(ss, 'lan_ip_policy', 'lan_gaming_mode_mac_addrs', _('Gaming mode MAC-s'), null, hosts);

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_global_proxy_ipv4_ips', _('Global proxy IPv4 IP-s'), null, 'ipv4', hosts, true);

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_global_proxy_ipv6_ips', _('Global proxy IPv6 IP-s'), null, 'ipv6', hosts, true);
		so.depends({'homeproxy.config.ipv6_support': '1'});
		so.retain = true;

		so = fwtool.addMACOption(ss, 'lan_ip_policy', 'lan_global_proxy_mac_addrs', _('Global proxy MAC-s'), null, hosts);

		ss.tab('wan_ip_policy', _('WAN IP Policy'));

		so = ss.taboption('wan_ip_policy', form.DynamicList, 'wan_proxy_ipv4_ips', _('Proxy IPv4 IP-s'));
		so.datatype = 'or(ip4addr, cidr4)';

		so = ss.taboption('wan_ip_policy', form.DynamicList, 'wan_proxy_ipv6_ips', _('Proxy IPv6 IP-s'));
		so.datatype = 'or(ip6addr, cidr6)';
		so.depends({'homeproxy.config.ipv6_support': '1'});
		so.retain = true;

		so = ss.taboption('wan_ip_policy', form.DynamicList, 'wan_direct_ipv4_ips', _('Direct IPv4 IP-s'));
		so.datatype = 'or(ip4addr, cidr4)';

		so = ss.taboption('wan_ip_policy', form.DynamicList, 'wan_direct_ipv6_ips', _('Direct IPv6 IP-s'));
		so.datatype = 'or(ip6addr, cidr6)';
		so.depends({'homeproxy.config.ipv6_support': '1'});
		so.retain = true;

		ss.tab('proxy_domain_list', _('Proxy Domain List'));

		so = ss.taboption('proxy_domain_list', form.TextValue, '_proxy_domain_list');
		so.rows = 10;
		so.monospace = true;
		so.datatype = 'hostname';
		so.load = function() {
			return loadDomainList('proxy_list');
		}
		so.write = function(_section_id, value) {
			stageDomainList('proxy_list', value);
		}
		so.remove = function() {
			stageDomainList('proxy_list', '');
		}
		so.validate = function(section_id, value) {
			if (section_id && value)
				for (let i of value.split('\n'))
					if (i && !stubValidator.apply('hostname', i))
						return _('Expecting: %s').format(_('valid hostname'));

			return true;
		}

		ss.tab('direct_domain_list', _('Direct Domain List'));

		so = ss.taboption('direct_domain_list', form.TextValue, '_direct_domain_list');
		so.rows = 10;
		so.monospace = true;
		so.datatype = 'hostname';
		so.load = function() {
			return loadDomainList('direct_list');
		}
		so.write = function(_section_id, value) {
			stageDomainList('direct_list', value);
		}
		so.remove = function() {
			stageDomainList('direct_list', '');
		}
		so.validate = function(section_id, value) {
			if (section_id && value)
				for (let i of value.split('\n'))
					if (i && !stubValidator.apply('hostname', i))
						return _('Expecting: %s').format(_('valid hostname'));

			return true;
		}

		return m.render();
	}
});
