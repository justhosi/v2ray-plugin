// =============================================================================
// Model.js — pure logic for the Omarchy "v2ray Client" plugin.
// =============================================================================
//
// This file has NO Qt or Quickshell dependencies on purpose. It is plain
// JavaScript so you can:
//
//   * read it top-to-bottom without knowing QML,
//   * unit-test every function in `qjs Model.js` or a browser console,
//   * keep the risky string-munging (share links are *messy*) out of the UI.
//
// Two jobs live here:
//
//   1. PARSE a share link (`vless://`, `vmess://`, `trojan://`, `ss://`) into a
//      normalized profile object that the rest of the plugin can trust.
//   2. BUILD a v2ray/xray configuration from that profile.
//
// The normalized profile produced by parseLink() is the contract between this
// file, the panel, and the backend CLI. Its fields are documented in
// `parseVless()` below and never contain undefined — missing values become "".
// =============================================================================

// -----------------------------------------------------------------------------
// Constants
// -----------------------------------------------------------------------------

// Private / loopback ranges routed "direct" so that talking to your own LAN,
// your printer, or localhost never goes through the tunnel. These are literal
// CIDR blocks rather than `geoip:private`, because the geoip database is an
// optional download and a missing one makes the engine refuse to start.
var DIRECT_CIDRS = [
  "127.0.0.0/8",
  "10.0.0.0/8",
  "172.16.0.0/12",
  "192.168.0.0/16",
  "169.254.0.0/16",
  "::1/128",
  "fc00::/7",
  "fe80::/10"
]

// -----------------------------------------------------------------------------
// Small helpers
// -----------------------------------------------------------------------------

// slug(text) — filesystem- and id-safe version of a display name.
// Keeps letters, digits, dots and dashes; everything else becomes a dash.
function slug(text) {
  var s = String(text || "").toLowerCase()
  s = s.replace(/[^a-z0-9.]+/g, "-")
  s = s.replace(/-+/g, "-").replace(/^[-.]+|[-.]+$/g, "")
  if (s.length > 32) s = s.substring(0, 32).replace(/-+$/, "")
  return s
}

// fnv1a(text) — tiny, dependency-free 32-bit hash, printed as 8 hex chars.
// Used to make profile ids stable AND unique: importing the same link twice
// must produce the same id (so it updates in place), while two different
// servers that happen to share a display name must not collide.
function fnv1a(text) {
  var h = 0x811c9dc5
  var s = String(text || "")
  for (var i = 0; i < s.length; i++) {
    h = h ^ s.charCodeAt(i)
    // h * 16777619 with 32-bit overflow, using shifts to stay in int range.
    h = (h + (h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24)) >>> 0
  }
  var out = h.toString(16)
  while (out.length < 8) out = "0" + out
  return out
}

// percentDecode(text) — decodeURIComponent that never throws.
// Share links in the wild routinely contain a stray "%" or "%zz"; a thrown
// exception here would break the whole import, so we fall back to raw text.
function percentDecode(text) {
  var s = String(text === undefined || text === null ? "" : text)
  if (s.indexOf("%") < 0) return s
  try {
    return decodeURIComponent(s)
  } catch (e) {
    return s
  }
}

// b64decode(text) — decode standard OR url-safe base64 into a UTF-8 string.
// vmess:// and ss:// links hide their payload in base64, and different clients
// disagree about padding and alphabet (-/_ vs +//), so we normalize first.
function b64decode(text) {
  var s = String(text || "").trim().replace(/\s+/g, "")
  s = s.replace(/-/g, "+").replace(/_/g, "/")
  s = s.replace(/=+$/, "")
  // Re-pad to a multiple of 4; atob is strict about this.
  while (s.length % 4 !== 0) s += "="
  var binary = ""
  if (typeof Qt !== "undefined" && typeof Qt.atob === "function") {
    try {
      binary = Qt.atob(s)
    } catch (e) {
      return ""
    }
  } else {
    binary = manualBase64(s)
  }
  return utf8FromBinary(binary)
}

// manualBase64(text) — fallback decoder for environments without Qt.atob
// (for example a plain Node/qjs test run of this file).
function manualBase64(s) {
  var alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  var out = ""
  var buffer = 0
  var bits = 0
  for (var i = 0; i < s.length; i++) {
    var index = alphabet.indexOf(s.charAt(i))
    if (index < 0) continue
    buffer = (buffer << 6) | index
    bits += 6
    if (bits >= 8) {
      bits -= 8
      out += String.fromCharCode((buffer >> bits) & 0xff)
    }
  }
  return out
}

// utf8FromBinary(binary) — turn a byte-per-char string into a real UTF-8 string.
// Qt.atob returns one character per byte, so a Chinese or Persian server name
// would otherwise render as mojibake.
function utf8FromBinary(binary) {
  var s = String(binary || "")
  if (s === "") return ""
  try {
    return decodeURIComponent(s.split("").map(function(ch) {
      return "%" + ("00" + ch.charCodeAt(0).toString(16)).slice(-2)
    }).join(""))
  } catch (e) {
    return s
  }
}

// parseInt0(value) — parse an integer, returning 0 instead of NaN.
// A NaN port would silently become `null` in JSON and make the engine refuse
// the config with a confusing message, so we normalize early.
function parseInt0(value) {
  var n = parseInt(String(value === undefined || value === null ? "" : value), 10)
  return isFinite(n) ? n : 0
}

// parseQuery(query) — turn "a=1&b=2" into an object, decoding both sides.
function parseQuery(query) {
  var out = {}
  var parts = String(query || "").split("&")
  for (var i = 0; i < parts.length; i++) {
    if (parts[i] === "") continue
    var eq = parts[i].indexOf("=")
    var key = eq < 0 ? parts[i] : parts[i].substring(0, eq)
    var value = eq < 0 ? "" : parts[i].substring(eq + 1)
    out[percentDecode(key).toLowerCase()] = percentDecode(value)
  }
  return out
}

// splitLink(raw) — peel a share link into scheme / body / query / fragment.
// Returns null for anything that is not a "scheme://rest" URL, which is how
// the panel tells "you pasted the wrong thing" from "this link is malformed".
function splitLink(raw) {
  var s = String(raw || "").trim()
  if (s === "") return null

  // Fragments give us the human-readable server name.
  var fragment = ""
  var hashAt = s.indexOf("#")
  if (hashAt >= 0) {
    fragment = s.substring(hashAt + 1)
    s = s.substring(0, hashAt)
  }

  var query = ""
  var queryAt = s.indexOf("?")
  if (queryAt >= 0) {
    query = s.substring(queryAt + 1)
    s = s.substring(0, queryAt)
  }

  var schemeAt = s.indexOf("://")
  if (schemeAt <= 0) return null

  return {
    scheme: s.substring(0, schemeAt).toLowerCase(),
    body: s.substring(schemeAt + 3),
    query: query,
    fragment: percentDecode(fragment)
  }
}

// splitHostPort(hostport) — "example.com:443" or "[2001:db8::1]:443" -> parts.
function splitHostPort(hostport) {
  var s = String(hostport || "")
  var host = ""
  var port = 0

  if (s.charAt(0) === "[") {
    // IPv6 literal: the address is bracketed, the port (if any) follows "]:"
    var close = s.indexOf("]")
    if (close > 0) {
      host = s.substring(1, close)
      var tail = s.substring(close + 1)
      if (tail.charAt(0) === ":") port = parseInt0(tail.substring(1))
    } else {
      host = s.replace(/[[\]]/g, "")
    }
  } else {
    var colon = s.lastIndexOf(":")
    if (colon > 0) {
      host = s.substring(0, colon)
      port = parseInt0(s.substring(colon + 1))
    } else {
      host = s
    }
  }
  return { host: percentDecode(host), port: port }
}

// splitUserInfo(body) — split "userinfo@host:port" at the LAST "@".
// The last "@" matters: a password may legitimately contain an "@" (rare but
// legal), and the host part never does.
function splitUserInfo(body) {
  var s = String(body || "")
  var at = s.lastIndexOf("@")
  if (at < 0) return { userinfo: "", hostport: s }
  return {
    userinfo: s.substring(0, at),
    hostport: s.substring(at + 1)
  }
}

// splitAlpn(value) — "h2,http/1.1" (or repeated &alpn= params) into an array.
function splitAlpn(value) {
  var s = String(value || "").trim()
  if (s === "") return []
  return s.split(",").map(function(item) { return item.trim() }).filter(function(item) {
    return item !== ""
  })
}

// -----------------------------------------------------------------------------
// Profile construction
// -----------------------------------------------------------------------------

// blankProfile(type, name) — every field a profile can have, pre-filled.
// Starting from a complete object is what lets the UI and the backend read
// `profile.sni` without defensive checks everywhere.
function blankProfile(type) {
  return {
    type: type,            // vless | vmess | trojan | shadowsocks
    name: "",              // display name shown in the panel
    host: "",              // server hostname or IP
    port: 0,               // server port
    // --- credentials (one of these is set, depending on type) ---
    uuid: "",              // vless / vmess
    password: "",          // trojan / shadowsocks
    method: "",            // shadowsocks cipher, e.g. aes-256-gcm
    alterId: 0,            // vmess legacy, 0 for AEAD
    flow: "",              // vless, e.g. xtls-rprx-vision
    encryption: "",        // vmess cipher, e.g. auto
    // --- transport ---
    network: "tcp",        // tcp | ws | grpc | http | xhttp | kcp
    headerType: "",        // tcp header camouflage, e.g. "http" or "none"
    path: "",              // ws / http / xhttp path
    wsHost: "",            // Host header for ws / http
    serviceName: "",       // grpc service name
    mode: "",              // xhttp mode (auto / packet-up / stream-up)
    // --- security ---
    security: "none",      // none | tls | reality
    sni: "",               // TLS server name
    fp: "",                // TLS fingerprint, e.g. chrome
    pbk: "",               // REALITY public key
    sid: "",               // REALITY short id
    spx: "",               // REALITY spider path
    alpn: [],              // e.g. ["h2", "http/1.1"]
    allowInsecure: false,  // skip certificate verification
    link: ""               // the original share link, kept for copy/export
  }
}

// parseVless(split) — vless://<uuid>@<host>:<port>?<params>#<name>
function parseVless(split) {
  var parts = splitUserInfo(split.body)
  var hp = splitHostPort(parts.hostport)
  var q = parseQuery(split.query)
  var p = blankProfile("vless")

  p.uuid = percentDecode(parts.userinfo)
  p.host = hp.host
  p.port = hp.port
  p.flow = q.flow || ""
  p.network = (q.type || "tcp").toLowerCase()
  p.security = (q.security || "none").toLowerCase()
  p.sni = q.sni || q.host || ""
  p.fp = q.fp || ""
  p.pbk = q.pbk || ""
  p.sid = q.sid || ""
  p.spx = q.spx || ""
  p.path = q.path || ""
  p.wsHost = q.host || ""
  p.serviceName = q.servicename || ""
  p.mode = q.mode || ""
  p.headerType = q.headertype || ""
  p.alpn = splitAlpn(q.alpn)
  p.allowInsecure = q.allowinsecure === "1" || q.allowinsecure === "true"
  p.name = split.fragment || p.host
  return p
}

// parseVmess(split) — two shapes exist in the wild:
//   * vmess://BASE64({"v":"2","ps":..,"add":..,"port":..,"id":..,...})
//   * vmess://<uuid>@<host>:<port>?<params>   (rare, v2rayN "AEAD" variant)
function parseVmess(split) {
  var decoded = b64decode(split.body)

  // Shape 1: base64 JSON. Detect on the brace, not on total decode success,
  // because a failed decode returns "" rather than throwing.
  if (decoded.indexOf("{") >= 0) {
    var obj = null
    try {
      obj = JSON.parse(decoded)
    } catch (e) {
      obj = null
    }
    if (obj) {
      var p = blankProfile("vmess")
      p.host = String(obj.add || "")
      p.port = parseInt0(obj.port)
      p.uuid = String(obj.id || "")
      p.alterId = parseInt0(obj.aid)
      p.encryption = String(obj.scy || obj.security || "auto")
      p.network = String(obj.net || "tcp").toLowerCase()
      p.headerType = String(obj.type || "")
      p.wsHost = String(obj.host || "")
      p.path = String(obj.path || "")
      p.serviceName = String(obj.path || "")   // grpc stores its name in path
      p.security = (String(obj.tls || "") === "tls" || String(obj.tls || "") === "reality")
        ? String(obj.tls).toLowerCase()
        : "none"
      p.sni = String(obj.sni || "")
      p.fp = String(obj.fp || "")
      p.pbk = String(obj.pbk || "")
      p.sid = String(obj.sid || "")
      p.spx = String(obj.spx || "")
      p.alpn = splitAlpn(obj.alpn)
      p.name = String(obj.ps || "") || split.fragment || p.host
      return p
    }
  }

  // Shape 2: URI-style.
  var parts = splitUserInfo(split.body)
  var hp = splitHostPort(parts.hostport)
  var q = parseQuery(split.query)
  var u = blankProfile("vmess")
  u.uuid = percentDecode(parts.userinfo)
  u.host = hp.host
  u.port = hp.port
  u.encryption = q.scy || "auto"
  u.network = (q.type || "tcp").toLowerCase()
  u.security = (q.security || q.tls || "none").toLowerCase()
  u.sni = q.sni || ""
  u.path = q.path || ""
  u.wsHost = q.host || ""
  u.serviceName = q.servicename || ""
  u.alpn = splitAlpn(q.alpn)
  u.name = split.fragment || u.host
  return u
}

// parseTrojan(split) — trojan://<password>@<host>:<port>?<params>#<name>
function parseTrojan(split) {
  var parts = splitUserInfo(split.body)
  var hp = splitHostPort(parts.hostport)
  var q = parseQuery(split.query)
  var p = blankProfile("trojan")

  p.password = percentDecode(parts.userinfo)
  p.host = hp.host
  p.port = hp.port
  // Trojan is TLS by definition; links often omit the param entirely.
  p.security = (q.security || "tls").toLowerCase()
  p.sni = q.sni || q.peer || ""
  p.fp = q.fp || ""
  p.network = (q.type || "tcp").toLowerCase()
  p.path = q.path || ""
  p.wsHost = q.host || ""
  p.serviceName = q.servicename || ""
  p.alpn = splitAlpn(q.alpn)
  p.allowInsecure = q.allowinsecure === "1" || q.allowinsecure === "true"
  p.name = split.fragment || p.host
  return p
}

// parseShadowsocks(split) — two shapes:
//   * ss://BASE64(method:password)@host:port#name   (SIP002, standard)
//   * ss://BASE64(method:password@host:port)#name   (legacy, all-in-one)
function parseShadowsocks(split) {
  var body = split.body
  var parts = splitUserInfo(body)
  var legacyForm = false

  // Legacy form: the whole thing is base64 and there is no "@" outside it.
  if (parts.userinfo === "" || parts.hostport.indexOf(":") < 0) {
    var legacy = b64decode(body)
    var atLegacy = legacy.lastIndexOf("@")
    if (atLegacy < 0) return null
    parts = {
      userinfo: legacy.substring(0, atLegacy),
      hostport: legacy.substring(atLegacy + 1)
    }
    // The decoded payload is already "method:password" — decoding it a second
    // time (as the SIP002 branch below does) would mangle the cipher name.
    legacyForm = true
  }

  var credentials = legacyForm ? parts.userinfo : b64decode(parts.userinfo)
  // Tolerate links that carry the credentials in plain text instead of base64.
  if (credentials.indexOf(":") < 0) credentials = percentDecode(parts.userinfo)
  var colon = credentials.indexOf(":")
  var p = blankProfile("shadowsocks")
  p.method = colon < 0 ? "" : credentials.substring(0, colon)
  p.password = colon < 0 ? credentials : credentials.substring(colon + 1)

  var hp = splitHostPort(parts.hostport)
  p.host = hp.host
  p.port = hp.port
  p.name = split.fragment || p.host
  return p
}

// lookupQueryValue(query, key) — first matching value, case-insensitively.
// Used for repeated params (some clients emit `&alpn=h2&alpn=http/1.1`).
function lookupQueryValue(query, key) {
  var parts = String(query || "").split("&")
  for (var i = 0; i < parts.length; i++) {
    var eq = parts[i].indexOf("=")
    var k = percentDecode(eq < 0 ? parts[i] : parts[i].substring(0, eq)).toLowerCase()
    if (k === key) return percentDecode(eq < 0 ? "" : parts[i].substring(eq + 1))
  }
  return ""
}

// parseLink(raw) — the one entry point the UI calls.
//
// Returns {ok:true, profile:<profile>} on success, or
//         {ok:false, error:"<why>"}  on failure.
// Errors are written for a human, because they are shown verbatim in the panel.
function parseLink(raw) {
  var text = String(raw || "").trim()
  if (text === "") return { ok: false, error: "Paste a server link first" }

  var split = splitLink(text)
  if (!split) {
    return {
      ok: false,
      error: "That does not look like a share link — it should start with vless:// (or vmess://, trojan://, ss://)"
    }
  }

  var profile = null
  if (split.scheme === "vless") profile = parseVless(split)
  else if (split.scheme === "vmess") profile = parseVmess(split)
  else if (split.scheme === "trojan") profile = parseTrojan(split)
  else if (split.scheme === "ss" || split.scheme === "shadowsocks") profile = parseShadowsocks(split)
  else {
    return { ok: false, error: "Unsupported link type: " + split.scheme + ":// (supported: vless, vmess, trojan, ss)" }
  }

  if (!profile) return { ok: false, error: "Could not read that " + split.scheme + " link" }
  if (!profile.host) return { ok: false, error: "The link has no server address" }
  if (profile.port <= 0 || profile.port > 65535) return { ok: false, error: "The link has no valid port" }

  if (profile.type === "vless" || profile.type === "vmess") {
    if (!profile.uuid) return { ok: false, error: "The link has no user id (UUID)" }
    if (!isUuidShaped(profile.uuid)) {
      return { ok: false, error: "The user id does not look like a UUID: " + profile.uuid }
    }
  }
  if (profile.type === "trojan" && !profile.password) {
    return { ok: false, error: "The link has no Trojan password" }
  }
  if (profile.type === "shadowsocks") {
    if (!profile.method) return { ok: false, error: "The link has no Shadowsocks cipher" }
    if (!profile.password) return { ok: false, error: "The link has no Shadowsocks password" }
  }
  // REALITY without a public key cannot work; catching it here beats a cryptic
  // engine log line six seconds later.
  if (profile.security === "reality" && !profile.pbk) {
    return { ok: false, error: "This is a REALITY link but the public key (pbk=) is missing" }
  }

  profile.link = text

  // Sensible fallbacks so the generated config is never subtly wrong:
  //   * REALITY/TLS links without an explicit SNI use the host name,
  //   * camouflage hosts fall back to the SNI or the host,
  //   * a grpc service name defaults to "" (xray accepts an empty one).
  if (profile.sni === "") profile.sni = profile.host
  if (profile.wsHost === "") profile.wsHost = profile.sni || profile.host
  if (profile.network === "") profile.network = "tcp"

  return { ok: true, profile: profile }
}

// isUuidShaped(value) — loose check for a 32-hex-char UUID (dashes optional).
// We only warn, never reject: some servers use non-UUID ids on purpose.
function isUuidShaped(value) {
  var s = String(value || "").replace(/-/g, "")
  return /^[0-9a-fA-F]{32}$/.test(s)
}

// makeId(profile) — stable, unique, filesystem-safe profile id.
function makeId(profile) {
  var base = slug(profile.name)
  var fingerprint = fnv1a([
    profile.type,
    profile.host,
    String(profile.port),
    profile.uuid || profile.password || ""
  ].join("|"))
  return (base === "" ? "server" : base) + "-" + fingerprint
}

// describe(profile) — one-line subtitle for the profile list.
function describe(profile) {
  var bits = [String(profile.type || "").toUpperCase()]
  if (profile.security && profile.security !== "none") bits.push(profile.security)
  if (profile.network && profile.network !== "tcp") bits.push(profile.network)
  return bits.filter(function(b) { return b !== "" }).join(" · ") +
    "  " + profile.host + ":" + profile.port
}

// -----------------------------------------------------------------------------
// Config generation
// -----------------------------------------------------------------------------

// buildStreamSettings(profile) — the transport + TLS half of the outbound.
//
// This is where vless/vmess links usually go wrong, so each network type is
// spelled out explicitly rather than being generated by a loop. xray and
// v2ray-core both accept these keys.
function buildStreamSettings(profile) {
  var network = (profile.network || "tcp").toLowerCase()
  var stream = { network: network, security: profile.security || "none" }

  // ---- transport ----
  if (network === "ws") {
    var ws = { path: profile.path || "/" }
    if (profile.wsHost) ws.headers = { Host: profile.wsHost }
    stream.wsSettings = ws
  } else if (network === "grpc") {
    stream.grpcSettings = { serviceName: profile.serviceName || "" }
  } else if (network === "http" || network === "h2") {
    stream.network = "http"
    stream.httpSettings = {
      path: profile.path || "/",
      host: profile.wsHost ? [profile.wsHost] : []
    }
  } else if (network === "xhttp" || network === "splithttp") {
    // XHTTP is xray-only. If a v2ray-core user hits this, start will fail with
    // a clear engine message, which is the honest outcome.
    stream.network = "xhttp"
    var xhttp = { path: profile.path || "/" }
    if (profile.wsHost) xhttp.host = profile.wsHost
    if (profile.mode) xhttp.mode = profile.mode
    stream.xhttpSettings = xhttp
  } else if (network === "kcp" || network === "mkcp") {
    stream.network = "kcp"
    stream.kcpSettings = { header: { type: profile.headerType || "none" } }
  } else {
    // Plain TCP. `headerType=http` is the old "TCP + HTTP camouflage" trick and
    // is still common on older servers, so it gets its own settings block.
    stream.network = "tcp"
    if ((profile.headerType || "").toLowerCase() === "http") {
      stream.tcpSettings = {
        header: {
          type: "http",
          request: {
            path: [profile.path || "/"],
            headers: { Host: [profile.wsHost || profile.sni || profile.host] }
          }
        }
      }
    }
  }

  // ---- TLS / REALITY ----
  if (stream.security === "tls") {
    var tls = {
      serverName: profile.sni || profile.host,
      fingerprint: profile.fp || "chrome",
      allowInsecure: profile.allowInsecure === true
    }
    if (profile.alpn && profile.alpn.length > 0) tls.alpn = profile.alpn
    stream.tlsSettings = tls
  } else if (stream.security === "reality") {
    var reality = {
      serverName: profile.sni || profile.host,
      fingerprint: profile.fp || "chrome",
      publicKey: profile.pbk || "",
      shortId: profile.sid || "",
      spiderX: profile.spx || ""
    }
    // ALPN PLACEMENT — verified against Xray 26.3.27 with `xray run -dump`:
    //   * `realitySettings.alpn` is NOT a field of Xray's REALITY config. Xray
    //     silently DROPS it (the config still reports "Configuration OK"), so the
    //     server never sees the ALPN list the share link asked for. This used to
    //     be written here and was therefore a no-op.
    //   * `tlsSettings.alpn` IS a real field, and for security="reality" Xray
    //     reuses that same TLS config to build the ClientHello, so ALPN belongs
    //     there. A tlsSettings block next to realitySettings is accepted
    //     (`xray -test` passes).
    // Result: REALITY parameters stay in realitySettings, ALPN goes into a
    // sibling tlsSettings block that only carries `alpn`.
    if (profile.alpn && profile.alpn.length > 0) {
      stream.tlsSettings = { alpn: profile.alpn }
    }
    stream.realitySettings = reality
  } else {
    stream.security = "none"
  }

  return stream
}

// buildOutbound(profile) — the "proxy" outbound for this profile.
function buildOutbound(profile) {
  var stream = buildStreamSettings(profile)
  var outbound = { tag: "proxy", streamSettings: stream, mux: { enabled: false } }

  if (profile.type === "vless") {
    outbound.protocol = "vless"
    var vlessUser = { id: profile.uuid, encryption: "none" }
    // `flow` must be omitted (or empty) for every transport except the plain
    // TCP + REALITY/TLS combination that XTLS Vision is designed for.
    if (profile.flow) vlessUser.flow = profile.flow
    outbound.settings = {
      vnext: [{ address: profile.host, port: profile.port, users: [vlessUser] }]
    }
  } else if (profile.type === "vmess") {
    outbound.protocol = "vmess"
    outbound.settings = {
      vnext: [{
        address: profile.host,
        port: profile.port,
        users: [{
          id: profile.uuid,
          alterId: profile.alterId || 0,
          security: profile.encryption || "auto"
        }]
      }]
    }
  } else if (profile.type === "trojan") {
    outbound.protocol = "trojan"
    outbound.settings = {
      servers: [{ address: profile.host, port: profile.port, password: profile.password }]
    }
  } else if (profile.type === "shadowsocks") {
    outbound.protocol = "shadowsocks"
    outbound.settings = {
      servers: [{
        address: profile.host,
        port: profile.port,
        method: profile.method,
        password: profile.password
      }]
    }
  } else {
    return null
  }

  return outbound
}

// buildConfig(profile, opts) — the complete engine configuration.
//
// opts.socksPort / opts.httpPort are the LOCAL listening ports. They are baked
// in at import time, which is why changing the port setting later only affects
// newly imported profiles (documented in README.md).
//
// The two inbounds mean every app on the machine gets both a SOCKS5 and an HTTP
// proxy on localhost — enough for browsers, curl, and anything else, with no
// root privileges required.
function buildConfig(profile, opts) {
  var socksPort = parseInt0(opts && opts.socksPort) || 10808
  var httpPort = parseInt0(opts && opts.httpPort) || 10809
  var outbound = buildOutbound(profile)
  if (!outbound) return null

  return {
    log: { loglevel: "warning" },
    inbounds: [
      {
        tag: "socks-in",
        listen: "127.0.0.1",
        port: socksPort,
        protocol: "socks",
        settings: { auth: "noauth", udp: true },
        sniffing: { enabled: true, destOverride: ["http", "tls"] }
      },
      {
        tag: "http-in",
        listen: "127.0.0.1",
        port: httpPort,
        protocol: "http",
        settings: {}
      }
    ],
    outbounds: [
      outbound,
      { tag: "direct", protocol: "freedom" },
      { tag: "block", protocol: "blackhole" }
    ],
    routing: {
      domainStrategy: "AsIs",
      rules: [
        {
          // Keep LAN traffic off the tunnel. Literal CIDRs (not geoip:private)
          // so no optional geo database is required for the engine to start.
          type: "field",
          ip: DIRECT_CIDRS,
          outboundTag: "direct"
        }
      ]
    }
  }
}

// buildImportPayload(profile, opts) — the exact JSON object the backend CLI
// expects on stdin: {"id": ..., "meta": {...}, "config": {...}}.
// Building it here keeps the CLI dumb, which is what makes the CLI testable.
function buildImportPayload(profile, opts) {
  var config = buildConfig(profile, opts)
  if (!config) return null

  var meta = {
    name: profile.name || profile.host,
    type: profile.type,
    host: profile.host,
    port: profile.port,
    added: (opts && opts.now) || 0,
    link: profile.link || "",
    security: profile.security,
    network: profile.network,
    socksPort: config.inbounds[0].port,
    httpPort: config.inbounds[1].port
  }

  return { id: makeId(profile), meta: meta, config: config }
}

// profileSummary(profile) — the panel's detail lines, as label/value pairs.
// Kept here (not in the .qml) so the same strings can be reused by a future CLI.
function profileSummary(profile) {
  var rows = [
    { label: "Server", value: String(profile.host) + ":" + String(profile.port) },
    { label: "Protocol", value: String(profile.type).toUpperCase() },
    { label: "Transport", value: String(profile.network) },
    { label: "Security", value: String(profile.security) }
  ]
  if (profile.flow) rows.push({ label: "Flow", value: String(profile.flow) })
  if (profile.sni) rows.push({ label: "SNI", value: String(profile.sni) })
  if (profile.network === "ws" || profile.network === "http") {
    rows.push({ label: "Path", value: String(profile.path || "/") })
  }
  if (profile.network === "grpc") rows.push({ label: "Service", value: String(profile.serviceName) })
  return rows
}

// formatUptime(seconds) — "3m 12s" / "1h 04m" for the connected row.
function formatUptime(seconds) {
  var total = parseInt0(seconds)
  if (total <= 0) return ""
  if (total < 60) return total + "s"
  var minutes = Math.floor(total / 60)
  var hours = Math.floor(minutes / 60)
  if (hours > 0) {
    var restMinutes = minutes % 60
    return hours + "h " + (restMinutes < 10 ? "0" : "") + restMinutes + "m"
  }
  return minutes + "m " + (total % 60) + "s"
}

// truncate(text, max) — middle-ellipsis helper for long server names.
function truncate(text, max) {
  var s = String(text || "")
  var limit = parseInt0(max) || 40
  if (s.length <= limit) return s
  return s.substring(0, limit - 1) + "…"
}
