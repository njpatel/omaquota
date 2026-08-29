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
  readonly property int cols: 62
  readonly property string tui: buildTui()

  function line(inner, color) {
    // `inner` is already HTML; `plainLen` tells us how much to pad.
    return span("│ ", faint) + inner.html + esc(rep(" ", Math.max(0, cols - 4 - inner.len))) + span(" │", faint) + "<br>"
  }
  function h(text, len) { return { html: text, len: len } }
  function rule(title, first, last) {
    var l = first ? "┌" : (last ? "└" : "├"), r = first ? "┐" : (last ? "┘" : "┤")
    if (!title) return span(l + rep("─", cols - 2) + r, faint) + "<br>"
    var t = "─ " + title + " "
    return span(l + t, faint).replace(esc(title), span(title, dim)) + span(rep("─", cols - 2 - t.length) + r, faint) + "<br>"
  }

  function accountLines(acct) {
    var out = ""
    var q = acct.quota || {}
    var statusTxt = acct.disabled ? "disabled" : (acct.unavailable ? "unavailable" : (acct.status || "?"))
    var right = "ok " + fmtInt(acct.success) + " · fail " + fmtInt(acct.failed)
    if (q.plan) right = q.plan + " · " + right
    var nameW = cols - 4 - right.length - 2
    var nameTxt = pad(displayName(acct.email), nameW)
    out += line(h(span(nameTxt, scrub ? dim : fg) + "  " + span(right, dim), nameTxt.length + 2 + right.length))

    var wins = q.windows || []
    if (wins.length === 0) {
      var why = q.error ? String(q.error) : statusTxt
      var w0 = "  " + why.slice(0, cols - 8)
      out += line(h(span(w0, q.error && q.error !== "disabled" ? urgent : dim), w0.length))
    }
    for (var w = 0; w < wins.length; w++) {
      var win = wins[w]
      var lab = pad(win.label, 10)
      var barW2 = 20
      var left = win.remaining_pct === null || win.remaining_pct === undefined ? "  —" : lpad(Math.round(win.remaining_pct) + "%", 4)
      var resets = win.resets_at ? "resets " + fmtDuration(win.resets_at - nowMs / 1000) : ""
      var plain = "  " + lab + " " + rep("x", barW2) + " " + left + " left  " + resets
      var leftColor = win.remaining_pct !== null && win.remaining_pct <= 10 ? urgent : fg
      out += line(h("  " + span(lab, dim) + " " + meter(win.remaining_pct, barW2) + " " + span(left, leftColor)
                     + span(" left  ", dim) + span(resets, q.stale ? faint : dim), plain.length))
    }
    if (q.stale || q.error) {
      var note = "  " + (q.stale ? "stale · " : "") + (q.error ? String(q.error) : "") + (q.retry_until && q.retry_until > nowMs / 1000 ? " · retry in " + fmtDuration(q.retry_until - nowMs / 1000) : "")
      if (wins.length > 0) out += line(h(span(note.slice(0, cols - 4), faint), Math.min(note.length, cols - 4)))
    }
    return out
  }

  // One block per provider: account count, summed counters, then for every
  // window label the average and the worst remaining across the accounts.
  function aggregateLines(plabel, list) {
    var out = ""
    var ok = 0, fail = 0, live = 0
    var byLabel = ({}), labels = []
    for (var i = 0; i < list.length; i++) {
      var acct = list[i]
      ok += acct.success; fail += acct.failed
      var q = acct.quota || {}
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
    var right = "ok " + fmtInt(ok) + " · fail " + fmtInt(fail)
    var head = plabel + "  " + list.length + (list.length === 1 ? " account" : " accounts") + (live < list.length ? " (" + live + " reporting)" : "")
    var headTxt = pad(head, cols - 4 - right.length - 2)
    out += line(h(span(headTxt, accent) + "  " + span(right, dim), headTxt.length + 2 + right.length))
    if (labels.length === 0) {
      var none = "  no quota data"
      out += line(h(span(none, dim), none.length))
    }
    for (var l = 0; l < labels.length; l++) {
      var e2 = byLabel[labels[l]]
      var avg = e2.sum / e2.n
      var lab = pad(labels[l], 10)
      var barW2 = 20
      var avgTxt = lpad(Math.round(avg) + "%", 4)
      var minTxt = "min " + Math.round(e2.min) + "%" + (e2.soonest ? " · " + fmtDuration(e2.soonest - nowMs / 1000) : "")
      var plain = "  " + lab + " " + rep("x", barW2) + " " + avgTxt + " avg  " + minTxt
      out += line(h("  " + span(lab, dim) + " " + meter(avg, barW2) + " " + span(avgTxt, avg <= 10 ? urgent : fg)
                     + span(" avg  ", dim) + span(minTxt, e2.min <= 10 ? urgent : dim), plain.length))
    }
    return out
  }

  function buildTui() {
    var out = ""
    var snap = root.snapshot
    var gen = snap && snap.generated_ts ? fmtAge(snap.generated_ts) : "never"
    var head = "CLIPROXYAPI @ " + hostLabel
    out += rule(head, true, false)

    if (!snap) {
      out += line(h(span("no snapshot yet — fetching…", dim), 27))
      out += rule("", false, true)
      return out
    }
    if (!snap.ok) {
      var err = String(snap.error || "offline")
      out += line(h(span("✗ " + err.slice(0, cols - 6), urgent), Math.min(err.length + 2, cols - 6)))
      out += line(h(span("last good data " + gen, dim), 15 + gen.length))
    }

    // ---- stats block
    var st = root.stats
    if (st && st.requests !== undefined) {
      var failPct = st.requests > 0 ? (100 * st.failed / st.requests) : 0
      var l1 = pad("requests " + range, 14) + lpad(fmtInt(st.requests), 8) + "   failed " + fmtInt(st.failed) + " (" + failPct.toFixed(1) + "%)"
      out += line(h(span(pad("requests " + range, 14), dim) + span(lpad(fmtInt(st.requests), 8), fg)
                     + span("   failed ", dim) + span(fmtInt(st.failed) + " (" + failPct.toFixed(1) + "%)", st.failed > 0 ? accent : fg), l1.length))
      var l2 = pad("tokens", 14) + "in " + lpad(fmtNum(st.input_tokens), 7) + "  out " + lpad(fmtNum(st.output_tokens), 7) + "  cached " + fmtNum(st.cached_tokens) + " (" + Math.round(100 * (st.cache_hit || 0)) + "%)"
      out += line(h(span(pad("tokens", 14), dim) + span("in ", dim) + span(lpad(fmtNum(st.input_tokens), 7), fg)
                     + span("  out ", dim) + span(lpad(fmtNum(st.output_tokens), 7), fg)
                     + span("  cached ", dim) + span(fmtNum(st.cached_tokens) + " (" + Math.round(100 * (st.cache_hit || 0)) + "%)", fg), l2.length))
      var l3 = pad("latency", 14) + "avg " + lpad(fmtMs(st.avg_latency_ms), 7) + "  ttft " + lpad(fmtMs(st.avg_ttft_ms), 7)
      out += line(h(span(pad("latency", 14), dim) + span("avg ", dim) + span(lpad(fmtMs(st.avg_latency_ms), 7), fg)
                     + span("  ttft ", dim) + span(lpad(fmtMs(st.avg_ttft_ms), 7), fg), l3.length))
      out += line(h("", 0))

      // ---- models
      out += rule("MODELS " + range + "  (t toggles range)", false, false)
      var models = st.models || []
      var maxReq = 0
      for (var i = 0; i < models.length; i++) maxReq = Math.max(maxReq, models[i].requests)
      if (models.length === 0) out += line(h(span("no traffic in this range", dim), 24))
      for (var m = 0; m < models.length; m++) {
        var md = models[m]
        var nameW = 18, barW = 20
        var txt = pad(md.model, nameW) + " " + rep("x", barW) + " " + lpad(fmtInt(md.requests), 6) + " " + lpad(fmtNum(md.total_tokens), 7)
        out += line(h(span(pad(md.model, nameW), fg) + " " + share(md.requests, maxReq, barW) + " "
                       + span(lpad(fmtInt(md.requests), 6), fg) + " " + span(lpad(fmtNum(md.total_tokens), 7), dim), txt.length))
      }
      out += line(h("", 0))
    } else {
      out += line(h(span("stats unavailable" + (st && st.error ? ": " + String(st.error).slice(0, 36) : ""), dim), 17))
    }

    // ---- subscriptions
    out += rule("SUBSCRIPTIONS  " + accounts.length + " · lowest " + (lowestRemaining > 100 ? "—" : Math.round(lowestRemaining) + "% left")
                + (expanded ? "" : " · aggregated"), false, false)
    var groups = []
    var byProvider = ({})
    for (var a = 0; a < accounts.length; a++) {
      var prov = accounts[a].provider
      if (!byProvider[prov]) { byProvider[prov] = []; groups.push(prov) }
      byProvider[prov].push(accounts[a])
    }
    for (var g = 0; g < groups.length; g++) {
      var list = byProvider[groups[g]]
      var plabel = groups[g].toUpperCase()
      if (expanded) {
        out += line(h(span(plabel, accent), plabel.length))
        for (var i2 = 0; i2 < list.length; i2++) out += accountLines(list[i2])
      } else {
        out += aggregateLines(plabel, list)
      }
      out += line(h("", 0))
    }
    // ---- footer
    var foot = "updated " + gen + (fetching ? " · fetching…" : "") + "  j/k r t e x/h" + (scrub ? " · scrubbed" : "")
    out += rule("", false, false)
    out += line(h(span(foot.slice(0, cols - 4), fg), Math.min(foot.length, cols - 4)))
    out += rule("", false, true)
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
