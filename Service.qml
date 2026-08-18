import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Windscribe allows only ONE `windscribe-cli` instance at a time; a second one
// prints "Windscribe CLI is already running" and can override an in-flight
// connect. Every invocation therefore goes through a single Process behind a
// FIFO queue, so status polls, connects, disconnects and firewall toggles can
// never collide.
Item {
  id: root

  property var settings: ({})

  // Parsed `windscribe-cli status`.
  property var status: ({ state: "UNKNOWN", loginState: "unknown", firewall: false })
  // Dropdown options (first is the synthetic "Best location").
  property var servers: []
  // "City - Nickname" -> { lat, lon, country }, from the server-list API.
  property var coordsByGroup: ({})
  property bool serversReady: false
  property string selectedServer: Model.BEST

  // Public-address cache, populated only while disconnected.
  property var homeGeo: null
  // Live reading of the tunnel exit.
  property var exitGeo: null

  // Optimistic toggle state so the switch reacts on click. -1 follows the
  // real state; 0/1 while a toggle settles.
  property int _desired: -1

  // FIFO queue of { command: [args], kind: "poll"|"control"|"fetch" }.
  property var _queue: []
  property var _current: null
  property bool _hasQueuedPoll: false
  property bool _apiInFlight: false
  property bool _everParsed: false
  property bool _flagsMerged: false
  property var _freeGroups: ({})
  property string lastDataUsage: ""
  property string zoneTabText: ""
  property string timezone: ""

  readonly property string state: String(status.state || "UNKNOWN")
  readonly property string loginState: String(status.loginState || "unknown")
  readonly property bool loggedIn: loginState === "loggedIn" || loginState === "loggingIn"
  readonly property bool connected: state === "CONNECTED"
  readonly property bool transitioning: state === "CONNECTING" || state === "DISCONNECTING"
  readonly property bool unavailable: state === "UNAVAILABLE"
  readonly property bool active: _desired === -1 ? connected : (_desired === 1)
  readonly property bool firewallOn: status.firewall === true
  readonly property bool busy: cliProcess.running || _queue.length > 0
  readonly property string statusText: Model.statusText(status)
  readonly property string serverCity: String(status.serverCity || "")
  readonly property string protocolLabel: Model.shortProtocol(status.protocol)
  readonly property string dataUsage: String(status.dataUsage || root.lastDataUsage)
  readonly property string vpnIp: String(status.vpnIp || "")
  readonly property string publicIp: String(status.publicIp || "")

  readonly property bool publicIpLookup: setting("publicIpLookup", false) === true
    || String(setting("publicIpLookup", false)) === "true"
  property double _lastLookup: 0

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 5, 2, 60)
  readonly property string protocol: String(setting("protocol", "WireGuard"))
  readonly property string statePath: Quickshell.env("HOME") + "/.config/omarchy/windscribe-widget.json"
  readonly property string cachePath: Quickshell.env("HOME") + "/.config/omarchy/windscribe-servers.json"
  readonly property string serverListUrl: "https://assets.windscribe.com/serverlist/ikev2/1/1"
  readonly property int cacheTtlMs: 12 * 3600 * 1000

  property string actionStatus: ""
  property string lastError: ""

  // Where the tunnel comes out. Prefer the API's per-group GPS, then a zone.tab
  // city match, then a zone.tab country point.
  readonly property var serverCoords: {
    if (exitGeo && connected && isFinite(exitGeo.lat)) return { lat: exitGeo.lat, lon: exitGeo.lon }
    var group = serverCity
    if (group !== "") {
      var hit = coordsByGroup[group]
      if (hit && isFinite(hit.lat) && isFinite(hit.lon)) return { lat: hit.lat, lon: hit.lon }
      var city = Model.cityOf(group)
      var cc = hit ? hit.country : ""
      var cityPt = Model.cityCoords(zoneTabText, city)
      if (cityPt) return cityPt
      if (cc !== "") {
        var countryPt = Model.countryCoords(zoneTabText, cc)
        if (countryPt) return countryPt
      }
    }
    return null
  }

  readonly property var homeCoords: (homeGeo && isFinite(homeGeo.lat) && isFinite(homeGeo.lon))
    ? { lat: homeGeo.lat, lon: homeGeo.lon }
    : Model.zoneCoords(zoneTabText, timezone)
  readonly property string homeLabel: (homeGeo && homeGeo.city)
    ? String(homeGeo.city)
    : String(timezone || "").split("/").pop().replace(/_/g, " ")
  readonly property string homeDetail: {
    if (homeGeo) {
      var line = String(homeGeo.ip || "")
      var age = (_now > 0 && isFinite(homeGeo.at)) ? Model.relativeAge(_now - homeGeo.at) : ""
      return age !== "" && age !== "just now" ? line + " \u00b7 " + age : line
    }
    if (!publicIpLookup) return "from your timezone"
    return connected ? "hidden by the tunnel" : "looking up..."
  }

  property double _now: 0
  property double connectedAt: 0
  readonly property string durationText: (connected && connectedAt > 0 && _now > 0)
    ? Model.formatDuration(_now - connectedAt) : ""

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function protocolArg() {
    var p = String(protocol).toLowerCase()
    if (p.indexOf("stealth") >= 0) return "stealth"
    if (p.indexOf("tcp") >= 0) return "tcp"
    if (p.indexOf("udp") >= 0) return "udp"
    return "wireguard"
  }

  // -------------------------------------------------------------------------
  // Queue

  function _controlInFlight() {
    if (_current && (_current.kind === "control" || _current.kind === "fetch")) return true
    for (var i = 0; i < _queue.length; i++)
      if (_queue[i].kind === "control" || _queue[i].kind === "fetch") return true
    return false
  }

  function enqueue(item) {
    _queue.push(item)
    _drain()
  }

  // A periodic status poll: coalesced (never more than one queued) and skipped
  // while a control command or server fetch is running/queued. `force` (used
  // after a control command) bypasses the skip rule.
  function requestStatus(force) {
    if (_hasQueuedPoll) return
    if (!force && _controlInFlight()) return
    _hasQueuedPoll = true
    enqueue({ command: ["windscribe-cli", "status"], kind: "poll" })
  }

  function _drain() {
    if (cliProcess.running || _queue.length === 0) return
    _current = _queue.shift()
    if (_current.kind === "poll") _hasQueuedPoll = false
    cliProcess.command = _current.command
    cliProcess.running = true
  }

  function fail(message) {
    root.lastError = Model.elide(message)
    root.actionStatus = root.lastError
    actionStatusTimer.restart()
  }

  // -------------------------------------------------------------------------
  // Actions

  function connectArgs() {
    var target = selectedServer === Model.BEST ? "best" : serverTarget(selectedServer)
    return ["windscribe-cli", "connect", target, protocolArg()]
  }

  // `windscribe-cli connect` matches a country code, region, city, or nickname
  // — NOT the full "Region - City - Nickname" string. Nicknames are unique, so
  // resolve the dropdown value to its nickname before connecting.
  function serverTarget(value) {
    for (var i = 0; i < root.servers.length; i++) {
      var s = root.servers[i]
      if (s.value === value && s.nickname) return s.nickname
    }
    var parts = String(value).split(" - ")
    return parts[parts.length - 1].trim()
  }

  // Last connect/disconnect intent already in the queue, or null if none.
  // Lets rapid toggles resolve in FIFO order instead of all reading the same
  // (stale) parsed state.
  function _lastConnectIntent() {
    var last = null
    for (var i = 0; i < _queue.length; i++) {
      var it = _queue[i]
      if (it.kind === "control" && it.connect !== undefined) last = it.connect
    }
    return last
  }

  function toggle() {
    if (loginState === "loggedOut") {
      fail("Not logged in. Run: windscribe-cli login")
      return
    }
    var last = _lastConnectIntent()
    var wantConnect = last === null ? !(root.connected || root.transitioning) : last
    root._desired = wantConnect ? 1 : 0
    if (wantConnect) {
      enqueue({ kind: "control", connect: true, command: connectArgs() })
    } else {
      enqueue({ kind: "control", connect: false, command: ["windscribe-cli", "disconnect"] })
    }
  }

  // Explicit connect/disconnect: idempotent against live state AND queued
  // intent, so a rapid connect() -> disconnect() resolves to the last intent
  // in FIFO order instead of both gating on the same stale status.
  function connect() {
    if (loginState === "loggedOut") { fail("Not logged in. Run: windscribe-cli login"); return }
    var last = _lastConnectIntent()
    var wantConnect = last === null ? (root.connected || root.transitioning) : last
    if (wantConnect) return
    root._desired = 1
    enqueue({ kind: "control", connect: true, command: connectArgs() })
  }

  function disconnect() {
    if (loginState === "loggedOut") return
    var last = _lastConnectIntent()
    var wantConnect = last === null ? (root.connected || root.transitioning) : last
    if (!wantConnect) return
    root._desired = 0
    enqueue({ kind: "control", connect: false, command: ["windscribe-cli", "disconnect"] })
  }

  function setFirewall(on) {
    enqueue({ command: ["windscribe-cli", "firewall", on ? "on" : "off"], kind: "control" })
  }

  function selectServer(value) {
    if (!value || value === root.selectedServer) return
    root.selectedServer = value
    saveState()
    if (root.connected && !_controlInFlight()) {
      _desired = 1
      enqueue({ command: connectArgs(), kind: "control" })
    }
  }

  // -------------------------------------------------------------------------
  // Server list

  function applyServerList(parsed) {
    if (!parsed || !parsed.servers || parsed.servers.length <= 1) return
    root.servers = parsed.servers
    root.coordsByGroup = parsed.coords || ({})
    root.serversReady = true
  }

  function loadCachedServers() {
    try {
      var c = JSON.parse(serverCacheFile.text())
      if (!c || c.version !== 2 || !c.servers || c.servers.length <= 1) {
        loadServers(false)
        return
      }
      if (c.freeGroups) {
        root._freeGroups = c.freeGroups
        root._flagsMerged = true
        Model.applyProFlags(c.servers, c.freeGroups)
      }
      applyServerList({ servers: c.servers, coords: c.coords || ({}) })
      if (Date.now() - Number(c.fetchedAt || 0) > root.cacheTtlMs) loadServers(true)
    } catch (e) {
      loadServers(false)
    }
  }

  function saveServerCache() {
    serverCacheFile.setText(JSON.stringify({
      version: 2,
      fetchedAt: Date.now(),
      servers: root.servers,
      coords: root.coordsByGroup || ({}),
      freeGroups: root._freeGroups
    }, null, 2) + "\n")
  }

  // API first (reliable, has coordinates + names), CLI locations as a
  // fallback. Fetched at startup and on manual refresh only, never per-poll.
  function loadServers(force) {
    if (!force && root.serversReady) return
    if (root._apiInFlight) return
    root._apiInFlight = true
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      root._apiInFlight = false
      if (xhr.status === 200) {
        var parsed = Model.parseServersApi(xhr.responseText)
        if (parsed.servers.length > 1) {
          applyServerList(parsed)
          if (Object.keys(root._freeGroups).length > 0) {
            // Fresh list, but reuse the free-group flags we already know from
            // the cache — otherwise every node arrives marked Pro again.
            Model.applyProFlags(root.servers, root._freeGroups)
            root.servers = root.servers.slice()
            root.saveServerCache()
          } else {
            requestProMerge()
          }
          return
        }
      }
      requestCliServers()
    }
    xhr.open("GET", root.serverListUrl)
    xhr.send()
  }

  // CLI locations know which groups are free (the API marks everything Pro).
  // Runs once per server load, serialized through the queue.
  function requestProMerge() {
    if (root._flagsMerged) return
    root._flagsMerged = true
    enqueue({ command: ["windscribe-cli", "locations"], kind: "fetch", merge: true })
  }

  function requestCliServers() {
    enqueue({ command: ["windscribe-cli", "locations"], kind: "fetch" })
  }

  function refresh() {
    requestStatus(false)
    if (!root.serversReady) loadServers(false)
    geoLookup(false)
  }

  // -------------------------------------------------------------------------
  // State + geo

  function saveState() {
    stateFile.setText(JSON.stringify({
      selectedServer: root.selectedServer,
      homeGeo: root.homeGeo
    }, null, 2) + "\n")
  }

  // ipinfo.io: loc is "lat,lon"; org is the ISP. While the tunnel is up the
  // lookup reports the exit, so a real home address is only captured while
  // disconnected (hence the cache).
  function geoLookup(force) {
    if (!publicIpLookup) return
    var now = Date.now()
    if (!force && now - root._lastLookup < 60000) return
    root._lastLookup = now
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      if (xhr.status !== 200) return
      var geo
      try { geo = JSON.parse(xhr.responseText) } catch (e) { return }
      var loc = String(geo.loc || "").split(",")
      var lat = Number(loc[0]), lon = Number(loc[1])
      if (!isFinite(lat) || !isFinite(lon)) return
      var record = {
        ip: String(geo.ip || ""),
        city: String(geo.city || geo.region || ""),
        country: String(geo.country || ""),
        isp: String(geo.org || ""),
        lat: lat,
        lon: lon,
        at: Date.now()
      }
      if (root.connected) root.exitGeo = record
      else { root.homeGeo = record; root.saveState() }
    }
    xhr.open("GET", "https://ipinfo.io/json")
    xhr.send()
  }

  onConnectedChanged: {
    geoLookup(true)
    if (connected) root.connectedAt = Date.now()
  }

  // -------------------------------------------------------------------------
  // Files

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    onFileChanged: stateFile.reload()
    onLoaded: {
      try {
        var saved = JSON.parse(stateFile.text())
        if (saved && saved.selectedServer) root.selectedServer = String(saved.selectedServer)
        if (saved && saved.homeGeo && isFinite(saved.homeGeo.lat)) root.homeGeo = saved.homeGeo
      } catch (e) {}
    }
  }

  FileView {
    id: serverCacheFile
    path: root.cachePath
    watchChanges: false
    onLoaded: root.loadCachedServers()
  }

  FileView {
    id: zoneTabFile
    path: "/usr/share/zoneinfo/zone.tab"
    onLoaded: root.zoneTabText = zoneTabFile.text()
  }

  // -------------------------------------------------------------------------
  // Timers

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: clockTimer
    interval: 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root._now = Date.now()
  }

  // Poll a few times after a control command so the icon catches up without
  // waiting for the periodic refresh. Coalescing keeps at most one poll live.
  Timer {
    id: settleTimer
    property int ticks: 0
    interval: 1000
    repeat: true
    running: false
    onTriggered: {
      settleTimer.ticks += 1
      root.requestStatus(true)
      if (settleTimer.ticks >= 5) {
        settleTimer.ticks = 0
        settleTimer.running = false
        root._desired = -1
      }
    }
  }

  Timer {
    id: watchdogTimer
    interval: 12000
    repeat: false
    running: true
    onTriggered: if (!root._everParsed) root.status = { state: "UNAVAILABLE", loginState: "unknown", firewall: false }
  }

  Timer {
    id: actionStatusTimer
    interval: 3000
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Process {
    id: timezoneProcess
    running: true
    command: ["timedatectl", "show", "-p", "Timezone", "--value"]
    stdout: StdioCollector {
      id: timezoneStdout
      waitForEnd: true
      onStreamFinished: root.timezone = String(text || "").trim()
    }
  }

  // The single owner of `windscribe-cli`. Nothing else may spawn it.
  Process {
    id: cliProcess
    running: false
    command: []
    stdout: StdioCollector { id: cliStdout; waitForEnd: true }
    stderr: StdioCollector { id: cliStderr; waitForEnd: true }

    onExited: function(exitCode) {
      var text = String(cliStdout.text || cliStderr.text || "")
      var item = root._current
      root._current = null

      if (!item) { root._drain(); return }

      if (item.kind === "poll") {
        if (text.trim() !== "") {
          var parsed = Model.parseStatus(text)
          if (parsed.dataUsage !== "") root.lastDataUsage = parsed.dataUsage
          // A concurrent manual `windscribe-cli` run yields only a
          // "already running" line, which parses to UNKNOWN. Keep the last
          // known status rather than flashing "Checking..." at the user.
          if (parsed.state !== "UNKNOWN" || !root._everParsed) {
            if (parsed.state !== "UNKNOWN") root._everParsed = true
            root.status = parsed
          }
          if (root._desired !== -1 && root.connected === (root._desired === 1)) root._desired = -1
        } else if (exitCode !== 0) {
          root.status = { state: "UNAVAILABLE", loginState: "unknown", firewall: false }
        }
      } else if (item.kind === "control") {
        if (exitCode !== 0) {
          root._desired = -1
          root.fail(String(cliStderr.text || cliStdout.text || "").trim() || "Windscribe command failed")
        } else {
          root.lastError = ""
          root.actionStatus = ""
        }
        settleTimer.ticks = 0
        settleTimer.restart()
      } else if (item.kind === "fetch") {
        if (exitCode === 0) {
          if (item.merge) {
            var flags = Model.parseServerFlags(text)
            if (Object.keys(flags).length > 0) {
              root._freeGroups = flags
              Model.applyProFlags(root.servers, flags)
              root.servers = root.servers.slice()
            }
            root.saveServerCache()
          } else {
            var cli = Model.parseServersCli(text)
            root.applyServerList(cli)
          }
        }
      }

      root._drain()
    }
  }

  Component.onCompleted: {
    root.loadServers(false)
  }
}
