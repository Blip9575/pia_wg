'use strict';
'require view';
'require rpc';
'require ui';
'require poll';
'require dom';

/*
 * PIA VPN: account and interfaces (one dialog to add or edit).
 * The work is done by pia.sh (api commands) through the rpcd plugin luci.pia.
 */

const callStatus = rpc.declare({ object: 'luci.pia', method: 'status' });
const callRegions = rpc.declare({ object: 'luci.pia', method: 'regions', params: [ 'proto' ] });
const callAccount = rpc.declare({ object: 'luci.pia', method: 'account', params: { id: 1, password: 1, path: 1 } });
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
	params: { name: 1, proto: 1, region: 1, fast: 1, dns: 1, dns_ip: 1, mtu: 1, keepalive: 1, route: 1, firewall: 1, forward: 1, killswitch: 1, ks_wan: 1, boot_delay: 1, portfwd: 1, pf_ip: 1, pf_port: 1, boot: 1, failover: 1, dns_redirect: 1 }
});
function callSave(args) {
	const o = {};
	Object.keys(args).forEach(k => { if (args[k] != null) o[k] = args[k]; });
	return callSaveObj(o);
}
const callPing = rpc.declare({ object: 'luci.pia', method: 'ping_regions', params: [ 'proto', 'ids' ] });
const callRemove = rpc.declare({ object: 'luci.pia', method: 'remove', params: [ 'name' ] });
const callLog = rpc.declare({ object: 'luci.pia', method: 'log', params: [ 'lines' ] });
const callHistory = rpc.declare({ object: 'luci.pia', method: 'history' });

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

function pad2(n) {
	return String(n).padStart(2, '0');
}

// seconds since the epoch -> 2026/10/13 and 20:27:55, in UTC
function utcDate(t) {
	const d = new Date(t * 1000);
	return '%d/%s/%s'.format(d.getUTCFullYear(), pad2(d.getUTCMonth() + 1), pad2(d.getUTCDate()));
}

function utcTime(t) {
	const d = new Date(t * 1000);
	return '%s:%s:%s'.format(pad2(d.getUTCHours()), pad2(d.getUTCMinutes()), pad2(d.getUTCSeconds()));
}

function fail(res) {
	ui.addNotification(null, E('p', (res && res.error) ? res.error : _('The request failed')), 'danger');
	return false;
}

// the PIA DNS server of a MACE choice and a streaming optimised region (as pia.sh does)
const DNSOPTS = [
	[ 'standard', _('PIA'), _('Recommended for PIA.') ],
	[ 'mace', _('PIA with MACE'), _('Blocks ads, trackers and malware') ],
	[ 'custom', _('Custom'), _('Provide DNS server address') ]
];

const MTU_MIN = 1280, MTU_MAX = 1420, KEEPALIVE = 25, STALE = 180;
const KEEPOPTS = [
	[ 'default', _('Default (%d)').format(KEEPALIVE), _('The value of the official PIA apps.') ],
	[ 'off', _('Disabled (0)'), _('No keepalive packets: a NAT or firewall in between may drop the idle tunnel, and the guard (which looks for a stale handshake) is switched off.') ],
	[ 'custom', _('Custom'), _('Seconds between keepalive packets.') ]
];

// a number-only input: digits are all it takes; ok() tells if the value is in range
function numInput(value, placeholder) {
	const inp = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'inputmode': 'numeric', 'pattern': '[0-9]*',
		'maxlength': 5, 'size': 8, 'value': value != null ? String(value) : '', 'placeholder': placeholder || '', 'style': 'margin-top:.4em' });
	inp.addEventListener('input', () => { inp.value = inp.value.replace(/[^0-9]/g, ''); });
	return inp;
}

const IPV4 = /^((25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])$/;

// a select with an extra input shown for its 'custom' choice
function withInput(ctl, input) {
	const box = E('div', [ ctl.node, input ]);
	const sync = () => { input.style.display = ctl.node.value == 'custom' ? '' : 'none'; };
	ctl.node.addEventListener('change', sync);
	sync();
	return box;
}

// the packet sizes: standard follows the WAN (st.std_mtu), the others are fixed
function mtuOpts(st) {
	return [
		[ 'std', _('Default (%d)').format(st.std_mtu), _('Recommended: follows the WAN connection (its MTU minus 60, at most 1420)') ],
		[ 'small', _('Small (%d)').format(st.small_mtu), _('Improve compatibility for mobile networks') ],
		[ 'custom', _('Custom'), _('Provide MTU value') ]
	];
}

function dnsFor(st, mace, streaming) {
	const d = st.dns_servers;
	return streaming ? (mace ? d.streaming_mace : d.streaming) : (mace ? d.mace : d.standard);
}

// the name of the chosen DNS option
function dnsLabel(i) {
	const o = DNSOPTS.find(o => o[0] == i.dns);
	return o ? o[1] : String(i.dns_ip);
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
				// after() may take over the window (a promise or value of true)
				return Promise.resolve(after ? after(ok) : null).then(handled => {
					if (handled !== true)
						ui.showModal(title, [
							E('p', ok ? _('Done.') : _('Finished with errors (see below and the log).')),
							E('pre', { 'style': 'max-height:14em;overflow:auto' }, ((job && job.output) || []).join('\n')),
							E('div', { 'class': 'right' }, [ E('button', { 'class': 'cbi-button cbi-button-action', 'click': ui.hideModal }, _('Close')) ])
						]);
					this.refresh();
					this.loadLog();
				});
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
		const pathIn = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'value': (st.cache && st.cache.path) || '/mnt/usb/pia',
			'spellcheck': 'false', 'autocomplete': 'off' });
		const have = !!(acc.id && acc.password_set);
		const c = st.cache || {};
		const when = c.checked || c.updated;
		const loggedIn = have && acc.vpn_expires && acc.vpn_expires > st.now;

		let loginStatus = _('No account is configured yet.');
		if (have)
			loginStatus = loggedIn ? _('Logged in') : _('Not logged in');
		// all times in UTC, year/month/day (PIA's tokens expire at 00:00 UTC, so only the date is shown)
		let tokenStatus = _('No token');
		if (have && acc.vpn_expires)
			tokenStatus = utcDate(acc.vpn_expires) + ' ' + (acc.vpn_expires > st.now
				? (days => days == 1 ? _('(1 day)') : _('(%d days)').format(days))(Math.floor((acc.vpn_expires - st.now) / 86400))
				: _('(expired: log in again)'));

		const cacheLine = c.regions
			? '%s (%d regions · %d meta servers)'.format(when ? utcDate(when) + ' ' + utcTime(when) + ' UTC' : _('never'), c.regions, c.meta || 0)
			: _('No servers list yet');
		const cacheWarn = [];
		if (c.regions && when && st.now - when > 3 * 86400)
			cacheWarn.push(_('the list has not been refreshed for over 3 days'));
		if (c.ram)
			cacheWarn.push(_('kept in RAM: lost at a reboot (the cache drive is not mounted)'));
		if (!c.cron)
			cacheWarn.push(_('no automatic refresh is installed'));
		const cacheNote = [];
		if (st.probe && st.probe.state == 'running')
			cacheNote.push(E('div', { 'class': 'cbi-value-description' }, _('checking which regions need the legacy token…')));
		if (cacheWarn.length)
			cacheNote.push(E('div', { 'class': 'cbi-value-description', 'style': 'color:#d97706' }, '⚠ ' + cacheWarn.join('; ')));

		// login, then the servers and tokens, then (nothing configured yet) the Add interface dialog
		const loginAndRefresh = () => this.runJob(_('Logging in to PIA'), '_global', () => callGlobal('login'), ok => {
			if (!ok) return false;
			this.runJob(_('Refreshing the server list & VPN token'), '_global', () => callGlobal('refresh_cache'), () =>
				this.refresh().then(() => {
					if (this.st.interfaces.length || !(this.st.cache && this.st.cache.regions)) return false;
					this.openForm(null);
					return true;
				}));
			return true;
		});

		const save = () => {
			const id = idIn.value.trim(), pw = pwIn.value, path = pathIn.value.trim() || '/mnt/usb/pia';
			if (!id || (!pw && !acc.password_set))
				return fail({ error: _('Enter your PIA username and password') });
			if (!pw && id != acc.id)
				return fail({ error: _('Enter the password with the new username') });
			// written to flash only when something changed
			const changed = pw || id != acc.id || path != ((st.cache && st.cache.path) || '/mnt/usb/pia');
			const first = changed ? callAccount({ id: id, password: pw, path: path }) : Promise.resolve({ ok: true });
			return first.then(r => {
				if (!r || !r.ok) return fail(r);
				pwIn.value = '';
				return loginAndRefresh();
			});
		};

		const row = (title, ...content) => E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, title),
			E('div', { 'class': 'cbi-value-field' }, content) ]);

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', _('Sign in to your account')),
			E('div', { 'class': 'cbi-section-descr' }, _('PIA credentials.')),
			field(_('Username'), idIn, _('Enter your PIA username')),
			field(_('Password'), pwIn, _('Enter your PIA password')),
			field(_('Cache Path'), pathIn, _('Recommend external flash drive for servers list and token')),
			row(_('Login Status'), loginStatus),
			row('', E('button', { 'class': 'cbi-button cbi-button-save', 'click': ui.createHandlerFn(this, save) }, _('Save and log in'))),
			row(_('VPN Token valid till'), tokenStatus),
			row(_('Cache Renewed'), E('div', cacheLine), ...cacheNote),
			row('', E('button', {
					'class': 'cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, () => this.runJob(_('Refreshing the server list & VPN token'), '_global', () => callGlobal('refresh_cache')))
				}, _('Refresh server list & VPN token')))
		]);
	},

	// ---- interfaces ------------------------------------------------------

	// one labelled line of the status column
	line: function(label, value) {
		return E('div', [ E('strong', label + ': '), value ]);
	},

	stateLines: function(i) {
		if (i.job && i.job.state == 'running')
			return [ E('div', { 'class': 'spinning' }, _('Working…')) ];
		if (!i.up)
			return [];
		return [];
	},

	settingsLines: function(i) {
		const warn = [], st = this.st;
		const yes = _('Yes'), no = _('No'), off = _('Off');
		const mtuAuto = i.mtu_auto || !i.mtu || i.mtu == st.std_mtu;
		const mtu = i.mtu_auto && i.mtu_run ? i.mtu_run : (i.mtu || st.std_mtu);
		const ka = i.keepalive == null ? KEEPALIVE : i.keepalive;
		const ksw = i.killswitch, pf = i.portfwd;
		const L2 = [].concat(
			this.stateLines(i),
			this.line(_('Keepalive'), ka == KEEPALIVE ? _('Default') : ka == 0 ? _('Disabled') : _('Custom')),
			this.line(_('Default route'), i.default_route ? yes : no),
			this.line(_('DNS'), dnsLabel(i)),
			this.line(_('DNS redirect'), i.firewall && i.dns_redirect ? _('On') : off),
			this.line(_('MTU'), mtuAuto ? _('Default') : mtu == st.small_mtu ? _('Small') : _('Custom')),
			this.line(_('Kill switch'), ksw && ksw.enabled ? _('On') : off),
			this.line(_('Firewall zone'), i.firewall ? (i.forward.length ? i.forward.join(', ') + ' → ' : '') + i.name : off),
			this.line(_('Port forwarding'), pf && pf.enabled ? (!pf.capable ? _('Not in this region')
				: !pf.port ? _('Waiting for a port')
				: (pf.public_ip ? pf.public_ip + ':' : '') + pf.port + (pf.ip ? ' → ' + pf.ip + ':' + (pf.dest_port || pf.port) : '')) : off),
			this.line(_('Bring up on boot'), i.boot ? yes : no),
			i.dip ? this.line(_('Dedicated IP'), yes) : []);
		if (i.failover && i.failover.home)
			warn.push('⚠ ' + _('Failover: running on %s; the chosen region %s is tried again by the renew job').format(i.region.name || i.region.id, i.failover.home_name || i.failover.home));
		if (i.mss && !i.mss.clamp) warn.push('⚠ ' + _('no MSS clamping'));
		if (ksw && ksw.leaks && ksw.leaks.length)
			ksw.leaks.forEach(l => warn.push('⚠ ' + _('%s can reach %s without the VPN').format(l.split('>')[0], l.split('>')[1])));
		return L2.concat(warn.map(w => E('div', { 'style': 'color:#d97706' }, w)));
	},

	// LuCI's interface box: shaded head with the name, badges below
	ifaceBox: function(i) {
		const working = i.job && i.job.state == 'running';
		const up = i.up && !working;
		const ka = i.keepalive == null ? KEEPALIVE : i.keepalive;
		// the theme's own colours (as the buttons use), so they follow the light and dark mode
		const scheme = { // [theme variable, on-colour variable, fallback colour, fallback on-colour]
			green: [ 'success', 'on-success-color', '#2ea44f', '#fff' ],
			amber: [ 'warn', 'on-warn-color', '#d97706', '#fff' ],
			red: [ 'error', 'on-error-color', '#d73a49', '#fff' ],
			grey: [ 'text-color', 'on-primary-color', '#6b7280', '#fff' ]
		};
		let kind = 'red', tip = _('Stopped');
		if (working) { kind = 'grey'; tip = _('Working…'); }
		else if (up && (ka == 0 || (i.handshake != null && i.handshake <= STALE))) { kind = 'green'; tip = _('Connected'); }
		else if (up) { kind = 'amber'; tip = i.handshake == null ? _('No handshake yet') : _('Handshake %s: older than %d s').format(ago(i.handshake), STALE); }
		const sc = scheme[kind], v = n => 'var(--' + n + ',' + (n == sc[1] ? sc[3] : sc[2]) + ')';
		const hi = kind == 'grey' ? v('text-color-medium') : v(sc[0] + '-color-high'),
			md = kind == 'grey' ? v('text-color-medium') : v(sc[0] + '-color-medium'),
			lo = kind == 'grey' ? v('text-color-low') : v(sc[0] + '-color-low');
		return E('div', { 'class': 'ifacebox', 'style': 'margin:0;border-color:' + hi }, [
			E('div', { 'class': 'ifacebox-head', 'title': tip,
				'style': 'background:linear-gradient(' + md + ',' + lo + ') !important;border-bottom-color:' + hi + ';color:' + v(sc[1]) + ';text-shadow:none' }, E('strong', i.name)),
			E('div', { 'class': 'ifacebox-body' }, [
				E('small', { 'style': 'color:' + hi },
					up ? (i.handshake != null ? _('Handshake %s').format(ago(i.handshake)) : _('Not connected'))
						: working ? _('Working…') : _('Stopped'))
			])
		]);
	},

	protoLabel: function(i) {
		const o = PROTOS.find(o => o[0] == (i.auto ? 'auto' : i.proto));
		return o ? o[1] : String(i.proto);
	},

	renderRows: function() {
		const list = this.st.interfaces;
		if (!list.length)
			return [ E('tr', { 'class': 'tr placeholder' }, [ E('td', { 'class': 'td', 'colspan': 2 },
				E('em', _('No interface yet: use Add interface to create one.'))) ]) ];
		return list.map(i => {
			const busy = i.job && i.job.state == 'running';
			const btn = (cls, label, fn, dis) => E('button', {
				'class': 'cbi-button ' + cls, 'disabled': (busy || dis) ? '' : null, 'click': ui.createHandlerFn(this, fn)
			}, label);
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'data-title': _('Interface') }, E('div', {}, [
					this.ifaceBox(i),
					E('div', { 'style': 'margin-top:.5em' }, [
						this.line(_('Region'), (i.region.name || i.region.id || '-')),
						this.line(_('Failover'), i.dip ? _('Not with a dedicated IP') : (i.failover && i.failover.enabled ? _('On') : _('Off'))),
						this.line(_('Protocol'), this.protoLabel(i))
					].concat(this.settingsLines(i)))
				])),
				E('td', { 'class': 'td cbi-section-actions' }, E('div', [
					i.up ? btn('cbi-button-action', _('Restart'), () => this.doAction(i.name, 'restart', _('Restarting %s').format(i.name)))
						: btn('cbi-button-action', _('Start'), () => this.doAction(i.name, 'start', _('Starting %s').format(i.name))),
					' ',
					btn('cbi-button-neutral', _('Stop'), () => this.doAction(i.name, 'stop', _('Stopping %s').format(i.name)), !i.up),
					' ',
					btn('cbi-button-edit', _('Edit'), () => this.openForm(i)),
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
		this.addBtn = E('button', {
			'class': 'cbi-button cbi-button-add',
			'click': ui.createHandlerFn(this, () => this.openForm(null))
		}, _('Add interface…'));
		this.syncAddBtn();
		const unavailable = !this.st.awg;
		return E('div', { 'class': 'cbi-section' }, [
			E('h3', _('Interfaces')),
			E('div', { 'class': 'cbi-section-descr' }, _('Each interface is a separate VPN tunnel to a PIA region.')
				+ (unavailable ? ' ' + _('AmneziaWG is not installed (amneziawg-tools, kmod-amneziawg): only WireGuard is offered.') : '')),
			E('div', { 'class': 'table cbi-section-table' }, [
				E('table', { 'class': 'table' }, [
					E('thead', {}, E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, _('Interface')),
						E('th', { 'class': 'th cbi-section-actions' }, '')
					])),
					this.tbody
				])
			]),
			E('div', { 'class': 'cbi-page-actions', 'style': 'text-align:left' }, [ this.addBtn ])
		]);
	},

	// Add interface needs an account; kept in step with the status at every poll
	syncAddBtn: function() {
		const have = !!(this.st.account.id && this.st.account.password_set);
		this.addBtn.disabled = !have;
		this.addBtn.title = have ? '' : _('Save the account first');
	},

	update: function() {
		if (!this.tbody) return;
		dom.content(this.tbody, this.renderRows());
		this.syncAddBtn();
		// the account part is redrawn only when its state changed (not while typing)
		const a = this.st.account, c = this.st.cache || {},
			sig = [ a.id, a.password_set, a.vpn_expires, c.regions, c.checked, c.updated, c.meta, c.ram, c.cron, c.path ].join('|');
		if (this.accountBox && sig != this.accSig) {
			this.accSig = sig;
			dom.content(this.accountBox, this.renderAccount());
		}
	},

	// ---- region picker (add and edit) ------------------------------------

	// -> { node, get(): { region, fast } }; 'proto' picks the servers list
	regionPicker: function(proto, current, fast, onchange, placeholder) {
		let kind = proto;
		const box = E('div');
		const state = { region: current ? current.id : '', fast: !!fast, regions: null, ping: {}, asked: {} };
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
			// adding: no location is chosen until the user picks one
			if (codes.indexOf(state.country) < 0)
				state.country = placeholder ? '' : cur ? cur.country : (codes.indexOf('GB') >= 0 ? 'GB' : codes[0]);

			const regionSel = E('select', { 'class': 'cbi-input-select', 'change': ev => { state.region = ev.target.value; if (onchange) onchange(); } });
			let curItems = [];
			const fill = () => {
				const items = state.country ? shown.filter(r => r.country == state.country) : [];
				const label = r => r.name + (r.id in state.ping ? ' (' + (state.ping[r.id] != null ? state.ping[r.id] + ' ms' : '–') + ')' : '');
				dom.content(regionSel, items.map(r => E('option', { 'value': r.id, 'selected': r.id == state.region ? '' : null }, label(r))));
				curItems = items;
				pingItems();
				if (!items.some(r => r.id == state.region)) state.region = items.length ? items[0].id : '';
				regionSel.value = state.region;
				regionSel.disabled = !state.country;
				if (onchange) onchange();
			};
			// the ping times of the country (from the WAN), asked once per region and protocol; not while the row is hidden
			const pingItems = () => {
				const items = curItems;
				const ask = state.fast ? [] : items.filter(r => !((kind + r.id) in state.asked));
				if (ask.length) {
					ask.forEach(r => { state.asked[kind + r.id] = 1; });
					callPing(kind, ask.map(r => r.id).join(' ')).then(res => {
						ask.forEach(r => { state.ping[r.id] = res && res[r.id] != null ? res[r.id] : null; });
						Array.from(regionSel.options).forEach(op => {
							const r = items.find(x => x.id == op.value);
							if (r && r.id in state.ping) op.textContent = label(r);
						});
					}).catch(() => {});
				}
			};
			const countrySel = select((placeholder ? [ [ '', _('Select VPN location') ] ] : []).concat(
				codes.map(c => [ c, '%s (%d)'.format(countryName(c), countries[c]) ])), state.country, ev => {
				state.country = ev.target.value;
				fill();
			});
			if (placeholder) countrySel.options[0].disabled = true;
			const so = checkbox(state.so, ev => { state.so = ev.target.checked; draw(); });
			const pf = checkbox(state.pf, ev => { state.pf = ev.target.checked; draw(); });
			const ng = checkbox(state.ng, ev => { state.ng = ev.target.checked; draw(); });
			const regionRow = field(_('Region Selection'), regionSel, _('Choose region for VPN endpoint'));
			const fastCb = checkbox(state.fast, ev => {
				state.fast = ev.target.checked;
				regionRow.style.display = state.fast ? 'none' : '';
				pingItems();
			});
			regionRow.style.display = state.fast ? 'none' : '';
			fill();
			dom.content(box, [
				field(_('Physical VPN locations only'), ng, _('Exclude virtual VPN locations')),
				field(_('Streaming optimised only'), so, _('List streaming optimised regions only')),
				field(_('Port forwarding only'), pf, _('List port forwarding regions only')),
				field(_('VPN location'), countrySel, _('Location of VPN endpoint')),
				field(_('Fastest region'), fastCb, _('Automatically choose fastest region in selected country. Overrides manual selection.')),
				regionRow
			]);
		};

		const load = () => callRegions(kind).then(r => {
			state.regions = (r && r.ok && r.regions) || [];
			draw();
		});

		dom.content(box, E('p', { 'class': 'spinning' }, _('Loading the regions…')));
		load();

		return { node: box, reload: p => {
			if (p == kind) return;
			kind = p;
			dom.content(box, E('p', { 'class': 'spinning' }, _('Loading the regions…')));
			load();
		}, get: () => {
			const r = (state.regions || []).find(x => x.id == state.region);
			return { region: state.region, name: r ? r.name : state.region, fast: state.fast, streaming: !!(r && r.streaming) };
		}, state: state };
	},

	// ---- add and edit: one dialog -------------------------------------------------

	// i: the interface to edit, or null to add one
	openForm: function(i) {
		const st = this.st;
		const adding = !i;
		const others = st.interfaces.filter(o => !i || o.name != i.name);
		const holder = others.find(o => o.default_route);
		const awgOk = !!st.awg;
		const protoCtl = selectHelp(PROTOS.filter(p => awgOk || p[0] == 'wireguard'),
			adding ? (awgOk ? 'amneziawg' : 'wireguard') : (i.auto ? 'auto' : i.proto), null,
			() => !awgOk ? _('AmneziaWG is not installed on this router.')
				: adding ? null
				: i.dip ? _('A dedicated IP needs WireGuard.')
				: _('Changing the protocol makes a new key and the region must have servers for it.'));
		const protoSel = protoCtl.node;
		if (!adding && i.dip) protoSel.disabled = true;

		const taken = n => others.some(o => o.name == n);
		const nameInp = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'value': '',
			'maxlength': 15, 'placeholder': 'pia_xx', 'spellcheck': 'false', 'style': 'margin-top:.4em', 'input': () => { nameTouched = true; } });
		let nameTouched = false, nameUpdate = null;
		// pia_<country code>, numbered when taken (pia_gb_2)
		const countryName_ = () => {
			const c = picker && picker.state.country ? picker.state.country.toLowerCase() : '';
			if (!c) return '';
			let n = 'pia_' + c, k = 2;
			while (taken(n) && k < 100) n = 'pia_' + c + '_' + (k++);
			return n.slice(0, 15);
		};
		const nameSel = E('select', { 'class': 'cbi-input-select', 'change': () => nameUpdate(true) });
		const nameBox = E('div', [ nameSel, nameInp ]);
		nameUpdate = pick => {
			const cn = countryName_(), prev = nameSel.value;
			const opts = [
				[ 'country', cn || 'pia_xx', false ],
				[ 'custom', _('Custom'), false ]
			];
			dom.content(nameSel, opts.map(o => E('option', { 'value': o[0], 'disabled': o[2] ? '' : null }, o[1])));
			const v = prev || 'country';
			nameSel.value = v;
			if (v == 'custom') {
				nameInp.style.display = '';
				if (!nameTouched && cn) nameInp.value = cn;
			}
			else
				nameInp.style.display = 'none';
		};
		const chosenName = () => nameSel.value == 'country' ? countryName_() : nameInp.value.trim();
		const nameOk = n => /^[A-Za-z0-9_]{1,15}$/.test(n) && [ 'account', 'apitoken', 'vpntoken', 'cache', 'log' ].indexOf(n) < 0;

		let picker = null;
		const dnsCtl = selectHelp(DNSOPTS, adding ? 'standard' : i.dns);
		const dnsInp = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'maxlength': 15, 'size': 16, 'spellcheck': 'false',
			'placeholder': _('IPv4 address'), 'value': !adding && i.dns == 'custom' ? i.dns_ip : '', 'style': 'margin-top:.4em' });
		const dnsBox = withInput(dnsCtl, dnsInp);
		// each PIA choice shows its server address in brackets (it follows a streaming optimised region)
		const dnsLabels = () => {
			const streaming = picker && picker.state.regions ? !!picker.get().streaming : !adding && !!i.streaming;
			Array.from(dnsCtl.node.options).forEach(op => {
				const o = DNSOPTS.find(x => x[0] == op.value);
				if (o && o[0] != 'custom') op.textContent = o[1] + ' (' + dnsFor(st, o[0] == 'mace', streaming) + ')';
			});
		};
		dnsCtl.node.addEventListener('focus', () => dnsLabels());
		dnsCtl.node.addEventListener('mousedown', () => dnsLabels());
		const cur = adding ? 0 : i.mtu;
		const isCustom = cur && !i.mtu_auto && cur != st.std_mtu && cur != st.small_mtu;
		const mtuCtl = selectHelp(mtuOpts(st), !cur || i.mtu_auto || cur == st.std_mtu ? 'std' : cur == st.small_mtu ? 'small' : 'custom');
		const mtuInp = numInput(isCustom ? cur : '', _('%d to %d').format(MTU_MIN, MTU_MAX));
		const mtuBox = withInput(mtuCtl, mtuInp);
		const ka = adding || i.keepalive == null || i.keepalive == KEEPALIVE ? 'default' : i.keepalive == 0 ? 'off' : 'custom';
		const keepCtl = selectHelp(KEEPOPTS, ka);
		const keepInp = numInput(ka == 'custom' ? i.keepalive : '', _('1 to 65535'));
		const keepBox = withInput(keepCtl, keepInp);

		const routeCb = checkbox(adding ? !holder : i.default_route);
		if (holder) {
			routeCb.disabled = true;
			routeCb.checked = !adding && i.default_route;
		}
		const fwWarn = E('div', { 'style': 'color:#d97706' }, _('Without the zone there is no MSS clamping: large TCP transfers can stall on a smaller path.'));
		const fwCb = checkbox(adding ? true : i.firewall, () => { fwWarn.style.display = fwCb.checked ? 'none' : ''; });
		fwWarn.style.display = (adding || i.firewall) ? 'none' : '';
		const bdInp = E('input', { 'class': 'cbi-input-text', 'type': 'number', 'min': 0, 'max': 3600, 'step': 1, 'style': 'width:7em',
			'value': String(adding ? 60 : !i.boot ? 0 : (i.boot_delay || 0)) });
		const bdBox = field(_('Delay before bring up'), bdInp, _('Seconds after the router starts; 0 brings it up as soon as the network starts. Needs the ifup hook.'));
		const drCb = checkbox(adding || i.dns_redirect !== false);
		const foCb = checkbox(adding ? true : !(i.failover && !i.failover.enabled));
		const bootCb = checkbox(adding ? true : i.boot, () => { bdBox.style.display = bootCb.checked ? '' : 'none'; });
		bdBox.style.display = adding || i.boot ? '' : 'none';
		const pf = adding ? {} : (i.portfwd || {});
		const pfIp = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'maxlength': 15, 'size': 16, 'spellcheck': 'false',
			'placeholder': _('IPv4 address'), 'value': pf.ip || '' });
		const pfPort = numInput(pf.dest_port, _('same as the forwarded port'));
		pfPort.style.marginTop = '0';
		const pfBox = E('div', [
			field(_('Destination IP address'), pfIp, _('The device on your network that receives the connections.')),
			field(_('Destination Port'), pfPort, _('1 to 65535; empty uses the port PIA forwards.'))
		]);
		const pfCb = checkbox(!!pf.enabled, () => { pfBox.style.display = pfCb.checked ? '' : 'none'; });
		pfBox.style.display = pf.enabled ? '' : 'none';
		const zones = st.zones.filter(z => (adding || z != i.name) && !/^Block-/.test(z));
		const fwd = adding ? (st.lan_zone ? [ st.lan_zone ] : []) : i.forward;
		// (not the zones attached to br-wan, the VPN zones and the zones that masquerade, unless it is already forwarding)
		const hidden = [].concat(st.brwan_zones || [], st.wan_zones || [], st.vpn_zones || [], st.masq_zones || []);
		const boxes = zones.filter(z => fwd.indexOf(z) >= 0 || hidden.indexOf(z) < 0).map(z => [ z, checkbox(fwd.indexOf(z) >= 0) ]);
		const ks = adding ? {} : (i.killswitch || {});
		const ksSel = ks.enabled && ks.wan.length ? ks.wan : (st.wan_zones || []).filter(z => (st.brwan_zones || []).indexOf(z) >= 0);
		const ksBoxes = (st.wan_zones || []).filter(z => z != (adding ? '' : i.name)).map(z => [ z, checkbox(ksSel.indexOf(z) >= 0) ]);
		const ksList = E('div', ksBoxes.length ? ksBoxes.map(b => E('label', { 'style': 'margin-right:1em' }, [ b[1], ' ', b[0] ])) : _('No WAN zone found (attached to br-wan or masquerading, not a VPN)'));
		const ksBox = field(_('WAN zones'), ksList, _('Select WAN connections to be removed so to isolate selected internal networks'));
		const ksCb = checkbox(adding ? (fwd.length > 0 && ksSel.length > 0) : !!ks.enabled, () => { ksBox.style.display = ksCb.checked ? '' : 'none'; });
		ksBox.style.display = ksCb.checked ? '' : 'none';

		const regionBox = E('div');
		const pickerProto = () => protoSel.value == 'wireguard' ? 'wireguard' : 'amneziawg';
		if (!adding && i.dip) {
			dom.content(regionBox, field(_('Region Selection'), E('span', i.region.name), _('Set by the dedicated IP.')));
		}
		else {
			picker = this.regionPicker(pickerProto(), !adding && i.region.id ? { id: i.region.id } : null, adding ? true : i.fast, () => { if (nameUpdate) nameUpdate(); }, adding);
			dom.content(regionBox, picker.node);
			protoSel.addEventListener('change', () => picker.reload(pickerProto()));
			if (adding) nameUpdate();
		}
		dnsLabels();

		const err = E('div', { 'class': 'alert-message warning', 'style': 'display:none' });
		const problem = msg => {
			err.textContent = msg;
			err.style.display = '';
		};

		const save = restart => {
			const g = picker ? picker.get() : null;
			let name = adding ? chosenName() : i.name;
			if (adding) {
				if (!name && nameSel.value == 'country') return problem(_('Select a VPN location'));
				if (!nameOk(name)) return problem(_('Invalid name: 1 to 15 letters, digits or underscore'));
				if (others.some(o => o.name == name)) return problem(_('An interface with that name exists'));
			}
			if (picker && !g.region) return problem(_('Choose a region'));
			if (mtuCtl.node.value == 'custom') {
				const m = +mtuInp.value;
				if (!/^[0-9]+$/.test(mtuInp.value) || m < MTU_MIN || (m > MTU_MAX && m != cur))
					return problem(_('Packet size: digits only, %d to %d').format(MTU_MIN, MTU_MAX));
			}
			if (keepCtl.node.value == 'custom') {
				const k = +keepInp.value;
				if (!/^[0-9]+$/.test(keepInp.value) || k < 1 || k > 65535)
					return problem(_('Keepalive: digits only, 1 to 65535'));
			}
			if (bootCb.checked && (!/^[0-9]+$/.test(bdInp.value.trim() || '0') || +bdInp.value > 3600))
				return problem(_('Delay before bring up: 0 to 3600 seconds'));
			if (ksCb.checked) {
				if (!fwCb.checked)
					return problem(_('The kill switch needs the firewall zone'));
				if (!boxes.some(b => b[1].checked))
					return problem(_('The kill switch needs a zone to allow forwarding from'));
				if (!ksBoxes.some(b => b[1].checked))
					return problem(_('The kill switch needs a WAN zone'));
			}
			if (pfCb.checked) {
				if (pfIp.value.trim() && !IPV4.test(pfIp.value.trim()))
					return problem(_('Destination IP address: enter an IPv4 address'));
				if (pfPort.value && (+pfPort.value < 1 || +pfPort.value > 65535))
					return problem(_('Destination Port: 1 to 65535'));
				if (pfIp.value.trim() && !fwCb.checked)
					return problem(_('Port forwarding to a device needs the firewall zone'));
			}
			if (dnsCtl.node.value == 'custom' && !IPV4.test(dnsInp.value.trim()))
				return problem(_('DNS server: enter an IPv4 address'));
			const title = adding ? _('Add interface') : _('Saving %s').format(name);
			ui.showModal(title, E('p', { 'class': 'spinning' }, adding ? _('Creating the interface…') : _('Saving…')));
			return callSave({
				name: name, proto: protoSel.value,
				region: g ? g.region : null, fast: g ? (g.fast ? '1' : '0') : null,
				dns: dnsCtl.node.value, dns_ip: dnsCtl.node.value == 'custom' ? dnsInp.value.trim() : null,
				mtu: mtuCtl.node.value == 'custom' ? mtuInp.value : mtuCtl.node.value,
				keepalive: keepCtl.node.value == 'custom' ? keepInp.value : keepCtl.node.value,
				route: routeCb.disabled ? null : (routeCb.checked ? 'yes' : 'no'),
				firewall: fwCb.checked ? 'yes' : 'no',
				forward: fwCb.checked ? boxes.filter(b => b[1].checked).map(b => b[0]).join(' ') : null,
				killswitch: ksCb.checked ? 'yes' : 'no',
				ks_wan: ksCb.checked ? ksBoxes.filter(b => b[1].checked).map(b => b[0]).join(' ') : null,
				failover: foCb.checked ? 'yes' : 'no',
				dns_redirect: fwCb.checked ? (drCb.checked ? 'yes' : 'no') : null,
				portfwd: pfCb.checked ? 'yes' : 'no',
				pf_ip: pfCb.checked ? pfIp.value.trim() : null,
				pf_port: pfCb.checked ? pfPort.value : null,
				boot: bootCb.checked ? 'yes' : 'no',
				boot_delay: bootCb.checked ? String(+bdInp.value || 0) : null
			}).then(r => {
				ui.hideModal();
				if (!r || !r.ok) return fail(r);
				this.refresh();
				if (adding) {
					ui.showModal(_('Interface %s created').format(name), [
						E('p', _('Start it now? The first start registers a key with PIA and can take up to a minute.')),
						E('div', { 'class': 'right' }, [
							E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Later')), ' ',
							E('button', { 'class': 'cbi-button cbi-button-positive important',
								'click': () => this.doAction(name, 'start', _('Starting %s').format(name)) }, _('Start'))
						])
					]);
					return;
				}
				if (restart) return this.doAction(name, 'restart', _('Restarting %s').format(name));
				if (i.up)
					ui.addNotification(null, E('p', _('Saved. The changes apply when %s is restarted.').format(name)), 'info');
			});
		};

		const buttons = adding
			? [ E('button', { 'class': 'cbi-button cbi-button-positive important', 'click': ui.createHandlerFn(this, () => save(false)) }, _('Create')) ]
			: [ E('button', { 'class': 'cbi-button cbi-button-save', 'click': ui.createHandlerFn(this, () => save(false)) }, _('Save')), ' ',
				E('button', { 'class': 'cbi-button cbi-button-positive important', 'click': ui.createHandlerFn(this, () => save(true)) }, _('Save and restart')) ];

		ui.showModal(adding ? _('Add interface') : _('Settings of %s').format(i.name), [].concat(
			adding ? [ field(_('Interface Name'), nameBox, _('Name for interface and firewall zone. Letters, digits and underscore (up to 15)')) ] : [],
			[
				field(_('Protocol Selection'), protoSel, protoCtl.help),
				regionBox,
				(!adding && i.dip) ? '' : field(_('Failover'), foCb, _('Switch to another region of the same country when this one cannot connect')),
				field(_('Packet size (MTU)'), mtuBox, mtuCtl.help),
				field(_('Keepalive'), keepBox, keepCtl.help),
				field(_('DNS servers'), dnsBox, dnsCtl.help),
				field(_('DNS redirect'), drCb, _('Send DNS from the selected networks to this router and reject DNS over TLS (port 853)')),
				field(_('Default route'), routeCb, holder ? routeTaken(holder.name) : [ E('div', _('Recommended to send all traffic via PIA.')), E('div', _('Enables strict DNS to prevent DNS leakage')) ]),
				field(_('Firewall zone'), fwCb, [ E('div', _('Recommended to create zone with NAT and MSS clamping')), fwWarn ]),
				field(_('Allow forwarding from'), E('div', boxes.map(b => E('label', { 'style': 'margin-right:1em' }, [ b[1], ' ', b[0] ]))),
					_('Select internal networks permitted to route traffic via VPN.')),
				field(_('Kill switch'), ksCb, _('Enable to isolate selected internal networks when VPN is down')),
				ksBox,
				field(_('Port forwarding'), pfCb, _('Enable Port forwarding')),
				pfBox,
				field(_('Bring up on boot'), bootCb, _('Enable to connect on boot')),
				bdBox,
				err,
				E('div', { 'class': 'right' }, [ E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')), ' ' ].concat(buttons))
			]));
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
				E('button', { 'class': 'cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, () => this.loadLog()) }, _('Refresh log'))
			])
		]);
	},

	// ---- history --------------------------------------------------------------------

	loadHistory: function() {
		return callHistory().then(r => {
			if (!this.histBox) return;
			const rows = (r && r.entries) || [], sum = (r && r.summary) || [];
			if (!rows.length) {
				dom.content(this.histBox, E('p', { 'class': 'cbi-value-description' }, _('Nothing has been recorded yet.')));
				return;
			}
			const EVENTS = { register: _('Key registration'), probe: _('Token probe'), fast: _('Fastest-region ping'), confirm: _('Tunnel confirmation'), guard: _('Guard') };
			const ms = v => (v == null) ? '–' : '%d ms'.format(v);
			const cell = (t, v) => E('td', { 'class': 'td', 'data-title': t }, v);
			const head = cols => E('tr', { 'class': 'tr table-titles' }, cols.map(c => E('th', { 'class': 'th' }, c)));
			const sumTable = E('table', { 'class': 'table' }, [
				head([ _('Region'), _('Country'), _('Requests'), _('Accepted'), _('Refused'), _('Average time') ])
			].concat(sum.map(x => E('tr', { 'class': 'tr' }, [
				cell(_('Region'), x.region || x.region_id), cell(_('Country'), x.country || '–'), cell(_('Requests'), String(x.total)),
				cell(_('Accepted'), String(x.ok)), cell(_('Refused'), x.refused + ' (' + (x.total ? Math.round(100 * x.refused / x.total) : 0) + '%)'),
				cell(_('Average time'), ms(x.ms))
			]))));
			const detail = E('table', { 'class': 'table' }, [
				head([ _('Time (UTC)'), _('Interface'), _('Event'), _('Country'), _('Region'), _('Server IP'), _('Latency'), _('Status') ])
			].concat(rows.map(x => E('tr', { 'class': 'tr' }, [
				cell(_('Time (UTC)'), utcDate(x.t) + ' ' + utcTime(x.t)), cell(_('Interface'), x.if || '–'),
				cell(_('Event'), EVENTS[x.ev] || x.ev), cell(_('Country'), x.country || '–'), cell(_('Region'), x.region || x.region_id || '–'),
				cell(_('Server IP'), x.ip || '–'), cell(_('Latency'), ms(x.ms)),
				E('td', { 'class': 'td', 'data-title': _('Status'), 'title': x.note || '' }, x.status || '–')
			]))));
			const total = sum.reduce((n, x) => n + x.total, 0), refused = sum.reduce((n, x) => n + x.refused, 0);
			dom.content(this.histBox, [
				E('h4', _('Region summary')),
				E('div', { 'class': 'cbi-section-descr' }, _('Key registrations and token probes per region. Requests: %d · Regions: %d · Refused: %d. A region that refuses often takes longer to connect.').format(total, sum.length, refused)),
				sumTable,
				E('h4', { 'style': 'margin-top:1.5em' }, _('Event history')),
				E('div', { 'class': 'cbi-section-descr' }, _('Newest first: registrations, token probes, fastest-region pings, tunnel confirmations and guard actions. Events shown: %d.').format(rows.length)),
				E('div', { 'style': 'max-height:22em;overflow:auto' }, detail)
			]);
		});
	},

	renderHistory: function() {
		this.histBox = E('div', {}, E('p', { 'class': 'spinning' }, _('Loading…')));
		this.loadHistory();
		return E('div', { 'class': 'cbi-section' }, [
			E('h3', _('History')),
			E('div', { 'class': 'cbi-section-descr' }, _('What this router did with the PIA servers, kept in history.json in the Cache Path (latest 200 events).')),
			this.histBox,
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', { 'class': 'cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, () => this.loadHistory()) }, _('Refresh history'))
			])
		]);
	},

	// ---- page ---------------------------------------------------------------------------

	render: function(st) {
		this.st = st;
		const a = st.account, c = st.cache || {};
		this.accSig = [ a.id, a.password_set, a.vpn_expires, c.regions, c.checked, c.updated, c.meta, c.ram, c.cron, c.path ].join('|');
		this.accountBox = E('div', {}, [ this.renderAccount() ]);
		const page = E('div', {}, [
			E('h2', _('PIA VPN')),
			E('div', { 'class': 'cbi-map-descr' }, _('Private Internet Access over WireGuard and AmneziaWG (pia.sh %s).').format(st.version)),
			this.accountBox,
			this.renderInterfaces(),
			this.renderLog(),
			this.renderHistory()
		]);
		poll.add(() => this.refresh(), 5);
		return page;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
