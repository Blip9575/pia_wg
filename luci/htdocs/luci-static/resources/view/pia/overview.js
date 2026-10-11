'use strict';
'require view';
'require rpc';
'require ui';
'require poll';
'require dom';

/*
 * PIA VPN: account, interfaces and a wizard to create them.
 * The work is done by pia.sh (api commands) through the rpcd plugin luci.pia.
 */

const callStatus = rpc.declare({ object: 'luci.pia', method: 'status' });
const callRegions = rpc.declare({ object: 'luci.pia', method: 'regions', params: [ 'proto' ] });
const callAccount = rpc.declare({ object: 'luci.pia', method: 'account', params: [ 'id', 'password' ] });
const callAction = rpc.declare({ object: 'luci.pia', method: 'action', params: [ 'name', 'op' ] });
const callGlobal = rpc.declare({ object: 'luci.pia', method: 'global_action', params: [ 'op' ] });
const callJob = rpc.declare({ object: 'luci.pia', method: 'job_status', params: [ 'name' ] });
function routeTaken(name) {
	return _('Default route already assigned to %s. Recommend configuring policy based routing via mwan3 with luci-app-mwan3.').format(name);
}

// the arguments an unchanged setting leaves out: rpcd rejects a null (Invalid argument),
// so they are sent as an object holding only the given ones
const callSaveObj = rpc.declare({
	object: 'luci.pia', method: 'save',
	params: { name: 1, proto: 1, region: 1, fast: 1, dns: 1, mtu: 1, route: 1, firewall: 1, forward: 1, strict: 1 }
});
function callSave(...a) {
	const keys = [ 'name', 'proto', 'region', 'fast', 'dns', 'mtu', 'route', 'firewall', 'forward', 'strict' ];
	const o = {};
	keys.forEach((k, n) => { if (a[n] != null) o[k] = a[n]; });
	return callSaveObj(o);
}
const callRemove = rpc.declare({ object: 'luci.pia', method: 'remove', params: [ 'name' ] });
const callLog = rpc.declare({ object: 'luci.pia', method: 'log', params: [ 'lines' ] });

const PROTOS = [
	[ 'amneziawg', _('AmneziaWG'), _('Recommended to prevent WireGuard traffic being throttled or blocked.') ],
	[ 'wireguard', _('WireGuard'), _('Prone to being blocked or throttled') ],
	[ 'auto', _('Automatic'), _('Try AmneziaWG, fall back to WireGuard') ]
];

function countryName(code) {
	try {
		return new Intl.DisplayNames([ document.documentElement.lang || 'en' ], { type: 'region' }).of(code) || code;
	}
	catch (e) {
		return code;
	}
}

function field(title, control, hint) {
	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title' }, title),
		E('div', { 'class': 'cbi-value-field' }, [ control ].concat(hint ? [ E('div', { 'class': 'cbi-value-description' }, hint) ] : []))
	]);
}

function select(options, value, onchange) {
	return E('select', { 'class': 'cbi-input-select', 'change': onchange },
		options.map(o => E('option', { 'value': o[0], 'selected': o[0] == value ? '' : null }, o[1])));
}

// a select whose help text follows the chosen option: opts = [ [ value, label, help ], … ];
// extra(value) may add a line (it is shown again by show())
function selectHelp(opts, value, onchange, extra) {
	const help = E('div');
	const ctl = {
		help: help,
		show: () => {
			const o = opts.find(x => x[0] == ctl.node.value);
			dom.content(help, [ o && o[2] ? E('div', o[2]) : '', extra ? E('div', extra(ctl.node.value)) : '' ]);
		}
	};
	ctl.node = select(opts, value, ev => {
		ctl.show();
		if (onchange) onchange(ev);
	});
	ctl.show();
	return ctl;
}

function checkbox(checked, onchange) {
	return E('input', { 'type': 'checkbox', 'checked': checked ? '' : null, 'change': onchange });
}

function ago(s) {
	if (s == null) return _('never');
	if (s < 90) return _('%d s ago').format(s);
	if (s < 5400) return _('%d min ago').format(Math.round(s / 60));
	return _('%d h ago').format(Math.round(s / 3600));
}

function fail(res) {
	ui.addNotification(null, E('p', (res && res.error) ? res.error : _('The request failed')), 'danger');
	return false;
}

// the PIA DNS server of a MACE choice and a streaming optimised region (as pia.sh does)
const DNSOPTS = [
	[ 'standard', _('PIA standard'), _('Standard DNS server for PIA') ],
	[ 'mace', _('PIA with MACE'), _('Blocks ads, trackers and malware') ]
];

const MTUOPTS = [
	[ 'std', _('Standard'), _('Recommended for IPv4 + IPv6 traffic') ],
	[ 'small', _('Small'), _('Improve compatibility for mobile networks') ]
];

function dnsFor(st, mace, streaming) {
	const d = st.dns_servers;
	return streaming ? (mace ? d.streaming_mace : d.streaming) : (mace ? d.mace : d.standard);
}

function dnsLabel(st, ip) {
	const d = st.dns_servers, names = {};
	names[d.standard] = _('PIA DNS');
	names[d.streaming] = _('PIA DNS + streaming');
	names[d.mace] = _('PIA DNS + MACE');
	names[d.streaming_mace] = _('PIA DNS + streaming + MACE');
	return (names[ip] || _('DNS')) + ' ' + ip;
}

return view.extend({
	load: function() {
		return callStatus();
	},

	// ---- helpers --------------------------------------------------------

	refresh: function() {
		return callStatus().then(st => {
			this.st = st;
			this.update();
		});
	},

	// poll the job of 'name' until it is done; onupdate(job) on each answer
	waitJob: function(name, onupdate) {
		return new Promise(resolve => {
			const tick = () => callJob(name).then(r => {
				const job = r && r.job;
				if (onupdate) onupdate(job);
				if (job && job.state == 'running')
					setTimeout(tick, 1500);
				else
					resolve(job);
			}).catch(() => setTimeout(tick, 3000));
			setTimeout(tick, 800);
		});
	},

	// run a job (an action of an interface, or a global one) in a modal
	runJob: function(title, name, starter, after) {
		const out = E('pre', { 'style': 'max-height:14em;overflow:auto' }, '');
		const closeBtn = E('button', { 'class': 'cbi-button cbi-button-action', 'disabled': '', 'click': ui.hideModal }, _('Close'));
		ui.showModal(title, [
			E('p', { 'class': 'spinning' }, _('Working…')),
			out,
			E('div', { 'class': 'right' }, [ closeBtn ])
		]);
		return starter().then(res => {
			if (!res || !res.ok) {
				ui.hideModal();
				return fail(res);
			}
			return this.waitJob(name, job => {
				if (job) out.textContent = (job.output || []).join('\n');
			}).then(job => {
				const ok = job && job.state == 'done' && job.rc === 0;
				ui.showModal(title, [
					E('p', ok ? _('Done.') : _('Finished with errors (see below and the log).')),
					E('pre', { 'style': 'max-height:14em;overflow:auto' }, ((job && job.output) || []).join('\n')),
					E('div', { 'class': 'right' }, [ E('button', { 'class': 'cbi-button cbi-button-action', 'click': ui.hideModal }, _('Close')) ])
				]);
				this.refresh();
				this.loadLog();
				if (after) after(ok);
			});
		});
	},

	// ---- account ---------------------------------------------------------

	renderAccount: function() {
		const st = this.st, acc = st.account;
		const idIn = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'value': acc.id || '', 'autocomplete': 'off', 'spellcheck': 'false' });
		const pwIn = E('input', {
			'class': 'cbi-input-password', 'type': 'password', 'autocomplete': 'new-password',
			'placeholder': acc.password_set ? _('(unchanged)') : ''
		});
		let status = _('No account is configured yet.');

		if (acc.id && acc.password_set) {
			if (acc.vpn_expires) {
				const days = Math.floor((acc.vpn_expires - st.now) / 86400);
				status = days > 0 ? _('Logged in; the VPN token is valid for %d more days (renewed automatically).').format(days)
					: _('The VPN token has expired: log in again.');
			}
			else {
				status = _('Account saved; not logged in yet.');
			}
		}

		// the offline cache: servers list, verified meta servers, refresh job
		const c = st.cache || {};
		const when = c.checked || c.updated;
		const cacheLine = [ E('span', c.regions
			? _('%d regions, checked %s').format(c.regions, ago(when ? st.now - when : null))
			: _('no servers list yet')) ];
		if (st.probe && st.probe.state == 'running')
			cacheLine.push(E('small', ' · ' + _('checking which regions need the legacy token…')));
		const cacheWarn = [];
		if (c.regions && when && st.now - when > 3 * 86400)
			cacheWarn.push(_('the list has not been refreshed for over 3 days'));
		if (c.ram)
			cacheWarn.push(_('kept in RAM: lost at a reboot (the cache drive is not mounted)'));
		if (!c.cron)
			cacheWarn.push(_('no automatic refresh is installed'));
		cacheLine.push(E('small', ' · ' + _('%d verified meta servers').format(c.meta || 0)
			+ (c.dir ? ' · ' + c.dir : '') + (c.cron ? ' · ' + _('refreshed every 6 hours') : '')));

		const save = () => {
			const id = idIn.value.trim(), pw = pwIn.value;
			if (!id || (!pw && !acc.password_set))
				return fail({ error: _('Enter the PIA user id (p1234567) and the password') });
			const first = pw ? callAccount(id, pw) : Promise.resolve({ ok: true });
			if (!pw && id != acc.id)
				return fail({ error: _('Enter the password with the new user id') });
			return first.then(r => {
				if (!r || !r.ok) return fail(r);
				pwIn.value = '';
				return this.runJob(_('Logging in to PIA'), '_global', () => callGlobal('login'));
			});
		};

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', _('Account')),
			E('div', { 'class': 'cbi-section-descr' }, _('The PIA subscription login. It is kept on this router only and used to obtain the tokens the VPN servers accept.')),
			field(_('User id'), idIn, _('Starts with a p followed by digits.')),
			field(_('Password'), pwIn),
			E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('Status')),
				E('div', { 'class': 'cbi-value-field' }, status) ]),
			E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('Cache')),
				E('div', { 'class': 'cbi-value-field' }, [ E('div', cacheLine) ].concat(cacheWarn.length
					? [ E('div', { 'class': 'cbi-value-description', 'style': 'color:#d97706' }, '⚠ ' + cacheWarn.join('; ')) ] : [])) ]),
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', { 'class': 'cbi-button cbi-button-save', 'click': ui.createHandlerFn(this, save) }, _('Save and log in')),
				' ',
				E('button', {
					'class': 'cbi-button cbi-button-action',
					'disabled': (acc.id && acc.password_set) ? null : '',
					'click': ui.createHandlerFn(this, () => this.runJob(_('Logging in to PIA'), '_global', () => callGlobal('login')))
				}, _('Renew login')),
				' ',
				E('button', {
					'class': 'cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, () => this.runJob(_('Refreshing the server list'), '_global', () => callGlobal('refresh_cache')))
				}, _('Refresh servers and tokens'))
			])
		]);
	},

	// ---- interfaces ------------------------------------------------------

	stateCell: function(i) {
		if (i.job && i.job.state == 'running')
			return E('span', { 'class': 'spinning' }, _('Working…'));
		if (i.up)
			return E('span', [
				E('strong', { 'style': 'color:#2ea44f' }, '● ' + _('Connected')),
				E('br'),
				E('small', _('handshake %s').format(ago(i.handshake)) + (i.endpoint ? ' · ' + i.endpoint : ''))
			]);
		return E('span', [ E('strong', { 'style': 'opacity:.6' }, '○ ' + _('Stopped')) ]);
	},

	settingsCell: function(i) {
		const parts = [];
		parts.push(dnsLabel(this.st, i.dns_ip));
		parts.push(_('MTU %s').format(i.mtu || _('default')));
		parts.push(i.default_route ? _('default route') : _('no default route'));
		if (i.firewall) parts.push(_('zone %s').format(i.name) + (i.forward.length ? ' ← ' + i.forward.join(', ') : ''));
		if (i.dip) parts.push(_('dedicated IP'));
		return E('small', parts.join(' · '));
	},

	protoLabel: function(i) {
		const n = i.proto == 'amneziawg' ? 'AmneziaWG' : 'WireGuard';
		return i.auto ? _('%s + automatic').format(n) : n;
	},

	renderRows: function() {
		const list = this.st.interfaces;
		if (!list.length)
			return [ E('tr', { 'class': 'tr placeholder' }, [ E('td', { 'class': 'td', 'colspan': 6 },
				E('em', _('No interface yet: use the wizard to create one.'))) ]) ];
		return list.map(i => {
			const busy = i.job && i.job.state == 'running';
			const btn = (cls, label, fn, dis) => E('button', {
				'class': 'cbi-button ' + cls, 'disabled': (busy || dis) ? '' : null, 'click': ui.createHandlerFn(this, fn)
			}, label);
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'data-title': _('Interface') }, E('strong', i.name)),
				E('td', { 'class': 'td', 'data-title': _('Region') }, [
					i.region.name || i.region.id || '-',
					i.fast ? E('small', ' · ' + _('fastest of the country')) : ''
				]),
				E('td', { 'class': 'td', 'data-title': _('Protocol') }, this.protoLabel(i)),
				E('td', { 'class': 'td', 'data-title': _('Settings') }, this.settingsCell(i)),
				E('td', { 'class': 'td', 'data-title': _('State') }, this.stateCell(i)),
				E('td', { 'class': 'td cbi-section-actions' }, E('div', [
					i.up ? btn('cbi-button-action', _('Restart'), () => this.doAction(i.name, 'restart', _('Restarting %s').format(i.name)))
						: btn('cbi-button-action', _('Start'), () => this.doAction(i.name, 'start', _('Starting %s').format(i.name))),
					' ',
					btn('cbi-button-neutral', _('Stop'), () => this.doAction(i.name, 'stop', _('Stopping %s').format(i.name)), !i.up),
					' ',
					btn('cbi-button-edit', _('Edit'), () => this.openEdit(i)),
					' ',
					btn('cbi-button-remove', _('Remove'), () => this.doRemove(i))
				]))
			]);
		});
	},

	doAction: function(name, op, title) {
		return this.runJob(title, name, () => callAction(name, op));
	},

	doRemove: function(i) {
		ui.showModal(_('Remove %s').format(i.name), [
			E('p', _('The interface, its network sections and the firewall zone made for it are removed.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', {
					'class': 'cbi-button cbi-button-negative',
					'click': ui.createHandlerFn(this, () => callRemove(i.name).then(r => {
						ui.hideModal();
						if (!r || !r.ok) return fail(r);
						return this.refresh();
					}))
				}, _('Remove'))
			])
		]);
	},

	renderInterfaces: function() {
		this.tbody = E('tbody', {}, this.renderRows());
		const unavailable = !this.st.awg;
		return E('div', { 'class': 'cbi-section' }, [
			E('h3', _('Interfaces')),
			E('div', { 'class': 'cbi-section-descr' }, _('Each interface is a separate VPN tunnel to a PIA region.')
				+ (unavailable ? ' ' + _('AmneziaWG is not installed (amneziawg-tools, kmod-amneziawg): only WireGuard is offered.') : '')),
			E('div', { 'class': 'table cbi-section-table' }, [
				E('table', { 'class': 'table' }, [
					E('thead', {}, E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, _('Interface')), E('th', { 'class': 'th' }, _('Region')),
						E('th', { 'class': 'th' }, _('Protocol')), E('th', { 'class': 'th' }, _('Settings')),
						E('th', { 'class': 'th' }, _('State')), E('th', { 'class': 'th cbi-section-actions' }, '')
					])),
					this.tbody
				])
			]),
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', {
					'class': 'cbi-button cbi-button-add',
					'disabled': (this.st.account.id && this.st.account.password_set) ? null : '',
					'title': (this.st.account.id && this.st.account.password_set) ? null : _('Save the account first'),
					'click': ui.createHandlerFn(this, () => this.openWizard())
				}, _('Add interface…'))
			])
		]);
	},

	update: function() {
		if (!this.tbody) return;
		dom.content(this.tbody, this.renderRows());
		// the account part is redrawn only when its state changed (not while typing)
		const a = this.st.account, c = this.st.cache || {},
			sig = [ a.id, a.password_set, a.vpn_expires, c.regions, c.checked, c.updated, c.meta, c.ram, c.cron ].join('|');
		if (this.accountBox && sig != this.accSig) {
			this.accSig = sig;
			dom.content(this.accountBox, this.renderAccount());
		}
	},

	// ---- region picker (wizard and edit) ------------------------------------

	// -> { node, get(): { region, fast } }; 'proto' picks the servers list
	regionPicker: function(proto, current, fast, onchange) {
		const box = E('div');
		const state = { region: current ? current.id : '', fast: !!fast, regions: null };
		const self = this;

		const draw = () => {
			const list = state.regions;
			if (!list || !list.length) {
				dom.content(box, [
					E('p', _('The servers list is not loaded.')),
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': ui.createHandlerFn(self, () => self.runJob(_('Refreshing the server list'), '_global', () => callGlobal('refresh_list'), () => load()))
					}, _('Refresh the servers list'))
				]);
				return;
			}
			if (state.ng === undefined) {
				// geo-located servers are left out, unless the region in use is one
				const used = list.find(r => r.id == state.region);
				state.ng = !(used && used.geo);
			}
			const shown = list.filter(r => (!state.so || r.streaming) && (!state.pf || r.port_forward) && (!state.ng || !r.geo));
			const countries = {};
			shown.forEach(r => { countries[r.country] = (countries[r.country] || 0) + 1; });
			const codes = Object.keys(countries).sort((a, b) => countryName(a).localeCompare(countryName(b)));
			const cur = shown.find(r => r.id == state.region);
			if (codes.indexOf(state.country) < 0)
				state.country = cur ? cur.country : (codes.indexOf('GB') >= 0 ? 'GB' : codes[0]);

			const regionSel = E('select', { 'class': 'cbi-input-select', 'change': ev => { state.region = ev.target.value; if (onchange) onchange(); } });
			const fill = () => {
				const items = shown.filter(r => r.country == state.country);
				dom.content(regionSel, items.map(r => E('option', { 'value': r.id, 'selected': r.id == state.region ? '' : null }, r.name)));
				if (!items.some(r => r.id == state.region)) state.region = items.length ? items[0].id : '';
				regionSel.value = state.region;
				if (onchange) onchange();
			};
			const countrySel = select(codes.map(c => [ c, '%s (%d)'.format(countryName(c), countries[c]) ]), state.country, ev => {
				state.country = ev.target.value;
				fill();
			});
			const so = checkbox(state.so, ev => { state.so = ev.target.checked; draw(); });
			const pf = checkbox(state.pf, ev => { state.pf = ev.target.checked; draw(); });
			const ng = checkbox(state.ng, ev => { state.ng = ev.target.checked; draw(); });
			const fastCb = checkbox(state.fast, ev => { state.fast = ev.target.checked; });
			fill();
			dom.content(box, [
				field(_('Country'), countrySel),
				field(_('Streaming optimised only'), so),
				field(_('Port forwarding only'), pf),
				field(_('Non geo-located server'), ng),
				field(_('Fastest region'), fastCb, _('Automatically choose fastest in selected country')),
				field(_('Region Selection'), regionSel)
			]);
		};

		const load = () => callRegions(proto).then(r => {
			state.regions = (r && r.ok && r.regions) || [];
			draw();
		});

		dom.content(box, E('p', { 'class': 'spinning' }, _('Loading the regions…')));
		load();

		return { node: box, get: () => {
			const r = (state.regions || []).find(x => x.id == state.region);
			return { region: state.region, name: r ? r.name : state.region, fast: state.fast, streaming: !!(r && r.streaming) };
		}, state: state };
	},

	// ---- wizard ---------------------------------------------------------------

	openWizard: function() {
		const st = this.st;
		const self = this;
		const others = st.interfaces;
		const holderIf = others.find(i => i.default_route);
		const taken = !!holderIf;
		const d = {
			name: others.some(i => i.name == 'pia') ? '' : 'pia', proto: st.awg ? 'amneziawg' : 'wireguard', dns: 'standard', mtu: 'std',
			route: !taken, firewall: true, forward: st.lan_zone ? [ st.lan_zone ] : [], strict: true
		};
		let picker = null;
		let step = 0;

		const nameOk = n => /^[A-Za-z0-9_]{1,15}$/.test(n) && [ 'account', 'apitoken', 'vpntoken', 'cache', 'log' ].indexOf(n) < 0;

		const steps = [
			{
				title: _('Interface Name'),
				render: () => {
					const inp = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'value': d.name, 'maxlength': 15,
						'placeholder': 'pia', 'spellcheck': 'false' });
					return { node: field(_('Interface Name'), inp, _('Name for interface and firewall zone. Letters, digits and underscore (up to 15)')),
						collect: () => {
							d.name = inp.value.trim();
							if (!nameOk(d.name)) return _('Invalid name: 1 to 15 letters, digits or underscore');
							if (others.some(i => i.name == d.name)) return _('An interface with that name exists');
						} };
				}
			},
			{
				title: _('Protocol Selection'),
				render: () => {
					const c = selectHelp(PROTOS.filter(p => st.awg || p[0] == 'wireguard'), d.proto, null,
						st.awg ? null : () => _('AmneziaWG is not installed on this router.'));
					return { node: field(_('Protocol Selection'), c.node, c.help),
						collect: () => { d.proto = c.node.value; } };
				}
			},
			{
				title: _('Region Selection'),
				render: () => {
					picker = this.regionPicker(d.proto == 'wireguard' ? 'wireguard' : 'amneziawg', d.region, d.fast);
					return { node: picker.node, collect: () => {
						const g = picker.get();
						if (!g.region) return _('Choose a region');
						d.region = { id: g.region };
						d.regionName = g.name;
						d.streaming = g.streaming;
						d.fast = g.fast;
					} };
				}
			},
			{
				title: _('DNS servers'),
				render: () => {
					const c = selectHelp(DNSOPTS, d.dns);
					return { node: field(_('DNS servers'), c.node, c.help), collect: () => { d.dns = c.node.value; } };
				}
			},
			{
				title: _('Packet size'),
				render: () => {
					const c = selectHelp(MTUOPTS, d.mtu);
					return { node: field(_('Packet size (MTU)'), c.node, c.help), collect: () => { d.mtu = c.node.value; } };
				}
			},
			{
				title: _('Routing'),
				render: () => {
					const cb = checkbox(d.route);
					if (taken) {
						cb.disabled = true;
						cb.checked = false;
					}
					return { node: field(_('Default route'), cb, taken
						? routeTaken(holderIf.name)
						: _('Recommended to send all traffic via PIA.')),
						collect: () => { d.route = taken ? false : cb.checked; } };
				}
			},
			{
				title: _('Firewall'),
				render: () => {
					const fw = checkbox(d.firewall);
					const zones = st.zones.filter(z => z != d.name && !/^Block-/.test(z));
					const boxes = zones.map(z => [ z, checkbox(d.forward.indexOf(z) >= 0) ]);
					const st2 = checkbox(d.strict);
					return { node: E('div', [
							field(_('Firewall zone'), fw, _('Recommended to create zone with NAT and MSS clamping')),
							field(_('Allow forwarding from'), E('div', boxes.map(b => E('label', { 'style': 'margin-right:1em' }, [ b[1], ' ', b[0] ]))),
								_('The zones whose traffic may go through this VPN.')),
							field(_('PIA DNS Server'), st2, _('Recommended to prevent DNS leakage'))
						]),
						collect: () => {
							d.firewall = fw.checked;
							d.forward = boxes.filter(b => b[1].checked).map(b => b[0]);
							d.strict = st2.checked;
						} };
				}
			},
			{
				title: _('Review'),
				render: () => {
					const rows = [
						[ _('Interface Name'), d.name ],
						[ _('Protocol Selection'), PROTOS.filter(p => p[0] == d.proto)[0][1] ],
						[ _('Region Selection'), d.regionName + (d.fast ? ' · ' + _('fastest of its country at each start') : '') ],
						[ _('DNS servers'), dnsLabel(st, dnsFor(st, d.dns == 'mace', d.streaming)) ],
						[ _('Packet size'), d.mtu == 'std' ? _('Standard (%d)').format(st.std_mtu) : _('Small (%d)').format(st.small_mtu) ],
						[ _('Default route'), d.route ? _('yes') : _('no') ],
						[ _('Firewall'), d.firewall ? _('zone %s, forwarding from: %s').format(d.name, d.forward.join(', ') || _('none')) : _('none') ]
					];
					return { node: E('div', rows.map(r => field(r[0], E('span', r[1])))), collect: () => null };
				}
			}
		];

		const show = () => {
			const s = steps[step];
			const r = s.render();
			const err = E('div', { 'class': 'alert-message warning', 'style': 'display:none' });
			const last = step == steps.length - 1;
			const go = dir => {
				const e = r.collect();
				if (e) {
					err.textContent = e;
					err.style.display = '';
					return;
				}
				if (dir > 0 && last) return create();
				step += dir;
				show();
			};
			ui.showModal(_('Add interface') + ' – ' + s.title + ' (%d/%d)'.format(step + 1, steps.length), [
				r.node,
				err,
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')), ' ',
					E('button', { 'class': 'cbi-button', 'disabled': step ? null : '',
						'click': () => { r.collect(); step--; show(); } }, _('Back')), ' ',
					E('button', { 'class': 'cbi-button cbi-button-positive important', 'click': () => go(1) },
						last ? _('Create') : _('Next'))
				])
			]);
		};

		const create = () => {
			ui.showModal(_('Add interface'), E('p', { 'class': 'spinning' }, _('Creating the interface…')));
			callSave(d.name, d.proto, d.region.id, d.fast ? '1' : '0', d.dns, d.mtu, d.route ? 'yes' : 'no',
				d.firewall ? 'yes' : 'no', d.firewall ? d.forward.join(' ') : null, d.strict ? 'yes' : 'no').then(r => {
				if (!r || !r.ok) {
					ui.hideModal();
					return fail(r);
				}
				this.refresh();
				ui.showModal(_('Interface %s created').format(d.name), [
					E('p', _('Start it now? The first start registers a key with PIA and can take up to a minute.')),
					E('div', { 'class': 'right' }, [
						E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Later')), ' ',
						E('button', { 'class': 'cbi-button cbi-button-positive important',
							'click': () => this.doAction(d.name, 'start', _('Starting %s').format(d.name)) }, _('Start'))
					])
				]);
			});
		};

		show();
	},

	// ---- edit --------------------------------------------------------------------

	openEdit: function(i) {
		const st = this.st;
		const protoCtl = selectHelp(PROTOS.filter(p => st.awg || p[0] == 'wireguard'),
			i.auto ? 'auto' : i.proto, null,
			() => i.dip ? _('A dedicated IP needs WireGuard.') : _('Changing the protocol makes a new key and the region must have servers for it.'));
		const protoSel = protoCtl.node;
		if (i.dip) protoSel.disabled = true;
		const dnsCtl = selectHelp(DNSOPTS, i.dns == 'mace' ? 'mace' : 'standard');
		const cur = i.mtu;
		const custom = (cur && cur != st.std_mtu && cur != st.small_mtu) ? [ [ String(cur), _('Custom (%d)').format(cur), '' ] ] : [];
		const mtuCtl = selectHelp(MTUOPTS.concat(custom), !cur || cur == st.std_mtu ? 'std' : cur == st.small_mtu ? 'small' : String(cur));
		const holder = st.interfaces.find(o => o.name != i.name && o.default_route);
		const routeCb = checkbox(i.default_route);
		if (holder) routeCb.disabled = true;
		const fwCb = checkbox(i.firewall);
		const zones = st.zones.filter(z => z != i.name && !/^Block-/.test(z));
		const boxes = zones.map(z => [ z, checkbox(i.forward.indexOf(z) >= 0) ]);

		const regionBox = E('div');
		let picker = null;
		if (i.dip) {
			dom.content(regionBox, field(_('Region Selection'), E('span', i.region.name), _('Set by the dedicated IP.')));
		}
		else {
			picker = this.regionPicker(i.proto, i.region.id ? { id: i.region.id } : null, i.fast);
			dom.content(regionBox, picker.node);
		}

		const save = restart => {
			const g = picker ? picker.get() : null;
			ui.showModal(_('Saving %s').format(i.name), E('p', { 'class': 'spinning' }, _('Saving…')));
			return callSave(i.name, protoSel.value, g ? g.region : null, g ? (g.fast ? '1' : '0') : null, dnsCtl.node.value, mtuCtl.node.value,
				routeCb.disabled ? null : (routeCb.checked ? 'yes' : 'no'), fwCb.checked ? 'yes' : 'no',
				fwCb.checked ? boxes.filter(b => b[1].checked).map(b => b[0]).join(' ') : null, null).then(r => {
				ui.hideModal();
				if (!r || !r.ok) return fail(r);
				this.refresh();
				if (restart) return this.doAction(i.name, 'restart', _('Restarting %s').format(i.name));
				if (i.up)
					ui.addNotification(null, E('p', _('Saved. The changes apply when %s is restarted.').format(i.name)), 'info');
			});
		};

		ui.showModal(_('Settings of %s').format(i.name), [
			field(_('Protocol Selection'), protoSel, protoCtl.help),
			regionBox,
			field(_('DNS servers'), dnsCtl.node, dnsCtl.help),
			field(_('Packet size (MTU)'), mtuCtl.node, mtuCtl.help),
			field(_('Default route'), routeCb, holder ? routeTaken(holder.name) : null),
			field(_('Firewall zone'), fwCb),
			field(_('Allow forwarding from'), E('div', boxes.map(b => E('label', { 'style': 'margin-right:1em' }, [ b[1], ' ', b[0] ])))),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'cbi-button cbi-button-save', 'click': ui.createHandlerFn(this, () => save(false)) }, _('Save')), ' ',
				E('button', { 'class': 'cbi-button cbi-button-positive important', 'click': ui.createHandlerFn(this, () => save(true)) }, _('Save and restart'))
			])
		]);
	},

	// ---- log ------------------------------------------------------------------------

	loadLog: function() {
		return callLog(60).then(r => {
			if (this.logBox) this.logBox.textContent = (r && r.log) ? r.log : _('The log is empty.');
		});
	},

	renderLog: function() {
		this.logBox = E('pre', { 'style': 'max-height:18em;overflow:auto' }, _('Loading…'));
		this.loadLog();
		return E('div', { 'class': 'cbi-section' }, [
			E('h3', _('Log')),
			this.logBox,
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', { 'class': 'cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, () => this.loadLog()) }, _('Reload'))
			])
		]);
	},

	// ---- page ---------------------------------------------------------------------------

	render: function(st) {
		this.st = st;
		const a = st.account, c = st.cache || {};
		this.accSig = [ a.id, a.password_set, a.vpn_expires, c.regions, c.checked, c.updated, c.meta, c.ram, c.cron ].join('|');
		this.accountBox = E('div', {}, [ this.renderAccount() ]);
		const page = E('div', {}, [
			E('h2', _('PIA VPN')),
			E('div', { 'class': 'cbi-map-descr' }, _('Private Internet Access over WireGuard and AmneziaWG (pia.sh %s).').format(st.version)),
			this.accountBox,
			this.renderInterfaces(),
			this.renderLog()
		]);
		poll.add(() => this.refresh(), 5);
		return page;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
