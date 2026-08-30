import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Omaquota: a bar icon and a TUI-style panel for a CLIProxyAPI instance.
// bin/omaquota-fetch writes ~/.local/state/omarchy/omaquota/snapshot.json;
// this file only renders it. Keys: j/k scroll · t 24h/7d · e aggregate ·
// h redact names · r cycle the bar metric · i cycle the bar icon · Enter refresh · Esc close.

Panel {
  id: root
  moduleName: "njpatel.omaquota"
  ipcTarget: "njpatel.omaquota"
  manageIpc: false

  // ---------------------------------------------------------------- settings
  readonly property string baseUrl: String(setting("baseUrl", "http://127.0.0.1:8317"))
  readonly property string hostLabel: String(setting("hostLabel", "cliproxyapi"))
  readonly property string keyFile: String(setting("keyFile", "~/.config/omaquota/management-key"))
  readonly property int refreshIntervalSec: Math.max(30, Number(setting("refreshIntervalSec", 60)))
  readonly property int quotaIntervalSec: Math.max(120, Number(setting("quotaIntervalSec", 900)))
  property string barMetric: String(setting("barMetric", "tokens"))
  readonly property var barMetrics: ["tokens", "tokens-split", "requests", "cost", "none"]
  function cycleBarMetric() {
    var i = barMetrics.indexOf(barMetric)
    barMetric = barMetrics[(i + 1) % barMetrics.length]
    // Persist on the bar entry so the choice survives a shell restart.
    Quickshell.execDetached(["omarchy", "bar", "set", "njpatel.omaquota", "barMetric", barMetric])
  }

  // Bar icon: a name from `barIcons` or any raw glyph. Nerd Font codepoints.
  readonly property var barIcons: ({
    "server-network": "\u{f048d}", "server": "\u{f048b}", "lan": "\u{f0317}", "network": "\u{f06f3}",
    "gauge": "\u{f029a}", "gauge-fa": "\u{eeb2}", "speedometer": "\u{f04c5}", "meter": "\u{f463}",
    "pulse": "\u{f0430}", "waveform": "\u{f147d}", "signal": "\u{f04a2}", "chart": "\u{f0128}",
    "chart-line": "\u{f012a}", "trending": "\u{f0535}", "counter": "\u{f0199}", "abacus": "\u{f16e0}",
    "coins": "\u{ede8}", "cash": "\u{f0114}", "usd": "\u{f01c1}", "fuel": "\u{f07ca}",
    "brain": "\u{f09d1}", "robot": "\u{f06a9}", "chip": "\u{f061a}", "flash": "\u{f0241}", "timer": "\u{f13ab}"
  })
  property string barIconName: String(setting("barIcon", "speedometer"))
  readonly property string barIcon: barIcons[barIconName] !== undefined ? barIcons[barIconName] : barIconName
  function cycleBarIcon() {
    var names = Object.keys(barIcons), i = names.indexOf(barIconName)
    barIconName = names[(i + 1) % names.length]
    Quickshell.execDetached(["omarchy", "bar", "set", "njpatel.omaquota", "barIcon", barIconName])
  }

  readonly property string snapshotPath: Quickshell.env("HOME") + "/.local/state/omarchy/omaquota/snapshot.json"
  readonly property string fetcher: Qt.resolvedUrl("bin/omaquota-fetch").toString().replace(/^file:\/\//, "")

  function setting(name, fallback) {
    var s = root.settings || ({})
    return s[name] !== undefined && s[name] !== null ? s[name] : fallback
  }

  // ---------------------------------------------------------------- theme
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.rgba(fg.r, fg.g, fg.b, 0.45)
  readonly property color faint: Qt.rgba(fg.r, fg.g, fg.b, 0.22)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---------------------------------------------------------------- state
  property var snapshot: null
  property string range: "24h"
  property bool scrub: false      // h: redact account names
  property bool expanded: true    // e: every account vs one block per provider
  property double nowMs: Date.now()
  readonly property bool fetching: fetchProcess.running

  readonly property var stats: snapshot && snapshot.stats ? (snapshot.stats[range] || null) : null
  readonly property var accounts: snapshot && snapshot.accounts ? snapshot.accounts : []
  readonly property bool online: !!snapshot && snapshot.ok === true

  readonly property real lowestRemaining: lowest(false)
  // Model-scoped caps (a weekly Fable allowance, say) run dry routinely while
  // the account is fine, so only the primary 5h/7d windows light the bar.
  readonly property bool alarming: online && lowest(true) <= 10
  readonly property var primaryWindows: ["five_hour", "seven_day", "main:primary_window", "main:secondary_window"]

  function lowest(primaryOnly) {
    var low = 101
    for (var i = 0; i < accounts.length; i++) {
      var wins = (accounts[i].quota || {}).windows || []
      for (var j = 0; j < wins.length; j++) {
        var w = wins[j]
        if (primaryOnly && primaryWindows.indexOf(w.id) < 0) continue
        if (w.remaining_pct !== null && w.remaining_pct !== undefined && w.remaining_pct < low) low = w.remaining_pct
      }
    }
    return low
  }

  function toggleRange() { range = range === "24h" ? "7d" : "24h" }
  function scrollBy(steps) {
    panelFlick.contentY = Math.max(0, Math.min(panelFlick.contentY + steps * Style.space(48),
                                               Math.max(0, panelFlick.contentHeight - panelFlick.height)))
  }

  // ---------------------------------------------------------------- data
  FileView {
    path: root.snapshotPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parseSnapshot(text())
    onLoadFailed: root.snapshot = null
  }

  function parseSnapshot(content) {
    try {
      var parsed = JSON.parse(String(content || ""))
      root.snapshot = parsed && typeof parsed === "object" ? parsed : null
    } catch (e) {
      console.warn("omaquota", "bad snapshot", e)
    }
  }

  Process {
    id: fetchProcess
    running: false
    property bool force: false
    command: [root.fetcher, JSON.stringify({
      baseUrl: root.baseUrl, hostLabel: root.hostLabel, keyFile: root.keyFile,
      quotaIntervalSec: root.quotaIntervalSec
    })].concat(force ? ["--force"] : [])
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("omaquota", text.trim())
    }
  }

  function refresh(force) {
    if (fetchProcess.running) return
    fetchProcess.force = !!force
    fetchProcess.running = true
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  onOpenedChanged: if (opened) {
    nowMs = Date.now()
    panelFlick.contentY = 0
    if (!snapshot || (Date.now() / 1000 - (snapshot.generated_ts || 0)) > refreshIntervalSec) refresh(false)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(true); return "ok" }
    function scrub(): string { root.scrub = !root.scrub; return root.scrub ? "scrubbed" : "clear" }
    function expand(): string { root.expanded = !root.expanded; return root.expanded ? "expanded" : "aggregated" }
    function range(): string { root.toggleRange(); return root.range }
    // Card rectangle in logical monitor coordinates (used for screenshots).
    function geometry(): string {
      return JSON.stringify({ x: panel.cardOrigin.x, y: panel.cardOrigin.y, w: panel.contentWidth, h: panel.contentHeight })
    }
  }

  // ---------------------------------------------------------------- formatting
  function fmtNum(n) {
    n = Number(n || 0)
    if (n >= 1e9) return (n / 1e9).toFixed(n >= 1e10 ? 0 : 1) + "B"
    if (n >= 1e6) return (n / 1e6).toFixed(n >= 1e7 ? 0 : 1) + "M"
    if (n >= 1e3) return (n / 1e3).toFixed(n >= 1e4 ? 0 : 1) + "k"
    return String(Math.round(n))
  }
  function fmtInt(n) {
    return String(Math.round(Number(n || 0))).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  }
  function fmtUsd(v) {
    v = Number(v || 0)
    if (v >= 1000) return "$" + fmtInt(Math.round(v))
    if (v >= 100) return "$" + v.toFixed(0)
    if (v >= 10) return "$" + v.toFixed(1)
    return "$" + v.toFixed(2)
  }
  function fmtMs(ms) {
    if (ms === null || ms === undefined) return "-"
    ms = Number(ms)
    return ms >= 1000 ? (ms / 1000).toFixed(1) + "s" : Math.round(ms) + "ms"
  }
  function fmtDuration(sec) {
    sec = Math.max(0, Math.round(sec))
    var d = Math.floor(sec / 86400), h = Math.floor((sec % 86400) / 3600), m = Math.floor((sec % 3600) / 60)
    if (d > 0) return d + "d " + h + "h"
    if (h > 0) return h + "h " + (m < 10 ? "0" : "") + m + "m"
    return m + "m"
  }
  function fmtDurationShort(sec) { return fmtDuration(sec).replace(/ /g, "") }
  function fmtAge(ts) {
    if (!ts) return "never"
    var s = nowMs / 1000 - ts
    return s < 90 ? "just now" : fmtDuration(s) + " ago"
  }
  function fmtClock(ts) {
    var d = new Date(ts * 1000)
    if (new Date(nowMs).toDateString() !== d.toDateString()) return d.toLocaleDateString(Qt.locale(), "d MMM")
    return (d.getHours() < 10 ? "0" : "") + d.getHours() + ":" + (d.getMinutes() < 10 ? "0" : "") + d.getMinutes()
  }
  // Drop a trailing snapshot date from model ids: claude-haiku-4-5-20251001.
  function modelName(m) { return String(m).replace(/-20\d{6}$/, "") }

  // Redaction: local part and domain become deterministic ░▒▓█ runs of the
  // same length; "@" and the TLD survive so accounts stay tell-apart-able.
  function noise(text) {
    var glyphs = "░▒▓█▓▒", h = 2166136261, out = ""
    for (var i = 0; i < text.length; i++) { h ^= text.charCodeAt(i); h = (h * 16777619) >>> 0 }
    for (var j = 0; j < text.length; j++) {
      h ^= h << 13; h >>>= 0; h ^= h >>> 17; h ^= h << 5; h >>>= 0
      out += glyphs.charAt(h % glyphs.length)
    }
    return out
  }
  function displayName(name) {
    name = String(name)
    if (!scrub) return name
    var at = name.indexOf("@")
    if (at < 0) return noise(name)
    var local = name.slice(0, at), domain = name.slice(at + 1), dot = domain.lastIndexOf(".")
    return noise(local) + "@" + noise(dot > 0 ? domain.slice(0, dot) : domain) + (dot > 0 ? domain.slice(dot) : "")
  }

  // ---------------------------------------------------------------- layout
  //
  // The panel is one rich-text block laid out on a fixed grid of `cols`
  // monospace columns. Every piece of text goes through cell(), which clips
  // to its width with an ellipsis, so long values never push the frame.
  readonly property int cols: 62
  readonly property int inner: cols - 4      // minus the "│ " … " │" frame
  readonly property string tui: buildTui()

  function pad(s, w) { s = String(s); while (s.length < w) s += " "; return s }
  function lpad(s, w) { s = String(s); while (s.length < w) s = " " + s; return s }
  function rep(ch, n) { var s = ""; for (var i = 0; i < n; i++) s += ch; return s }
  function esc(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/ /g, "&nbsp;")
  }
  function span(text, color) { return "<span style=\"color:" + String(color) + "\">" + esc(text) + "</span>" }

  // Fragments carry their plain width alongside the HTML so lines can be
  // padded exactly.
  function frag(html, len) { return { html: html, len: len } }
  function cat() {
    var html = "", len = 0
    for (var i = 0; i < arguments.length; i++) { html += arguments[i].html; len += arguments[i].len }
    return frag(html, len)
  }
  function cell(text, w, color, right) {
    text = String(text === null || text === undefined ? "" : text)
    if (text.length > w) text = w > 1 ? text.slice(0, w - 1) + "…" : text.slice(0, w)
    return frag(span(right ? lpad(text, w) : pad(text, w), color), w)
  }
  function gap(n) { return frag(esc(rep(" ", n)), n) }
  function line(f) {
    return span("│ ", faint) + f.html + esc(rep(" ", Math.max(0, inner - f.len))) + span(" │", faint) + "<br>"
  }
  function blank() { return line(frag("", 0)) }
  function rule(title, first, last) {
    var l = first ? "┌" : (last ? "└" : "├"), r = first ? "┐" : (last ? "┘" : "┤")
    if (!title) return span(l + rep("─", cols - 2) + r, faint) + "<br>"
    if (title.length > cols - 6) title = title.slice(0, cols - 7) + "…"
    return span(l + "─ ", faint) + span(title, dim) + span(" " + rep("─", cols - 5 - title.length) + r, faint) + "<br>"
  }

  // Meters: remaining quota (filled = what is left) and share of a maximum.
  function meter(remaining, width) {
    if (remaining === null || remaining === undefined) return frag(span(rep("·", width), faint), width)
    var cells = Math.round(width * Math.max(0, Math.min(100, remaining)) / 100)
    var color = remaining <= 10 ? urgent : (remaining <= 25 ? accent : fg)
    return frag(span(rep("▓", cells), color) + span(rep("░", width - cells), faint), width)
  }
  function share(value, max, width) {
    var cells = max > 0 ? Math.round(width * value / max) : 0
    return frag(span(rep("▓", cells), accent) + span(rep("░", width - cells), faint), width)
  }

  // Usage grid: label 8 · gap · value 7 · gap 2, three pairs per line.
  function kv(label, value, color) {
    return cat(cell(label, 8, dim), gap(1), cell(value, 7, color || fg, true), gap(2))
  }
  // Subscription rows: name 36 · ok 7 · fail 6 · plan 5.
  function accountRow(name, nameColor, ok, fail, plan) {
    return line(cat(cell(name, 36, nameColor), gap(1), cell(ok, 7, dim, true), gap(1),
                    cell(fail, 6, dim, true), gap(1), cell(plan, 5, dim)))
  }
  function accountHeader(title) {
    return line(cat(cell(title, 36, accent), gap(1), cell("ok", 7, faint, true), gap(1),
                    cell("fail", 6, faint, true), gap(1), cell("plan", 5, faint)))
  }
  // Window rows: indent 2 · label 10 · meter 18 · left 9 · gap 2 · tail 15.
  function windowRow(label, remaining, left, leftColor, tail, tailColor) {
    return line(cat(gap(2), cell(label, 10, dim), gap(1), meter(remaining, 18), gap(1),
                    cell(left, 9, leftColor, true), gap(2), cell(tail, 15, tailColor)))
  }

  function buildTui() {
    var out = ""
    var snap = root.snapshot
    var gen = snap && snap.generated_ts ? fmtAge(snap.generated_ts) : "never"
    out += rule("CLIPROXYAPI @ " + hostLabel, true, false)

    if (!snap) {
      out += line(cell("no snapshot yet - fetching…", inner, dim))
      return out + rule("", false, true)
    }
    if (!snap.ok) {
      out += line(cell("✗ " + String(snap.error || "offline"), inner, urgent))
      out += line(cell("last good data " + gen, inner, dim))
    }

    // Usage
    var st = root.stats
    var title = "USAGE " + range + " · t toggles"
    if (st && st.covered_since) title += " · since " + fmtClock(st.covered_since)
    out += rule(title, false, false)
    if (st && st.requests !== undefined) {
      var failPct = st.requests > 0 ? (100 * st.failed / st.requests) : 0
      out += line(cat(kv("requests", fmtInt(st.requests)),
                      kv("failed", fmtInt(st.failed), st.failed > 0 ? accent : fg),
                      kv("rate", failPct.toFixed(1) + "%", failPct >= 5 ? urgent : fg)))
      var fresh = st.uncached_tokens !== undefined ? st.uncached_tokens : Math.max(0, (st.input_tokens || 0) - (st.cached_tokens || 0))
      out += line(cat(kv("input", fmtNum(fresh)),
                      kv("output", fmtNum(st.output_tokens)),
                      kv("total", fmtNum(st.total_tokens))))
      out += line(cat(kv("cache rd", fmtNum(st.cached_tokens)),
                      kv("cache wr", st.cache_write_tokens !== undefined ? fmtNum(st.cache_write_tokens) : "-"),
                      kv("hit rate", Math.round(100 * (st.cache_hit || 0)) + "%")))
      if (st.priced && st.requests > 0) {
        out += line(cat(kv("est cost", fmtUsd(st.cost_usd)),
                        kv("cache", fmtUsd(st.cost_cache_usd)),
                        kv("in+out", fmtUsd((st.cost_in_usd || 0) + (st.cost_out_usd || 0)))))
      }
      out += line(cat(kv("latency", fmtMs(st.avg_latency_ms)), kv("ttft", fmtMs(st.avg_ttft_ms))))
      if (st.covered_since) {
        var span = range === "7d" ? 604800 : 86400, left = span - (nowMs / 1000 - st.covered_since)
        out += line(cell("collecting since " + fmtClock(st.covered_since) + " · the " + range + " view fills in over the next " + fmtDuration(left), inner, faint))
      }
      if (st.note) out += line(cell(st.note, inner, faint))
      if (st.unpriced_requests > 0) out += line(cell(fmtInt(st.unpriced_requests) + " requests on models without a list price", inner, faint))
      out += blank()

      // Models: name 20 · share 10 · reqs 7 · tokens 8 · cost 8
      var models = st.models || [], maxReq = 0
      for (var i = 0; i < models.length; i++) maxReq = Math.max(maxReq, models[i].requests)
      out += line(cat(cell("model", 20, faint), gap(1), cell("share", 10, faint), gap(1),
                      cell("reqs", 7, faint, true), gap(1), cell("tokens", 8, faint, true), gap(1),
                      cell(st.priced ? "cost" : "", 8, faint, true)))
      if (models.length === 0) out += line(cell("no traffic in this range", inner, dim))
      for (var m = 0; m < models.length; m++) {
        var md = models[m]
        var cost = st.priced ? (md.priced === false ? "-" : fmtUsd(md.cost)) : ""
        out += line(cat(cell(modelName(md.model), 20, fg), gap(1), share(md.requests, maxReq, 10), gap(1),
                        cell(fmtInt(md.requests), 7, fg, true), gap(1), cell(fmtNum(md.total_tokens), 8, dim, true), gap(1),
                        cell(cost, 8, fg, true)))
      }
    } else {
      out += line(cell("stats unavailable" + (st && st.error ? ": " + st.error : ""), inner, dim))
    }
    out += blank()

    // Subscriptions, grouped by provider in snapshot order
    var lowestText = lowestRemaining > 100 ? "-" : Math.round(lowestRemaining) + "% left"
    out += rule("SUBSCRIPTIONS " + accounts.length + " · lowest " + lowestText + (expanded ? "" : " · aggregated"), false, false)
    var groups = [], byProvider = ({})
    for (var a = 0; a < accounts.length; a++) {
      var prov = accounts[a].provider
      if (!byProvider[prov]) { byProvider[prov] = []; groups.push(prov) }
      byProvider[prov].push(accounts[a])
    }
    if (!expanded && groups.length > 0) out += accountHeader("")
    for (var g = 0; g < groups.length; g++) {
      out += expanded ? expandedGroup(groups[g], byProvider[groups[g]]) : aggregateGroup(groups[g], byProvider[groups[g]])
      out += blank()
    }

    var foot = gen + (fetching ? " · fetching…" : "") + " · bar " + barMetric + " · icon " + barIconName + (scrub ? " · hidden" : "")
    out += rule("", false, false)
    out += line(cell(foot, inner, fg))
    out += rule("", false, true)
    checkWidths(out)
    return out
  }

  function expandedGroup(provider, list) {
    var out = accountHeader(provider.toUpperCase())
    for (var i = 0; i < list.length; i++) {
      var acct = list[i], q = acct.quota || {}, wins = q.windows || []
      out += accountRow(displayName(acct.email), scrub ? dim : fg, fmtInt(acct.success), fmtInt(acct.failed), q.plan || "")
      if (wins.length === 0) {
        var why = q.error || q.note || (acct.disabled ? "disabled" : (acct.unavailable ? "unavailable" : (acct.status || "?")))
        out += line(cat(gap(2), cell(why, inner - 2, q.error && q.error !== "disabled" ? urgent : dim)))
      }
      for (var w = 0; w < wins.length; w++) {
        var win = wins[w]
        var known = win.remaining_pct !== null && win.remaining_pct !== undefined
        out += windowRow(win.label, win.remaining_pct,
                         known ? Math.round(win.remaining_pct) + "% left" : "-", known && win.remaining_pct <= 10 ? urgent : fg,
                         win.resets_at ? "resets " + fmtDuration(win.resets_at - nowMs / 1000) : "", q.stale ? faint : dim)
      }
      if (wins.length > 0 && (q.stale || q.error)) {
        var note = (q.stale ? "stale · " : "") + (q.error || "")
          + (q.retry_until > nowMs / 1000 ? " · retry in " + fmtDuration(q.retry_until - nowMs / 1000) : "")
        out += line(cat(gap(2), cell(note, inner - 2, faint)))
      }
    }
    return out
  }

  // One block per provider: summed counters, then per window label the
  // average remaining and the worst account.
  function aggregateGroup(provider, list) {
    var ok = 0, fail = 0, live = 0, byLabel = ({}), labels = []
    for (var i = 0; i < list.length; i++) {
      var acct = list[i], wins = (acct.quota || {}).windows || []
      ok += acct.success; fail += acct.failed
      if (wins.length > 0) live++
      for (var w = 0; w < wins.length; w++) {
        var win = wins[w]
        if (win.remaining_pct === null || win.remaining_pct === undefined) continue
        if (!byLabel[win.label]) { byLabel[win.label] = { sum: 0, n: 0, min: 101, soonest: null }; labels.push(win.label) }
        var e = byLabel[win.label]
        e.sum += win.remaining_pct; e.n++
        if (win.remaining_pct < e.min) { e.min = win.remaining_pct; e.soonest = win.resets_at || null }
      }
    }
    var title = provider.toUpperCase() + " · " + list.length + (list.length === 1 ? " account" : " accounts")
      + (live < list.length ? " · " + live + " reporting" : "")
    var out = accountRow(title, accent, fmtInt(ok), fmtInt(fail), "")
    if (labels.length === 0) out += line(cat(gap(2), cell("no quota data", inner - 2, dim)))
    for (var l = 0; l < labels.length; l++) {
      var e2 = byLabel[labels[l]], avg = e2.sum / e2.n
      var tail = "min " + Math.round(e2.min) + "%" + (e2.soonest ? " " + fmtDurationShort(e2.soonest - nowMs / 1000) : "")
      out += windowRow(labels[l], avg, Math.round(avg) + "% avg", avg <= 10 ? urgent : fg, tail, e2.min <= 10 ? urgent : dim)
    }
    return out
  }

  // Every rendered line must be exactly `cols` wide or the frame drifts;
  // warn rather than guess.
  function checkWidths(html) {
    var rows = html.split("<br>")
    for (var i = 0; i < rows.length; i++) {
      if (rows[i] === "") continue
      var plain = rows[i].replace(/<[^>]+>/g, "").replace(/&nbsp;/g, " ").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&")
      if (plain.length !== cols) console.warn("omaquota", "line " + i + " is " + plain.length + " wide, want " + cols + ":", plain)
    }
  }

  // ---------------------------------------------------------------- bar
  // Bar label: always the last 24h (documented; the tooltip says so). Input
  // here is what was actually sent fresh; cache reads re-send the whole
  // conversation every turn and would swamp the number, so they live in the tooltip.
  readonly property var stats24: snapshot && snapshot.stats ? (snapshot.stats["24h"] || null) : null
  function freshInput(st) {
    return st.uncached_tokens !== undefined ? st.uncached_tokens : Math.max(0, (st.input_tokens || 0) - (st.cached_tokens || 0))
  }
  readonly property string barText: {
    if (!snapshot || barMetric === "none") return ""
    if (!online) return snapshot.error && String(snapshot.error).indexOf("omaquota-setup") >= 0 ? "setup" : "off"
    var st = stats24
    if (!st) return ""
    if (barMetric === "requests") return fmtNum(st.requests)
    if (barMetric === "cost") return st.priced ? fmtUsd(st.cost_usd) : "-"
    if (barMetric === "tokens-split") return "↑" + fmtNum(freshInput(st)) + " ↓" + fmtNum(st.output_tokens)
    return fmtNum(freshInput(st) + (st.output_tokens || 0))
  }
  readonly property string barTooltip: {
    var st = stats24
    if (!st) return "Omaquota"
    return "Last 24h: " + fmtInt(st.requests) + " requests · ↑" + fmtNum(freshInput(st)) + " new input + " + fmtNum(st.cached_tokens)
      + " cache read (" + Math.round(100 * (st.cache_hit || 0)) + "% hit) · ↓" + fmtNum(st.output_tokens) + " output" + (st.priced ? " · est " + fmtUsd(st.cost_usd) : "")
  }

  implicitWidth: row.implicitWidth
  implicitHeight: bar ? bar.barSize : Style.bar.sizeHorizontal

  Row {
    id: row
    anchors.centerIn: parent

    BarIconButton {
      id: button
      bar: root.bar
      text: root.barIcon
      active: root.alarming
      onPressed: function(buttonCode) { root.barPressed(buttonCode) }
    }

    // The metric text acts as part of the button: same clicks as the icon.
    Text {
      id: metric
      anchors.verticalCenter: parent.verticalCenter
      visible: !(root.bar && root.bar.vertical) && root.barText !== ""
      text: root.barText
      color: root.alarming ? root.urgent : (root.bar ? root.bar.barForeground : root.fg)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      rightPadding: Style.space(6)

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
        onClicked: function(mouse) { root.barPressed(mouse.button) }
        onEntered: if (root.bar) root.bar.showTooltip(metric, root.barTooltip)
        onExited: if (root.bar) root.bar.hideTooltip(metric)
      }
    }
  }

  function barPressed(buttonCode) {
    if (buttonCode === Qt.RightButton) root.refresh(true)
    else if (buttonCode === Qt.MiddleButton) root.toggleRange()
    else root.toggle()
  }

  // ---------------------------------------------------------------- panel
  TextMetrics {
    id: colMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    text: root.rep("─", root.cols)
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // The panel's own padding lives inside contentWidth.
    contentWidth: panel.fittedContentWidth(colMetrics.advanceWidth + panel.padding * 2 + Style.space(12))
    contentHeight: panel.fittedContentHeight(tuiText.implicitHeight + Style.space(12), Style.space(920))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      // The catcher maps j/k to vertical moves and h/l to horizontal ones
      // before textKey sees them; h (dx < 0) toggles redaction.
      onMoveRequested: function(dx, dy) {
        if (dx < 0) root.scrub = !root.scrub
        if (dy !== 0) root.scrollBy(dy)
      }
      onActivateRequested: root.refresh(true)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.cycleBarMetric()
        else if (t === "t" || t === "T") root.toggleRange()
        else if (t === "e" || t === "E") root.expanded = !root.expanded
        else if (t === "i" || t === "I") root.cycleBarIcon()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: tuiText.implicitHeight + Style.space(8)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Text {
          id: tuiText
          x: Style.space(4)
          y: Style.space(4)
          text: root.tui
          textFormat: Text.RichText
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          lineHeight: 1.15
          wrapMode: Text.NoWrap
        }
      }
    }
  }
}
