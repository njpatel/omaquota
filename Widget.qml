import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// CLIProxyAPI — bar icon + a TUI-flavoured panel: proxy-wide stats up top,
// then every subscription with the quota it has left in each window.
//
// Data comes from bin/cpa-fetch, which writes ~/.local/state/omarchy/omaquota/
// snapshot.json; this file only renders it. Keys inside the panel:
//   j/k or arrows  scroll        r  refresh now        t  toggle 24h / 7d
//   e  aggregate / expand        x or h  scrub (hide) account names with ASCII noise
//   Esc            close         Tab/Shift+Tab  next / previous panel

Panel {
  id: root
  moduleName: "njpatel.omaquota"
  ipcTarget: "njpatel.omaquota"
  manageIpc: false

  // ------------------------------------------------------------ settings
  readonly property string baseUrl: String(setting("baseUrl", "http://127.0.0.1:8317"))
  readonly property string hostLabel: String(setting("hostLabel", "cliproxyapi"))
  readonly property string keyFile: String(setting("keyFile", "~/.config/omaquota/management-key"))
  readonly property int refreshIntervalSec: Math.max(60, Number(setting("refreshIntervalSec", 300)))
  readonly property int quotaIntervalSec: Math.max(120, Number(setting("quotaIntervalSec", 900)))
  readonly property string barMetric: String(setting("barMetric", "requests"))

  readonly property string snapshotPath: Quickshell.env("HOME") + "/.local/state/omarchy/omaquota/snapshot.json"
  readonly property string fetcher: Qt.resolvedUrl("bin/omaquota-fetch").toString().replace(/^file:\/\//, "")

  // ------------------------------------------------------------ theme
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.rgba(fg.r, fg.g, fg.b, 0.45)
  readonly property color faint: Qt.rgba(fg.r, fg.g, fg.b, 0.22)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ------------------------------------------------------------ state
  property var snapshot: null
  property string range: "24h"
  // x: replace account names with deterministic ASCII noise (screenshots,
  // screen shares). e: collapse each provider into one aggregate block.
  property bool scrub: false
  property bool expanded: true
  property bool fetching: false
  property double nowMs: Date.now()

  readonly property var stats: snapshot && snapshot.stats ? (snapshot.stats[range] || null) : null
  readonly property var accounts: snapshot && snapshot.accounts ? snapshot.accounts : []
  readonly property bool online: !!snapshot && snapshot.ok === true

  // Lowest remaining percentage across every window of every account — the
  // number that decides whether the bar icon lights up.
  readonly property real lowestRemaining: lowest(false)
  // Model-scoped caps (e.g. a weekly Fable allowance) run dry routinely while
  // the account itself is fine, so only the primary 5h / 7d windows light the
  // bar icon.
  readonly property real lowestPrimary: lowest(true)
  readonly property bool alarming: online && lowestPrimary <= 10

  function lowest(primaryOnly) {
    var low = 101
    for (var i = 0; i < accounts.length; i++) {
      var q = accounts[i].quota
      if (!q || !q.windows) continue
      for (var j = 0; j < q.windows.length; j++) {
        var w = q.windows[j]
        if (primaryOnly && !(w.id === "five_hour" || w.id === "seven_day" || w.id === "main:primary_window" || w.id === "main:secondary_window")) continue
        var r = w.remaining_pct
        if (r !== null && r !== undefined && r < low) low = r
      }
    }
    return low
  }

  function setting(name, fallback) {
    var s = root.settings || ({})
    return s[name] !== undefined && s[name] !== null ? s[name] : fallback
  }

  // ------------------------------------------------------------ data
  FileView {
    id: snapshotFile
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
    onRunningChanged: root.fetching = running
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
    if (panelFlick) panelFlick.contentY = 0
    // A panel opened on a snapshot older than the refresh interval is stale
    // enough to be worth a fetch of its own.
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
    function range(): string { root.range = root.range === "24h" ? "7d" : "24h"; return root.range }
  }

  // ------------------------------------------------------------ formatting
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
  function fmtClock(ts) {
    var d = new Date(ts * 1000)
    var sameDay = new Date(nowMs).toDateString() === d.toDateString()
    var hm = (d.getHours() < 10 ? "0" : "") + d.getHours() + ":" + (d.getMinutes() < 10 ? "0" : "") + d.getMinutes()
    return sameDay ? hm : d.toLocaleDateString(Qt.locale(), "d MMM")
  }
  function fmtMs(ms) {
    if (ms === null || ms === undefined) return "—"
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
  function fmtAge(ts) {
    if (!ts) return "never"
    var s = nowMs / 1000 - ts
    if (s < 90) return "just now"
    return fmtDuration(s) + " ago"
  }
  function pad(s, w) { s = String(s); while (s.length < w) s += " "; return s.slice(0, w) }
  function lpad(s, w) { s = String(s); while (s.length < w) s = " " + s; return s }
  function rep(ch, n) { var s = ""; for (var i = 0; i < n; i++) s += ch; return s }
  function hex(c) { return String(c) }
  function esc(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/ /g, "&nbsp;")
  }
  // Redaction with block glyphs: local part and domain become deterministic
  // ░▒▓█ runs (same input -> same pattern, same length); the "@" and the TLD
  // survive so accounts stay tell-apart-able and still read as e-mails.
  readonly property string noiseChars: "░▒▓█▓▒"
  function noise(text) {
    var h = 2166136261
    for (var i = 0; i < text.length; i++) { h ^= text.charCodeAt(i); h = (h * 16777619) >>> 0 }
    var out = ""
    for (var j = 0; j < text.length; j++) {
      h ^= h << 13; h >>>= 0; h ^= h >>> 17; h ^= h << 5; h >>>= 0
      out += noiseChars.charAt(h % noiseChars.length)
    }
    return out
  }
  function scrubName(name) {
    name = String(name)
    var at = name.indexOf("@")
    if (at < 0) return noise(name)
    var local = name.slice(0, at), domain = name.slice(at + 1)
    var dot = domain.lastIndexOf(".")
    var host = dot > 0 ? domain.slice(0, dot) : domain
    var tld = dot > 0 ? domain.slice(dot) : ""
    return noise(local) + "@" + noise(host) + tld
  }
  function displayName(name) { return scrub ? scrubName(name) : String(name) }

  function span(text, color) { return "<span style=\"color:" + hex(color) + "\">" + esc(text) + "</span>" }

  // Remaining-quota meter: filled cells are what is left.
  function meter(remaining, width) {
    if (remaining === null || remaining === undefined) return span(rep("·", width), faint)
    var cells = Math.round(width * Math.max(0, Math.min(100, remaining)) / 100)
    var color = remaining <= 10 ? urgent : (remaining <= 25 ? accent : fg)
    return span(rep("▓", cells), color) + span(rep("░", width - cells), faint)
  }
  // Share meter for the model table: filled cells are the share of the max.
  function share(value, max, width) {
    var cells = max > 0 ? Math.round(width * value / max) : 0
    return span(rep("▓", cells), accent) + span(rep("░", width - cells), faint)
  }

  // ------------------------------------------------------------ TUI text
  //
  // Everything is laid out on fixed-width cells so long values truncate with
  // an ellipsis instead of pushing their neighbours off the edge. Inner width
  // is `cols - 4` (the "│ " and " │" frame).
  readonly property int cols: 62
  readonly property int inner: cols - 4
  readonly property string tui: buildTui()

  function h(text, len) { return { html: text, len: len } }
  function cat() {
    var html = "", len = 0
    for (var i = 0; i < arguments.length; i++) { html += arguments[i].html; len += arguments[i].len }
    return h(html, len)
  }
  // A cell: text clipped to `w` (with an ellipsis), padded, coloured.
  function cell(text, w, color, right) {
    text = String(text === null || text === undefined ? "" : text)
    if (text.length > w) text = w > 1 ? text.slice(0, w - 1) + "…" : text.slice(0, w)
    var padded = right ? lpad(text, w) : pad(text, w)
    return h(span(padded, color), w)
  }
  function gap(n) { return h(esc(rep(" ", n)), n) }
  function line(inner) {
    return span("│ ", faint) + inner.html + esc(rep(" ", Math.max(0, root.inner - inner.len))) + span(" │", faint) + "<br>"
  }
  function blank() { return line(h("", 0)) }
  function rule(title, first, last) {
    var l = first ? "┌" : (last ? "└" : "├"), r = first ? "┐" : (last ? "┘" : "┤")
    if (!title) return span(l + rep("─", cols - 2) + r, faint) + "<br>"
    if (title.length > cols - 6) title = title.slice(0, cols - 7) + "…"
    // l(1) + "─ "(2) + title + " "(1) + dashes + r(1) must equal cols.
    return span(l + "─ ", faint) + span(title, dim) + span(" " + rep("─", cols - 5 - title.length) + r, faint) + "<br>"
  }
  // Drop a trailing snapshot date from model ids: claude-haiku-4-5-20251001.
  function modelName(m) { return String(m).replace(/-20\d{6}$/, "") }

  // label/value pairs on a 3-column grid: 9-char label, 7-char value, 2 gap.
  function kv(label, value, color) {
    return cat(cell(label, 8, dim), gap(1), cell(value, 7, color || fg, true), gap(2))
  }

  function buildTui() {
    var out = ""
    var snap = root.snapshot
    var gen = snap && snap.generated_ts ? fmtAge(snap.generated_ts) : "never"
    out += rule("CLIPROXYAPI @ " + hostLabel, true, false)

    if (!snap) {
      out += line(cell("no snapshot yet — fetching…", inner, dim))
      out += rule("", false, true)
      return out
    }
    if (!snap.ok) {
      out += line(cell("✗ " + String(snap.error || "offline"), inner, urgent))
      out += line(cell("last good data " + gen, inner, dim))
    }

    // ---- usage
    var st = root.stats
    var usageTitle = "USAGE " + range + " · t toggles"
    if (st && st.covered_since) usageTitle += " · since " + fmtClock(st.covered_since)
    out += rule(usageTitle, false, false)
    if (st && st.requests !== undefined) {
      var failPct = st.requests > 0 ? (100 * st.failed / st.requests) : 0
      out += line(cat(kv("requests", fmtInt(st.requests)),
                      kv("failed", fmtInt(st.failed), st.failed > 0 ? accent : fg),
                      kv("rate", failPct.toFixed(1) + "%", failPct >= 5 ? urgent : fg)))
      out += line(cat(kv("input", fmtNum(st.input_tokens)),
                      kv("output", fmtNum(st.output_tokens)),
                      kv("cached", Math.round(100 * (st.cache_hit || 0)) + "%")))
      if (st.priced && st.requests > 0) {
        out += line(cat(kv("est cost", fmtUsd(st.cost_usd)),
                        kv("cache", fmtUsd(st.cost_cache_usd)),
                        kv("in+out", fmtUsd((st.cost_in_usd || 0) + (st.cost_out_usd || 0)))))
      }
      out += line(cat(kv("latency", fmtMs(st.avg_latency_ms)), kv("ttft", fmtMs(st.avg_ttft_ms))))
      if (st.note) out += line(cell(String(st.note), inner, faint))
      if (st.unpriced_requests > 0) out += line(cell(fmtInt(st.unpriced_requests) + " requests on models without a list price", inner, faint))
      out += blank()

      // ---- models: name 20 · share 10 · reqs 7 · tokens 8 · cost 8 = 57
      var models = st.models || []
      var maxReq = 0
      for (var i = 0; i < models.length; i++) maxReq = Math.max(maxReq, models[i].requests)
      out += line(cat(cell("model", 20, faint), gap(1), cell("share", 10, faint), gap(1),
                      cell("reqs", 7, faint, true), gap(1), cell("tokens", 8, faint, true), gap(1),
                      cell(st.priced ? "cost" : "", 8, faint, true)))
      if (models.length === 0) out += line(cell("no traffic in this range", inner, dim))
      for (var m = 0; m < models.length; m++) {
        var md = models[m]
        out += line(cat(cell(modelName(md.model), 20, fg), gap(1), h(share(md.requests, maxReq, 10), 10), gap(1),
                        cell(fmtInt(md.requests), 7, fg, true), gap(1), cell(fmtNum(md.total_tokens), 8, dim, true), gap(1),
                        cell(st.priced ? (md.priced === false ? "—" : fmtUsd(md.cost)) : "", 8, fg, true)))
      }
    } else {
      out += line(cell("stats unavailable" + (st && st.error ? ": " + String(st.error) : ""), inner, dim))
    }
    out += blank()

    // ---- subscriptions
    out += rule("SUBSCRIPTIONS " + accounts.length + " · lowest " + (lowestRemaining > 100 ? "—" : Math.round(lowestRemaining) + "% left")
                + (expanded ? "" : " · aggregated"), false, false)
    var groups = [], byProvider = ({})
    for (var a = 0; a < accounts.length; a++) {
      var prov = accounts[a].provider
      if (!byProvider[prov]) { byProvider[prov] = []; groups.push(prov) }
      byProvider[prov].push(accounts[a])
    }
    if (!expanded && groups.length > 0) out += providerHeader("")
    for (var g = 0; g < groups.length; g++) {
      var list = byProvider[groups[g]]
      out += (expanded ? expandedGroup(groups[g], list) : aggregateGroup(groups[g], list))
      out += blank()
    }

    // ---- footer
    var foot = "updated " + gen + (fetching ? " · fetching…" : "") + "  j/k r t e x/h" + (scrub ? " · scrubbed" : "")
    out += rule("", false, false)
    out += line(cell(foot, inner, fg))
    out += rule("", false, true)
    checkWidths(out)
    return out
  }

  // Every rendered line must be exactly `cols` wide, or the frame drifts.
  function checkWidths(html) {
    var rows = html.split("<br>")
    for (var i = 0; i < rows.length; i++) {
      if (rows[i] === "") continue
      var plain = rows[i].replace(/<[^>]+>/g, "").replace(/&nbsp;/g, " ").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&")
      if (plain.length !== cols) console.warn("omaquota", "line " + i + " is " + plain.length + " wide, want " + cols + ":", plain)
    }
  }

  // Provider header row: name cell 36 · ok 7 · fail 6 · plan 5 (= 57 with gaps)
  function providerHeader(title, subtitle) {
    return line(cat(cell(title, 36, accent), gap(1), cell("ok", 7, faint, true), gap(1),
                    cell("fail", 6, faint, true), gap(1), cell("plan", 5, faint)))
  }
  function accountRow(name, ok, fail, plan, nameColor) {
    return line(cat(cell(name, 36, nameColor), gap(1), cell(fmtInt(ok), 7, dim, true), gap(1),
                    cell(fmtInt(fail), 6, fail > 0 ? dim : faint, true), gap(1), cell(plan || "", 5, dim)))
  }
  // Window row: indent 2 · label 10 · meter 18 · left 9 · gap 2 · tail 15 = 58
  function windowRow(label, remaining, leftText, leftColor, tail, tailColor) {
    return line(cat(gap(2), cell(label, 10, dim), gap(1), h(meter(remaining, 18), 18), gap(1),
                    cell(leftText, 9, leftColor, true), gap(2), cell(tail, 15, tailColor)))
  }
  function fmtDurationShort(sec) { return fmtDuration(sec).replace(/ /g, "") }

  function expandedGroup(provider, list) {
    var out = providerHeader(provider.toUpperCase())
    for (var i = 0; i < list.length; i++) {
      var acct = list[i], q = acct.quota || {}
      out += accountRow(displayName(acct.email), acct.success, acct.failed, q.plan, scrub ? dim : fg)
      var wins = q.windows || []
      if (wins.length === 0) {
        var why = q.error ? String(q.error) : (acct.disabled ? "disabled" : (acct.unavailable ? "unavailable" : (acct.status || "?")))
        out += line(cat(gap(2), cell(why, inner - 2, q.error && q.error !== "disabled" ? urgent : dim)))
      }
      for (var w = 0; w < wins.length; w++) {
        var win = wins[w]
        var left = win.remaining_pct === null || win.remaining_pct === undefined ? "—" : Math.round(win.remaining_pct) + "% left"
        var resets = win.resets_at ? "resets " + fmtDuration(win.resets_at - nowMs / 1000) : ""
        out += windowRow(win.label, win.remaining_pct, left,
                         win.remaining_pct !== null && win.remaining_pct <= 10 ? urgent : fg, resets, q.stale ? faint : dim)
      }
      if (q.stale || q.error) {
        var note = (q.stale ? "stale · " : "") + (q.error ? String(q.error) : "")
          + (q.retry_until && q.retry_until > nowMs / 1000 ? " · retry in " + fmtDuration(q.retry_until - nowMs / 1000) : "")
        if (wins.length > 0) out += line(cat(gap(2), cell(note, inner - 2, faint)))
      }
    }
    return out
  }

  // One block per provider: summed counters, then for every window label the
  // average and the worst remaining across the accounts.
  function aggregateGroup(provider, list) {
    var ok = 0, fail = 0, live = 0, byLabel = ({}), labels = []
    for (var i = 0; i < list.length; i++) {
      var acct = list[i], q = acct.quota || {}
      ok += acct.success; fail += acct.failed
      if ((q.windows || []).length > 0) live++
      for (var w = 0; w < (q.windows || []).length; w++) {
        var win = q.windows[w]
        if (win.remaining_pct === null || win.remaining_pct === undefined) continue
        if (!byLabel[win.label]) { byLabel[win.label] = { sum: 0, n: 0, min: 101, soonest: null }; labels.push(win.label) }
        var e = byLabel[win.label]
        e.sum += win.remaining_pct; e.n++
        if (win.remaining_pct < e.min) { e.min = win.remaining_pct; e.soonest = win.resets_at || null }
      }
    }
    var title = provider.toUpperCase() + " · " + list.length + (list.length === 1 ? " account" : " accounts")
      + (live < list.length ? " · " + live + " reporting" : "")
    var out = line(cat(cell(title, 36, accent), gap(1), cell(fmtInt(ok), 7, dim, true), gap(1),
                       cell(fmtInt(fail), 6, dim, true), gap(1), cell("", 5, dim)))
    if (labels.length === 0) out += line(cat(gap(2), cell("no quota data", inner - 2, dim)))
    for (var l = 0; l < labels.length; l++) {
      var e2 = byLabel[labels[l]], avg = e2.sum / e2.n
      var tail = "min " + Math.round(e2.min) + "%" + (e2.soonest ? " " + fmtDurationShort(e2.soonest - nowMs / 1000) : "")
      out += windowRow(labels[l], avg, Math.round(avg) + "% avg", avg <= 10 ? urgent : fg, tail, e2.min <= 10 ? urgent : dim)
    }
    return out
  }

  // ------------------------------------------------------------ bar widget
  readonly property string barText: {
    if (!snapshot) return ""
    if (!online) return "off"
    if (barMetric === "lowest") return lowestRemaining > 100 ? "—" : Math.round(lowestRemaining) + "%"
    var st = snapshot.stats ? snapshot.stats["24h"] : null
    if (!st) return ""
    return barMetric === "tokens" ? fmtNum(st.total_tokens) : fmtNum(st.requests)
  }

  readonly property bool vertical: bar ? bar.vertical : false

  visible: true
  implicitWidth: row.implicitWidth
  implicitHeight: bar ? bar.barSize : Style.bar.sizeHorizontal

  Row {
    id: row
    anchors.centerIn: parent
    spacing: 0

    BarIconButton {
      id: button
      bar: root.bar
      text: "󰒍"
      active: root.alarming
      onPressed: function(buttonCode) {
        if (buttonCode === Qt.RightButton) root.refresh(true)
        else if (buttonCode === Qt.MiddleButton) root.range = root.range === "24h" ? "7d" : "24h"
        else root.toggle()
      }
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: !root.vertical && root.barText !== ""
      text: root.barText
      color: root.alarming ? root.urgent : (root.bar ? root.bar.barForeground : root.fg)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      rightPadding: Style.space(6)
    }
  }

  // ------------------------------------------------------------ panel
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
    // The panel keeps its own padding inside contentWidth, so leave room for
    // that plus the text inset on both sides.
    contentWidth: panel.fittedContentWidth(colMetrics.advanceWidth + panel.padding * 2 + Style.space(12))
    contentHeight: panel.fittedContentHeight(tuiText.implicitHeight + Style.space(12), Style.space(920))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      // The catcher turns x into deleteRequested and h/l into horizontal
      // moves before textKey sees them, so hook those signals for scrub.
      onDeleteRequested: root.scrub = !root.scrub
      onMoveRequested: function(dx, dy) {
        if (dx < 0) root.scrub = !root.scrub
        if (dy !== 0)
          panelFlick.contentY = Math.max(0, Math.min(panelFlick.contentY + dy * Style.space(48),
                                                     Math.max(0, panelFlick.contentHeight - panelFlick.height)))
      }
      onActivateRequested: root.refresh(true)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh(true)
        else if (t === "t" || t === "T") root.range = root.range === "24h" ? "7d" : "24h"
        else if (t === "e" || t === "E") root.expanded = !root.expanded
        else if (t === "j") panelFlick.contentY = Math.min(panelFlick.contentY + Style.space(48), Math.max(0, panelFlick.contentHeight - panelFlick.height))
        else if (t === "k") panelFlick.contentY = Math.max(0, panelFlick.contentY - Style.space(48))
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
