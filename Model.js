var BEST = "__best__"

// windscribe-cli prints JSON debug lines to stdout on startup. They start with
// '{' and carry no state we need, so they are dropped before parsing.
function stripJsonLines(raw) {
  var lines = String(raw || "").split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.trim() === "") continue
    if (line.charAt(0) === "{") continue
    out.push(line)
  }
  return out.join("\n")
}

// `windscribe-cli status` prints "Label  : value" rows. Distinguishes the full
// connection lifecycle so the UI can track transitions instead of guessing.
//   state:       DISCONNECTED | CONNECTING | CONNECTED | DISCONNECTING | UNKNOWN
//   loginState:  loggedIn | loggingIn | loggedOut | unknown
function parseStatus(raw) {
  var out = {
    state: "UNKNOWN",
    loginState: "unknown",
    firewall: false,
    firewallMode: "",
    publicIp: "",
    dataUsage: "",
    protocol: "",
    vpnIp: "",
    serverCity: "",
    internetConnectivity: ""
  }

  var clean = stripJsonLines(raw)
  var lines = clean.split("\n")

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "") continue

    var idx = line.indexOf(":")
    if (idx < 0) continue

    var key = line.substring(0, idx).trim()
    var value = line.substring(idx + 1).trim()
    var low = value.toLowerCase()

    switch (key) {
      case "Internet connectivity":
        out.internetConnectivity = value
        break
      case "Login state":
        if (low.indexOf("not logged in") >= 0) out.loginState = "loggedOut"
        else if (low.indexOf("logging in") >= 0) out.loginState = "loggingIn"
        else if (low.indexOf("logged in") >= 0) out.loginState = "loggedIn"
        else out.loginState = "unknown"
        break
      case "Firewall state":
        out.firewallMode = value
        out.firewall = low === "on" || low === "always on"
        break
      case "Connect state":
        if (low.indexOf("disconnecting") >= 0) {
          out.state = "DISCONNECTING"
        } else if (low.indexOf("connecting") >= 0) {
          out.state = "CONNECTING"
        } else if (low.indexOf("connected") === 0) {
          out.state = "CONNECTED"
          var cityPart = value.substring("Connected".length).trim()
          if (cityPart.indexOf(":") === 0) cityPart = cityPart.substring(1).trim()
          if (cityPart !== "") out.serverCity = cityPart
        } else {
          out.state = "DISCONNECTED"
        }
        break
      case "Protocol":
        out.protocol = value
        break
      case "VPN IP":
        out.vpnIp = value
        break
      case "Public IP":
        out.publicIp = value
        break
      case "Data usage":
        out.dataUsage = value
        break
      default:
        break
    }
  }

  return out
}

// Windscribe server-list API (https://assets.windscribe.com/serverlist/ikev2/1/1).
// Verified shape:
//   { data: [ { name: "US East", country_code: "US", premium_only: 0,
//               nodes: [ { group: "New York - Big Apple", gps: "40.73,-73.94",
//                         pro_only: 1, ... } ] } ] }
// Returns { servers: [option], coords: { "City - Nickname": {lat, lon, country} } }.
function parseServersApi(jsonText) {
  var out = { servers: [], coords: {} }
  var root
  try { root = JSON.parse(String(jsonText || "")) } catch (e) { return out }
  var data = root && Array.isArray(root.data) ? root.data : []
  if (data.length === 0) return out

  var seen = {}
  for (var r = 0; r < data.length; r++) {
    var region = data[r]
    var regionName = String(region.name || "").trim()
    var country = String(region.country_code || "").toUpperCase()
    var regionPro = region.premium_only === 1
    var nodes = Array.isArray(region.nodes) ? region.nodes : []

    for (var n = 0; n < nodes.length; n++) {
      var node = nodes[n]
      var group = String(node.group || "").trim()
      if (group === "") continue
      if (seen[group]) continue
      seen[group] = true

      var pro = regionPro || node.pro_only === 1
      var gps = String(node.gps || "")
      if (gps !== "") {
        var parts = gps.split(",")
        var lat = Number(parts[0])
        var lon = Number(parts[1])
        if (isFinite(lat) && isFinite(lon)) {
          out.coords[group] = { lat: lat, lon: lon, country: country }
        }
      }

      out.servers.push({
        value: regionName + " - " + group,
        label: group,
        description: regionName + (pro ? " \u00b7 Pro" : ""),
        region: regionName,
        city: cityOf(group),
        nickname: nicknameOf(group),
        pro: pro
      })
    }
  }

  sortServers(out.servers)
  out.servers.unshift({ value: BEST, label: "Best location", description: "Lowest latency available" })
  return out
}

// Fallback server list from `windscribe-cli locations`, whose lines read
//   "US East - New York - Big Apple (Pro) (10 Gbps)"
// The availability markers are not part of the connectable name.
function parseServersCli(raw) {
  var out = { servers: [], coords: {} }
  var clean = stripJsonLines(raw)
  var lines = clean.split("\n")
  var seen = {}

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "") continue
    if (line.indexOf(" - ") < 0) continue

    var parts = line.split(" - ")
    if (parts.length < 2) continue

    var region = parts[0].trim()
    var group = parts.slice(1).join(" - ").trim()
    var pro = /\(Pro\)/i.test(group)

    group = group.replace(/\s*\(Pro\)\s*/gi, " ")
      .replace(/\s*\(\d+\s*Gbps\)\s*/gi, " ")
      .replace(/\s+/g, " ").trim()
    if (group === "" || seen[group]) continue
    seen[group] = true

    out.servers.push({
      value: region + " - " + group,
      label: group,
      description: region + (pro ? " \u00b7 Pro" : ""),
      region: region,
      city: cityOf(group),
      nickname: nicknameOf(group),
      pro: pro
    })
  }

  sortServers(out.servers)
  out.servers.unshift({ value: BEST, label: "Best location", description: "Lowest latency available" })
  return out
}

function sortServers(list) {
  list.sort(function(a, b) {
    if (a.region !== b.region) return a.region < b.region ? -1 : 1
    return a.label < b.label ? -1 : (a.label > b.label ? 1 : 0)
  })
}

// The server-list API labels every node as Pro, which hides the free
// locations. `windscribe-cli locations` marks Pro servers with "(Pro)", so it
// is the authoritative source for which groups are free. Returns
// { group: true } for every group without a "(Pro)" marker.
function parseServerFlags(raw) {
  var free = {}
  var clean = stripJsonLines(raw)
  var lines = clean.split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "") continue
    if (line.indexOf(" - ") < 0) continue
    if (/\(Pro\)/i.test(line)) continue
    var parts = line.split(" - ")
    var group = parts.slice(1).join(" - ").trim()
      .replace(/\s*\(\d+\s*Gbps\)\s*/gi, " ")
      .replace(/\s+/g, " ").trim()
    if (group !== "") free[group] = true
  }
  return free
}

// Rewrite each server's Pro flag from the CLI's free-group set and refresh
// its description. Groups missing from the CLI output are treated as Pro so a
// truncated listing can never invent a fake free server.
function applyProFlags(servers, freeGroups) {
  for (var i = 0; i < servers.length; i++) {
    var s = servers[i]
    if (s.value === BEST) continue
    var pro = !Object.prototype.hasOwnProperty.call(freeGroups, s.label)
    s.pro = pro
    s.description = s.region + (pro ? " \u00b7 Pro" : "")
  }
}

// "Toronto - Comfort Zone" -> "Toronto"
function cityOf(group) {
  var g = String(group || "").trim()
  var parts = g.split(" - ")
  return parts.length >= 2 ? parts[0].trim() : g
}

// "Toronto - Comfort Zone" -> "Comfort Zone"
function nicknameOf(group) {
  var g = String(group || "").trim()
  var parts = g.split(" - ")
  return parts.length >= 2 ? parts.slice(1).join(" - ").trim() : g
}

function statusText(status) {
  var s = String(status.state || "").toUpperCase()
  if (status.loginState === "loggedOut") return "Not logged in"
  if (status.loginState === "loggingIn") return "Signing in..."
  switch (s) {
    case "CONNECTED":     return "Connected"
    case "CONNECTING":    return "Connecting..."
    case "DISCONNECTING": return "Disconnecting..."
    case "DISCONNECTED":  return "Disconnected"
    case "UNAVAILABLE":   return "Daemon unavailable"
    default:              return "Checking..."
  }
}

function shortProtocol(protocol) {
  var p = String(protocol || "").toLowerCase()
  if (p.indexOf("wireguard") >= 0) return "WG"
  if (p.indexOf("stealth") >= 0) return "Stealth"
  if (p.indexOf("udp") >= 0) return "UDP"
  if (p.indexOf("tcp") >= 0) return "TCP"
  return String(protocol || "")
}

function elide(text) {
  var value = String(text || "").replace(/\s+/g, " ").trim()
  return value.length > 140 ? value.substring(0, 137) + "..." : value
}

// ---------------------------------------------------------------------------
// Map
var MAP_W = 96
var MAP_H = 37
var LAT_TOP = 83.0
var LAT_BOT = -56.0

var LAND = [
  "000000000000000000000000111111011111111111110000000000000000000000000000010000000000000000000000",
  "000000000000000010000000011000111111111111100000000010000000000000000000000100000000000000000000",
  "000000000000000110000111001000000111111111000000000000000000000000000111111111110000010000000000",
  "000001111100010001111010001111000111111111000000000001110000000000101111111111111111111111100100",
  "111001111111111111111111100011100011110000010000000111111001111111111111111111111111111111111111",
  "000011111111111111111110000100000001100000000000011110111111111111111111111111111111111111111110",
  "000000100001111111111110000111100000000000000000000100111111111111111111111111111111110000100000",
  "000010000000011111111111110111111000000000000001001001111111111111111111111111111111000001100000",
  "000000000000001111111111111111110000000000000001011111111111111111111111111111111111100000000000",
  "000000000000000111111111111111100000000000000001111111111111111111111111111111111111100000000000",
  "000000000000000111111111111110000000000000000010110111110001111111111111111111111111001000000000",
  "000000000000000111111111111100000000000000000011001001011111111111111111111111111100010000000000",
  "000000000000000011111111111100000000000000000010111000000011111111111111111111110010110000000000",
  "000000000000000001111111111000000000000000000011111101000111111111111111111111110000000000000000",
  "000000000000000000111100001000000000000000000111111111111111101111111111111111110000000000000000",
  "000000000000000000011100000000000000000000001111111111111011110000111111111111111000000000000000",
  "000000000000000000001100100100000000000000011111111111111111111100011110011111000000000000000000",
  "000000000000000000000111000000000000000000001111111111111101111000001100011110001000000000000000",
  "000000000000000000000000110000000000000000001111111111111110100000001000001110000000000000000000",
  "000000000000000000000000010011110000000000001111111111111111110000001000000000000000000000000000",
  "000000000000000000000000000111111000000000000111011111111111100000000000000000000100000000000000",
  "000000000000000000000000000111111110000000000000000111111111000000000000001100100000000000000000",
  "000000000000000000000000001111111111000000000000001111111110000000000000000101101001000000000000",
  "000000000000000000000000001111111111111000000000000111111100000000000000000000000000011010000000",
  "000000000000000000000000000111111111111000000000000111111110000000000000000000000100000100000000",
  "000000000000000000000000000011111111110000000000000111111110100000000000000000000111101000000000",
  "000000000000000000000000000001111111110000000000000111111000100000000000000000001111111100000000",
  "000000000000000000000000000001111111000000000000000011111000100000000000000000111111111100000000",
  "000000000000000000000000000001111110000000000000000011111000000000000000000000111111111110000000",
  "000000000000000000000000000001111100000000000000000001110000000000000000000000011111111110000000",
  "000000000000000000000000000001111000000000000000000000000000000000000000000000000000011100000000",
  "000000000000000000000000000011100000000000000000000000000000000000000000000000000000000000000010",
  "000000000000000000000000000001100000000000000000000000000000000000000000000000000000000000000000",
  "000000000000000000000000000011000000000000000000000000000000000000000000000000000000000000000000",
  "000000000000000000000000000011000000000000000000000000000000000000000000000000000000000000000000",
  "000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000"
]

function project(lat, lon) {
  var la = Number(lat), lo = Number(lon)
  if (!isFinite(la) || !isFinite(lo)) return null
  if (la > LAT_TOP) la = LAT_TOP
  if (la < LAT_BOT) la = LAT_BOT
  return {
    x: (lo + 180) / 360,
    y: (LAT_TOP - la) / (LAT_TOP - LAT_BOT)
  }
}

function parseIso6709(text) {
  var m = /^([+-])(\d{2})(\d{2})(\d{2})?([+-])(\d{3})(\d{2})(\d{2})?$/.exec(String(text || "").trim())
  if (!m) return null
  var lat = Number(m[2]) + Number(m[3]) / 60 + (m[4] ? Number(m[4]) / 3600 : 0)
  var lon = Number(m[6]) + Number(m[7]) / 60 + (m[8] ? Number(m[8]) / 3600 : 0)
  if (m[1] === "-") lat = -lat
  if (m[5] === "-") lon = -lon
  return { lat: lat, lon: lon }
}

function zoneCoords(zoneTabText, timezone) {
  var want = String(timezone || "").trim()
  if (want === "") return null
  var lines = String(zoneTabText || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].charAt(0) === "#") continue
    var f = lines[i].split("\t")
    if (f.length < 3) continue
    if (f[2].trim() === want) return parseIso6709(f[1])
  }
  return null
}

// Match a city name against zone.tab. The server group is "City - Nickname",
// so callers strip the nickname first with cityOf().
function cityCoords(zoneTabText, city) {
  var want = String(city || "").replace(/\s*\([A-Z]{2}\)\s*$/, "").replace(/,.*$/, "").trim().toLowerCase()
  if (want === "") return null
  var lines = String(zoneTabText || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].charAt(0) === "#") continue
    var f = lines[i].split("\t")
    if (f.length < 3) continue
    var zoneCity = f[2].trim().split("/").pop().replace(/_/g, " ").toLowerCase()
    if (zoneCity === want) return parseIso6709(f[1])
  }
  return null
}

// Country centroid as a last resort: the first zone.tab entry for a country
// code. zone.tab's second field is ISO 6709, third is the zone name.
function countryCoords(zoneTabText, countryCode) {
  var cc = String(countryCode || "").toUpperCase().trim()
  if (cc === "") return null
  var lines = String(zoneTabText || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].charAt(0) === "#") continue
    var f = lines[i].split("\t")
    if (f.length < 2) continue
    if (f[0].trim().toUpperCase() === cc) return parseIso6709(f[1])
  }
  return null
}

function parseConnectedAt(text) {
  var m = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})\s*([+-])(\d{2})(\d{2})/.exec(String(text || "").trim())
  if (!m) return 0
  var utc = Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6])
  var offset = (+m[8] * 60 + +m[9]) * 60000
  return m[7] === "-" ? utc + offset : utc - offset
}

function formatDuration(ms) {
  if (!isFinite(ms) || ms <= 0) return ""
  var total = Math.floor(ms / 1000)
  var d = Math.floor(total / 86400)
  var h = Math.floor((total % 86400) / 3600)
  var mi = Math.floor((total % 3600) / 60)
  var s = total % 60
  if (d > 0) return d + "d " + h + "h"
  if (h > 0) return h + "h " + mi + "m"
  if (mi > 0) return mi + "m " + s + "s"
  return s + "s"
}

function relativeAge(ms) {
  var age = Number(ms)
  if (!isFinite(age) || age < 0) return ""
  var mins = Math.floor(age / 60000)
  if (mins < 2) return "just now"
  if (mins < 60) return mins + "m ago"
  var hours = Math.floor(mins / 60)
  if (hours < 24) return hours + "h ago"
  return Math.floor(hours / 24) + "d ago"
}
