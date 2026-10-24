/* NetBird view for the GL.iNet admin panel (SDK4 / oui).
 * Loaded by the panel as module.exports (Vue 2 component), rendered under
 * Applications → NetBird. Talks to the "netbird" RPC object only.
 * Hand-written render function (no build toolchain needed). */
module.exports = {
  name: "GlNetbirdView",
  data: function () {
    return {
      loading: true,
      s: null,
      setup: { url: "", key: "" },
      urlTouched: false,
      showSetup: false,
      adv: null,
      advOpen: false,
      advToken: "",
      logText: "",
      logOpen: false,
      busy: false,
      lastActionTs: 0,
      timer: null
    };
  },
  created: function () {
    var self = this;
    this.injectCss();
    this.refresh();
    /* Every poll costs the router a status fetch; keep it slow and pause it
       while the tab is hidden (the Opal has ~30 MB RAM to spare). */
    this.timer = setInterval(function () {
      if (document.hidden) return;
      self.refresh();
    }, 15000);
    this.onVis = function () { if (!document.hidden) self.refresh(); };
    document.addEventListener("visibilitychange", this.onVis);
  },
  beforeDestroy: function () {
    clearInterval(this.timer);
    document.removeEventListener("visibilitychange", this.onVis);
  },
  methods: {
    t: function (k, vars) {
      return this.$t("netbird." + k, vars);
    },
    rpc: function (method, params) {
      return window.$rpcRequest("call", ["sid", "netbird", method, params || {}]);
    },
    toast: function (type, msg) {
      if (this.$message && this.$message[type]) this.$message[type](msg);
    },

    /* ── data ─────────────────────────────────────────────── */
    refresh: function () {
      var self = this;
      if (this.inflight) return Promise.resolve();
      this.inflight = true;
      return this.rpc("get_status").then(function (r) {
        self.inflight = false;
        if (!r || r.err_code) return;
        self.s = r;
        self.loading = false;
        var c = r.config || {};
        if (!self.urlTouched && c.connection) self.setup.url = c.connection.management_url || "";
        if (!self.advOpen) self.adv = self.cloneConfig(c);
        var a = r.action;
        if (a && a.state === "running") {
          self.busy = true;
        } else {
          self.busy = false;
          if (a && a.ts && a.ts !== self.lastActionTs && self.lastActionTs !== 0) {
            self.toast(a.ok ? "success" : "error", (a.ok ? self.t("action_done") : self.t("action_failed")) + " (" + a.action + ")" + (a.ok ? "" : ": " + a.message));
          }
          if (a && a.ts) self.lastActionTs = a.ts;
        }
        if (self.logOpen) self.loadLog();
      }).catch(function () {
        self.inflight = false;
        self.loading = false;
      });
    },
    cloneConfig: function (c) {
      var out = { settings: {}, connection: {} };
      var k;
      for (k in (c.settings || {})) out.settings[k] = c.settings[k];
      for (k in (c.connection || {})) out.connection[k] = c.connection[k];
      return out;
    },
    loadLog: function () {
      var self = this;
      this.rpc("get_log", { lines: 80 }).then(function (r) {
        if (r && r.log !== undefined) self.logText = r.log;
      });
    },

    /* ── actions ──────────────────────────────────────────── */
    act: function (name, arg) {
      var self = this;
      if (this.busy) { this.toast("warning", this.t("msg_busy")); return; }
      this.busy = true;
      this.lastActionTs = this.lastActionTs || 1;
      return this.rpc("action", { name: name, arg: arg || "" }).then(function (r) {
        if (!r || r.err_code) {
          self.busy = false;
          self.toast("error", (r && r.err_msg) || self.t("msg_failed"));
          return;
        }
        self.toast("info", self.t("msg_action_started"));
        setTimeout(self.refresh, 2500);
      }).catch(function () {
        self.busy = false;
        self.toast("error", self.t("msg_failed"));
      });
    },
    enroll: function () {
      var url = (this.setup.url || "").trim();
      var key = (this.setup.key || "").trim();
      if (!/^https?:\/\/[\w.-]+:\d+\/?$/.test(url)) { this.toast("error", this.t("msg_invalid_url")); return; }
      var self = this;
      this.rpc("set_config", { connection: { management_url: url } }).then(function (r) {
        if (!r || r.err_code) { self.toast("error", (r && r.err_msg) || self.t("msg_failed")); return; }
        if (key) {
          self.act("enroll", key);
          self.setup.key = "";
        } else {
          self.act("connect");
        }
        self.showSetup = false;
      });
    },
    toggleService: function (on) {
      this.act(on ? "start" : "stop");
    },
    saveAdvanced: function () {
      var self = this;
      var a = this.adv;
      var params = { settings: {}, connection: {} };
      var k;
      for (k in a.settings) params.settings[k] = a.settings[k];
      for (k in a.connection) {
        if (k === "api_token" || k === "peer_id" || k === "route_id") continue;
        params.connection[k] = a.connection[k];
      }
      if (this.advToken) params.connection.api_token = this.advToken;
      this.rpc("set_config", params).then(function (r) {
        if (!r || r.err_code) { self.toast("error", (r && r.err_msg) || self.t("msg_failed")); return; }
        self.advToken = "";
        var onlyToken = r.changed && r.changed.length === 1 && r.changed[0] === "connection.api_token";
        if (onlyToken) {
          self.toast("success", self.t("msg_saved"));
          self.act("exit_discover");
        } else if (r.restart_required && self.s && self.s.running) {
          self.toast("success", self.t("msg_saved_restart"));
          self.act("restart");
        } else {
          self.toast("success", self.t("msg_saved"));
          self.refresh();
        }
        self.advOpen = false;
      });
    },

    /* ── helpers ──────────────────────────────────────────── */
    stateInfo: function () {
      var s = this.s;
      if (!s) return { key: "state_loading", cls: "nb-dot-gray" };
      if (!s.installed) return { key: "state_not_installed", cls: "nb-dot-red" };
      if (s.config && s.config.settings && !s.config.settings.enabled) return { key: "state_disabled", cls: "nb-dot-gray" };
      if (!s.running) return { key: "state_stopped", cls: "nb-dot-red" };
      if (s.starting && !s.status) return { key: "state_connecting", cls: "nb-dot-amber" };
      if (s.login_failed) return { key: "state_login_failed", cls: "nb-dot-red" };
      if (s.needs_login) return { key: "state_needs_login", cls: "nb-dot-amber" };
      if (s.status && s.status.mgmt_connected) return { key: "state_connected", cls: "nb-dot-green" };
      return { key: "state_connecting", cls: "nb-dot-amber" };
    },
    mb: function (kb) {
      return kb ? (kb / 1024).toFixed(1) + " MB" : "—";
    },
    injectCss: function () {
      if (document.getElementById("nb-view-style")) return;
      var st = document.createElement("style");
      st.id = "nb-view-style";
      st.textContent =
        ".nb-wrap{max-width:1100px}" +
        ".nb-card{background:#fff;border-radius:8px;padding:20px 24px;margin-bottom:16px;box-shadow:0 1px 4px rgba(0,0,0,.06)}" +
        ".nb-head{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap;margin-bottom:12px}" +
        ".nb-title{font-size:18px;font-weight:600;display:flex;align-items:center;gap:10px}" +
        ".nb-sub{font-size:14px;font-weight:600;margin:0 0 10px}" +
        ".nb-desc{color:#6b7280;font-size:13px;line-height:1.6;margin:0 0 6px}" +
        ".nb-dot{display:inline-block;width:10px;height:10px;border-radius:50%}" +
        ".nb-dot-green{background:#22c55e}.nb-dot-amber{background:#f59e0b}.nb-dot-red{background:#ef4444}.nb-dot-gray{background:#9ca3af}" +
        ".nb-badge{font-size:13px;color:#374151;display:inline-flex;align-items:center;gap:6px}" +
        ".nb-row{display:flex;justify-content:space-between;gap:16px;padding:8px 0;border-bottom:1px solid #f3f4f6;font-size:13px}" +
        ".nb-row:last-child{border-bottom:none}.nb-label{color:#6b7280;flex-shrink:0}.nb-val{text-align:right;word-break:break-all;color:#111827}" +
        ".nb-grid{display:grid;grid-template-columns:1fr 1fr;gap:0 32px}@media(max-width:800px){.nb-grid{grid-template-columns:1fr}}" +
        ".nb-btns{display:flex;gap:10px;flex-wrap:wrap;margin-top:14px}" +
        ".nb-field{margin-bottom:14px}.nb-field label{display:block;font-size:13px;font-weight:600;color:#374151;margin-bottom:5px}" +
        ".nb-input{width:100%;box-sizing:border-box;padding:9px 12px;border:1px solid #dcdfe6;border-radius:6px;font-size:13px;font-family:monospace;background:#fff;color:#111827}" +
        ".nb-input:focus{outline:none;border-color:#409eff}" +
        ".nb-hint{font-size:12px;color:#9ca3af;margin-top:4px;line-height:1.5}" +
        ".nb-check{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:8px 0;border-bottom:1px solid #f3f4f6;font-size:13px}" +
        ".nb-check:last-child{border-bottom:none}" +
        ".nb-table{width:100%;border-collapse:collapse;font-size:13px}.nb-table th{text-align:left;padding:8px 10px;background:#f9fafb;color:#6b7280;font-weight:600;font-size:12px;text-transform:uppercase;letter-spacing:.03em}" +
        ".nb-table td{padding:8px 10px;border-bottom:1px solid #f3f4f6}.nb-empty{color:#9ca3af;text-align:center;padding:16px}" +
        ".nb-pre{background:#1f2937;color:#e5e7eb;padding:12px;border-radius:6px;font-size:11px;line-height:1.5;max-height:320px;overflow:auto;white-space:pre-wrap;word-break:break-all;margin:0}" +
        ".nb-link{color:#409eff;cursor:pointer;font-size:13px;user-select:none}" +
        ".nb-warn{background:#fffbeb;border:1px solid #fde68a;color:#92400e;border-radius:6px;padding:10px 14px;font-size:13px;margin-bottom:12px;line-height:1.5}" +
        ".nb-tag{display:inline-block;font-size:11px;padding:1px 7px;border-radius:10px;background:#eef2ff;color:#3730a3;margin-left:6px}";
      document.head.appendChild(st);
    }
  },

  render: function (h) {
    var self = this;
    var s = this.s;
    var t = function (k, v) { return self.t(k, v); };

    /* ── small builders ───────────────────────────────────── */
    function btn(label, onClick, opts) {
      opts = opts || {};
      return h("gl-button", {
        attrs: { type: opts.type || "default", disabled: !!opts.disabled || self.busy },
        on: { click: onClick }
      }, [label]);
    }
    function sw(value, onChange, disabled) {
      var fire = function (v) { if (typeof v === "boolean" && v !== value) onChange(v); };
      return h("gl-switch", {
        attrs: { size: "small", value: value, disabled: !!disabled },
        props: { value: value, disabled: !!disabled },
        on: { input: fire, change: fire }
      });
    }
    function row(label, val) {
      return h("div", { class: "nb-row" }, [
        h("span", { class: "nb-label" }, [label]),
        h("span", { class: "nb-val" }, Array.isArray(val) ? val : [val === undefined || val === null || val === "" ? "—" : String(val)])
      ]);
    }
    function input(obj, key, opts) {
      opts = opts || {};
      return h("input", {
        class: "nb-input",
        attrs: { type: opts.type || "text", placeholder: opts.placeholder || "", autocomplete: "off", spellcheck: "false", value: obj[key] },
        on: {
          input: function (e) { obj[key] = e.target.value; if (opts.onInput) opts.onInput(); }
        }
      });
    }
    function field(label, inputNode, hint) {
      return h("div", { class: "nb-field" }, [h("label", [label]), inputNode, hint ? h("div", { class: "nb-hint" }, [hint]) : null]);
    }
    function check(label, obj, key, hint) {
      return h("div", { class: "nb-check" }, [
        h("div", [h("div", [label]), hint ? h("div", { class: "nb-hint" }, [hint]) : null]),
        sw(!!obj[key], function (v) { self.$set(obj, key, v); })
      ]);
    }
    function card(children) {
      return h("div", { class: "nb-card" }, children);
    }

    var info = this.stateInfo();
    var st = s && s.status;
    var cfg = s && s.config;
    var enabled = !!(cfg && cfg.settings && cfg.settings.enabled);
    var running = !!(s && s.running);
    var connected = !!(st && st.mgmt_connected);
    var needsSetup = !!(s && s.installed && running && (s.needs_login || s.login_failed));
    var children = [];

    /* ── header card ──────────────────────────────────────── */
    var headerChildren = [
      h("div", { class: "nb-head" }, [
        h("div", { class: "nb-title" }, [
          "NetBird",
          h("span", { class: "nb-badge" }, [h("span", { class: "nb-dot " + info.cls }), t(info.key)])
        ]),
        s && s.installed ? h("div", { style: "display:flex;align-items:center;gap:10px;font-size:13px" }, [
          t("enable"), sw(enabled, function (v) { self.toggleService(v); })
        ]) : null
      ]),
      h("p", { class: "nb-desc" }, [t("desc")])
    ];
    if (s && !s.installed) headerChildren.push(h("div", { class: "nb-warn" }, [t("not_installed_hint")]));
    if (s && s.mem && s.mem.avail_kb && s.mem.avail_kb < 16000 && !s.mem.swap_total_kb) {
      headerChildren.push(h("div", { class: "nb-warn" }, [t("swap_hint", { avail: this.mb(s.mem.avail_kb) })]));
    }
    if (this.busy && s && s.action) headerChildren.push(h("div", { class: "nb-hint" }, [t("action_running") + ": " + s.action.action + "…"]));
    children.push(card(headerChildren));

    /* ── setup card ───────────────────────────────────────── */
    if (s && s.installed && (needsSetup || this.showSetup || (!running && enabled === false) || (!connected && !running))) {
      children.push(card([
        h("div", { class: "nb-sub" }, [t("setup_title")]),
        field(t("mgmt_url"), input(this.setup, "url", { placeholder: "https://your-server.example.com:443", onInput: function () { self.urlTouched = true; } }), t("mgmt_url_hint")),
        field(t("setup_key"), input(this.setup, "key", { placeholder: "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX" }), t("setup_key_hint")),
        h("div", { class: "nb-btns" }, [
          btn(t("btn_connect"), function () { self.enroll(); }, { type: "primary" }),
          this.showSetup ? btn(t("btn_cancel"), function () { self.showSetup = false; }) : null
        ])
      ]));
    }

    /* ── status card ──────────────────────────────────────── */
    if (s && s.installed && running) {
      var mem = s.mem || {};
      var wg = s.wg_mode === "kernel" ? t("wg_kernel") : (s.wg_mode === "userspace" ? t("wg_userspace") : "—");
      var dnsVal;
      if (cfg && cfg.connection && cfg.connection.disable_dns) {
        dnsVal = t("dns_off");
      } else {
        dnsVal = t("dns_on") + (s.dns_forward && s.dns_forward.length ? " · " + t("dns_forward_count", { n: s.dns_forward.length }) : "");
      }
      var exitVal = st && st.exit_node_active ? t("exit_active") : t("exit_inactive");
      var left = [
        row(t("ip"), st ? st.netbird_ip : "—"),
        row(t("fqdn"), st ? st.fqdn : "—"),
        row(t("management"), [
          h("span", [(st && st.mgmt_url) || (cfg && cfg.connection.management_url) || "—"]),
          h("span", { class: "nb-tag" }, [connected ? t("state_connected") : t("state_connecting")])
        ]),
        row(t("peers"), st ? (st.peers_connected + " / " + st.peers_total) : "—"),
        row(t("exit_node"), exitVal)
      ];
      var right = [
        row(t("version"), [
          h("span", [(st && st.daemon_version) || s.cli_version || "—"]),
          h("span", { class: "nb-tag", attrs: { title: t("procd_hint") } }, [s.procd_daemon ? "procd" : t("detached")])
        ]),
        row(t("wireguard"), wg),
        row(t("memory"), t("memory_val", { rss: this.mb(mem.rss_kb), avail: this.mb(mem.avail_kb) }) + (mem.swap_total_kb ? " · swap " + this.mb(mem.swap_total_kb - mem.swap_free_kb) + "/" + this.mb(mem.swap_total_kb) : "")),
        row(t("dns"), dnsVal),
        row(t("watchdog"), s.procd_watchdog ? t("running") : t("stopped"))
      ];
      var btns = [];
      if (!connected && !needsSetup) btns.push(btn(t("btn_connect"), function () { self.act("connect"); }, { type: "primary" }));
      btns.push(btn(t("btn_edit"), function () { self.showSetup = !self.showSetup; }));
      btns.push(btn(t("btn_disconnect"), function () { self.act("disconnect"); }));
      btns.push(btn(t("btn_restart"), function () { self.act("restart"); }));
      btns.push(btn(t("btn_watchdog"), function () { self.rpc("run_watchdog").then(function () { self.toast("info", self.t("msg_action_started")); setTimeout(self.refresh, 4000); }); }));
      if (cfg && cfg.connection.api_token) {
        if (cfg.connection.route_id) {
          btns.push(btn(st && st.exit_node_active ? t("exit_toggle_off") : t("exit_toggle_on"), function () { self.act("exit_toggle"); }, { type: "primary" }));
        } else {
          btns.push(btn(t("exit_discover"), function () { self.act("exit_discover"); }));
        }
      }
      children.push(card([
        h("div", { class: "nb-sub" }, [t("status_title")]),
        h("div", { class: "nb-grid" }, [h("div", left), h("div", right)]),
        h("div", { class: "nb-btns" }, btns),
        !(cfg && cfg.connection.api_token) ? h("div", { class: "nb-hint", style: "margin-top:8px" }, [t("exit_need_token")]) : null
      ]));

      /* ── peers card ─────────────────────────────────────── */
      var peers = (st && st.peers) || [];
      var rows = peers.length ? peers.map(function (p) {
        var dotCls = p.status === "Connected" ? "nb-dot-green" : (p.status === "Connecting" ? "nb-dot-amber" : "nb-dot-gray");
        return h("tr", [
          h("td", { attrs: { title: p.fqdn } }, [p.fqdn.split(".")[0]]),
          h("td", [p.ip]),
          h("td", [h("span", { class: "nb-dot " + dotCls, style: "margin-right:6px" }), p.status]),
          h("td", [p.conn ? (p.conn + (p.relayed ? " (" + t("relayed") + ")" : "")) : "—"]),
          h("td", [p.status === "Connected" && p.latency_ms ? p.latency_ms + " ms" : "—"])
        ]);
      }) : [h("tr", [h("td", { class: "nb-empty", attrs: { colspan: 5 } }, [t("no_peers")])])];
      children.push(card([
        h("div", { class: "nb-sub" }, [t("peers_title")]),
        h("table", { class: "nb-table" }, [
          h("thead", [h("tr", [h("th", [t("peer")]), h("th", [t("peer_ip")]), h("th", [t("peer_status")]), h("th", [t("peer_type")]), h("th", [t("peer_latency")])])]),
          h("tbody", rows)
        ])
      ]));
    }

    /* ── advanced settings ────────────────────────────────── */
    if (s && s.installed && this.adv) {
      var a = this.adv;
      var advBody = [];
      if (this.advOpen) {
        advBody = [
          h("div", { class: "nb-grid", style: "margin-top:12px" }, [
            h("div", [
              field(t("hostname"), input(a.connection, "hostname", { placeholder: "" }), t("hostname_hint")),
              field(t("wireguard_port"), input(a.connection, "wireguard_port", { placeholder: "51820" })),
              field(t("log_level"), input(a.settings, "log_level", { placeholder: "info" }), "panic · fatal · error · warn · info · debug · trace"),
              field(t("gogc"), input(a.settings, "gogc", { placeholder: "50" }), t("gogc_hint")),
              field(t("gomemlimit"), input(a.settings, "gomemlimit", { placeholder: "48MiB" }), t("gomemlimit_hint")),
              field(t("extra_up_args"), input(a.connection, "extra_up_args", { placeholder: "--block-inbound" }), t("extra_up_args_hint")),
              field(t("api_token") , input(this, "advToken", { type: "password", placeholder: a.connection.api_token ? t("api_token_set") : "nbp_…" }), t("api_token_hint"))
            ]),
            h("div", [
              check(t("disable_client_routes"), a.connection, "disable_client_routes", t("disable_client_routes_hint")),
              check(t("disable_server_routes"), a.connection, "disable_server_routes", t("disable_server_routes_hint")),
              check(t("disable_dns"), a.connection, "disable_dns", t("disable_dns_hint")),
              check(t("lan_dns_forward"), a.connection, "lan_dns_forward", t("lan_dns_forward_hint")),
              check(t("firewall_zone"), a.connection, "firewall_zone", t("firewall_zone_hint")),
              check(t("block_lan_access"), a.connection, "block_lan_access", t("block_lan_access_hint")),
              check(t("wg_userspace_opt"), a.settings, "wg_userspace", t("wg_userspace_hint")),
              check(t("disable_ebpf_proxy"), a.settings, "disable_ebpf_proxy", t("disable_ebpf_proxy_hint"))
            ])
          ]),
          h("div", { class: "nb-hint" }, [t("restart_hint")]),
          h("div", { class: "nb-btns" }, [
            btn(t("btn_save"), function () { self.saveAdvanced(); }, { type: "primary" }),
            btn(t("btn_cancel"), function () { self.advOpen = false; self.adv = self.cloneConfig(self.s.config || {}); self.advToken = ""; })
          ])
        ];
      }
      children.push(card([
        h("div", { class: "nb-head", style: "margin-bottom:0" }, [
          h("div", { class: "nb-sub", style: "margin:0" }, [t("advanced_title")]),
          h("span", { class: "nb-link", on: { click: function () { self.advOpen = !self.advOpen; if (self.advOpen) self.adv = self.cloneConfig(self.s.config || {}); } } }, [this.advOpen ? t("btn_close") : t("btn_open")])
        ])
      ].concat(advBody)));
    }

    /* ── log card ─────────────────────────────────────────── */
    if (s && s.installed) {
      children.push(card([
        h("div", { class: "nb-head", style: "margin-bottom:0" }, [
          h("div", { class: "nb-sub", style: "margin:0" }, [t("log_title")]),
          h("span", { class: "nb-link", on: { click: function () { self.logOpen = !self.logOpen; if (self.logOpen) self.loadLog(); } } }, [this.logOpen ? t("btn_close") : t("btn_open")])
        ]),
        this.logOpen ? h("pre", { class: "nb-pre", style: "margin-top:12px" }, [this.logText || t("no_log")]) : null
      ]));
    }

    if (this.loading && !s) children.push(card([h("div", { class: "nb-empty" }, [t("state_loading")])]));
    return h("div", { class: "nb-wrap" }, children);
  }
};
