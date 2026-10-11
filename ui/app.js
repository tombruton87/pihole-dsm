// Pi-hole's tabs on the chassis window: Blocking, Lists, Setup, and the HTTPS part of Site address.
(function (P) {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  function phUrl(st) { return ((st.app || {}).url || "").replace(/\/$/, ""); }
  function num(n) { return (n || 0).toLocaleString(); }

  // ---------------------------------------------------------------- Blocking
  P.register("blocking", {
    render: function (st) {
      var a = st.app || {}, s = a.stats || {}, b = a.blocking || {}, t = $("bl-tiles");
      document.querySelectorAll(".ph-link").forEach(function (x) { x.href = phUrl(st) ? phUrl(st) + "/admin/" : "#"; });
      P.clear(t); P.tile(t, num(s.queries), "lookups today"); P.tile(t, num(s.blocked), "blocked"); P.tile(t, (Math.round((s.percent || 0) * 10) / 10) + "%", "of lookups blocked");
      P.tile(t, String(s.clients || 0), "devices using it");
      var st2 = $("bl-state"), acts = $("bl-acts"); P.clear(st2); P.clear(acts);
      var on = b.state === "enabled";
      st2.appendChild(on ? P.chip("blocking", "ok") : P.chip("paused", "warn"));
      if (!on) st2.appendChild(document.createTextNode(b.timer ? "  back on in " + Math.ceil(b.timer / 60) + " min" : "  until you turn it on"));
      if (on) [[300, "Pause 5 minutes"], [1800, "30 minutes"], [3600, "1 hour"]].forEach(function (p) { acts.appendChild(P.btn(p[1], "", function () { P.act("pause", { seconds: p[0] }); })); });
      else acts.appendChild(P.btn("Turn blocking on", "primary", function () { P.act("resume", {}); }));
      var tt = $("bl-top"), top = a.top || [], sig = JSON.stringify(top); if (tt.dataset.sig !== sig) {
        tt.dataset.sig = sig; P.clear(tt);
        if (!top.length) { var r0 = P.el("tr"), c0 = P.cell("Nothing blocked yet today — point your network at Pi-hole (Setup tab).", "empty"); r0.appendChild(c0); tt.appendChild(r0); }
        top.forEach(function (d) { P.row(tt, [P.cell(P.el("span", d.domain, "dom")), P.cell(P.el("span", num(d.count) + "×", "muted"), "n")]); });
      }
      var tr = $("bl-recent"), rec = a.recent || [], sig2 = JSON.stringify(rec); if (tr.dataset.sig !== sig2) {
        tr.dataset.sig = sig2; P.clear(tr);
        if (!rec.length) { var r1 = P.el("tr"), c1 = P.cell("Nothing yet.", "empty"); c1.colSpan = 3; r1.appendChild(c1); tr.appendChild(r1); }
        rec.forEach(function (q) { P.row(tr, [P.cell(P.el("span", q.domain, "dom")), q.client || "–", q.at ? P.ago(q.at) : "–"]); });
      }
    },
    tiles: function (t, st) { var s = (st.app || {}).stats || {}; P.tile(t, num(s.blocked), "blocked today"); }
  });

  // ---------------------------------------------------------------- Lists
  P.register("lists", {
    render: function (st) {
      var a = st.app || {}, lists = a.lists || [], doms = a.domains || [], s = a.stats || {};
      $("ls-when").textContent = s.gravity_at ? num(s.gravity) + " domains, updated " + P.ago(s.gravity_at) + "." : "";
      var tl = $("ls-lists"), sig = JSON.stringify(lists) + "|" + P.busy + "|" + P.role; if (tl.dataset.sig !== sig) {
        tl.dataset.sig = sig; P.clear(tl);
        lists.forEach(function (l) { var tr = P.row(tl, [P.cell(P.el("span", l.address, "dom")), num(l.domains), P.cell(P.btn("Remove", "danger", function () { P.act("listdel", { id: l.id }, "Remove this blocklist?"); }), "n")]); if (!l.enabled) tr.className = "muted-row"; });
      }
      var td = $("ls-domains"), sig2 = JSON.stringify(doms) + "|" + P.busy + "|" + P.role; if (td.dataset.sig !== sig2) {
        td.dataset.sig = sig2; P.clear(td);
        if (!doms.length) { var r0 = P.el("tr"), c0 = P.cell("None yet.", "empty"); c0.colSpan = 3; r0.appendChild(c0); td.appendChild(r0); }
        doms.forEach(function (d) {
          P.row(td, [P.cell(P.el("span", d.domain, "dom")), d.type === "allow" ? P.chip("always allowed", "ok") : P.chip("always blocked", "warn"),
            P.cell(d.kind === "exact" ? P.btn("Remove", "", function () { P.act("domaindel", { kind: d.type, domain: d.domain }); }) : P.el("span", d.kind, "muted small"), "n")]);
        });
      }
    }
  });
  $("ls-add").onclick = function () { P.act("listadd", { url: $("ls-url").value.trim() }).then(function () { $("ls-url").value = ""; }); };
  $("dm-allow").onclick = function () { P.act("domainadd", { kind: "allow", domain: $("dm-name").value.trim() }).then(function () { $("dm-name").value = ""; }); };
  $("dm-deny").onclick = function () { P.act("domainadd", { kind: "deny", domain: $("dm-name").value.trim() }).then(function () { $("dm-name").value = ""; }); };

  // ---------------------------------------------------------------- Setup
  ["su-up", "su-custom"].forEach(function (id) { ["input", "change"].forEach(function (e) { $(id).addEventListener(e, function () { $(id).dataset.touched = "1"; $("su-custom-row").hidden = $("su-up").value !== "custom"; }); }); });
  P.register("setup", {
    render: function (st) {
      var a = st.app || {}, d = a.dns || {};
      $("su-dns").textContent = (d.ip || "") + (d.port && d.port !== 53 ? " (port " + d.port + ")" : "");
      $("su-port").textContent = d.port && d.port !== 53 ? "Pi-hole answers on port " + d.port + " here — most routers and devices can only use port 53." : "";
      if (!$("su-up").dataset.touched) $("su-up").value = a.upstream || "cloudflare";
      if (!$("su-custom").dataset.touched) $("su-custom").value = (a.custom || []).join(" ");
      $("su-custom-row").hidden = $("su-up").value !== "custom";
      $("su-now").textContent = (a.upstreams || []).length ? "Now: " + a.upstreams.join(", ") : "";
    }
  });
  $("su-save").onclick = function () { P.act("upstream", { upstream: $("su-up").value, custom: $("su-custom").value.trim() }).then(function () { $("su-up").dataset.touched = ""; $("su-custom").dataset.touched = ""; }); };
  P.register("secretNote", function () { return "For Pi-hole's own web page. Keep it in your password manager."; });

  // ---------------------------------------------------------------- Site address: HTTPS
  P.register("site", {
    fill: function (st) { var t = (st.app && st.app.tls) || {}; $("set-tls").value = t.mode || "off"; },
    values: function () { return { tls: $("set-tls").value }; },
    render: function (st) {
      var t = (st.app && st.app.tls) || {}, c = t.cert, tb = $("tls-info"), note = $("tls-note"), acts = $("tls-actions"); P.clear(tb); P.clear(acts);
      $("tls-card").hidden = !t.mode || t.mode === "off";
      if (!t.mode || t.mode === "off") return;
      if (!c) { P.kv(tb, "Certificate", "none yet — it's made or read when Pi-hole starts"); note.textContent = ""; return; }
      P.kv(tb, "From", t.source === "dsm" ? "DSM (the system default certificate)" : "the package (self-signed)");
      P.kv(tb, "Issued to", c.subject || "–"); P.kv(tb, "Issued by", c.self_signed ? "itself (self-signed)" : (c.issuer || "–"));
      P.kv(tb, "Expires", (c.expires || "–") + (typeof c.days_left === "number" ? " (" + (c.days_left < 0 ? "expired" : c.days_left + " days") + ")" : ""));
      if (c.names) P.kv(tb, "Names", c.names.replace(/,/g, ", "));
      note.textContent = t.mode === "dsm" && t.source === "self" ? "DSM's certificate wasn't found on this system, so a self-signed one is in use."
        : c.self_signed ? "Self-signed: browsers warn once. For no warning, use a trusted certificate (Let's Encrypt in DSM, made the system default)."
        : "Browsers trust this certificate as long as they reach Pi-hole by one of its names.";
      acts.appendChild(P.btn(t.mode === "dsm" ? "Read DSM's certificate again" : "Make a new self-signed certificate", "", function () { P.act("refreshcert", {}, t.mode === "dsm" ? null : "Make a new self-signed certificate?"); }));
    }
  });
  $("set-tls").addEventListener("change", function () { $("set-url").dataset.touched = "1"; var u = $("set-url").value.trim(); if ($("set-tls").value !== "off" && /^http:\/\//.test(u)) $("set-url").value = "https://" + u.slice(7); });

  // ---------------------------------------------------------------- Storage
  P.register("storage", { render: function (app, st, box) {
    P.clear(box); var c = P.el("div", null, "card"); c.appendChild(P.el("h2", "Pi-hole's data")); var tbl = P.el("table"), tb = P.el("tbody"); tbl.appendChild(tb); c.appendChild(tbl);
    [["Blocklists (gravity)", app.gravity], ["Lookup history", app.history]].forEach(function (p) { P.kv(tb, p[0], P.mb(p[1] || 0), true); });
    box.appendChild(c);
  } });
})(window.Panel);
