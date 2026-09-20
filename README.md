# v2ray Client — an Omarchy bar plugin

Paste a share link, get a working tunnel.

This plugin puts a **shield icon** in your Omarchy bar. You paste a server link
(`vless://`, `vmess://`, `trojan://` or `ss://`), press **Add**, and click the
server — a tunnel comes up. Everything runs as your user: no root, no password
prompts, and nothing in `/etc` is touched.

---

## Add it in three steps

### Step 1 — make sure a v2ray core is installed

The plugin needs one of two programs on your `PATH`. Check which you have:

```bash
command -v xray || command -v v2ray
```

* **Nothing printed?** Install the easy one:

  ```bash
  omarchy pkg add v2ray
  ```

* **Something printed?** You are done — go to step 2.

> **Most modern links need `xray`, which is not in Arch's official repos.**
> `extra/v2ray` (5.x) cannot speak REALITY or XHTTP, and those are what most
> current share links use. It does not *reject* them either — it loads the
> config, says "Configuration OK", and then connects with no REALITY handshake
> at all, so the failure looks like a bad link. Searching Arch for "xray" only
> finds `python-aws-xray-sdk`, Amazon's tracing SDK, which is unrelated. The
> core you want lives in the AUR:
>
> ```bash
> omarchy pkg aur add xray      # or: yay -S xray
> ```
>
> With `xray` on `PATH` the plugin detects and prefers it automatically, and
> every profile you already imported keeps working unchanged.

If no engine is found the plugin still appears — with a **!** badge on the icon
and an **Install v2ray** button in the popup. That button opens a terminal,
because pacman has to ask for your password and a bar process must never prompt
for one.

### Step 2 — add the plugin

```bash
omarchy plugin add https://github.com/justhosi/v2ray-plugin --enable
```

It will:

1. warn you that plugins run as unsandboxed code inside your shell — only add
   repos you trust — and ask you to confirm,
2. clone the repo and validate it against the plugin manifest schema,
3. install it into `~/.config/omarchy/plugins/community.v2ray-client`
   (the folder name comes from the `id` in `manifest.json`, not from the repo
   name, so it is always this path),
4. ask whether to enable it now, and which bar section to use it in.

Answer **yes**, then choose **right**. There is no build step and nothing to
compile — the QML and the shell script are the whole program.

### Step 3 — look at your bar

A **shield** appears in the bar section you picked. It has three looks:

| look | meaning |
|---|---|
| dim shield with a slash | the tunnel is off |
| bright shield with a check mark | the tunnel is on |
| pulsing shield | starting or stopping right now |
| shield with a **!** badge | no v2ray core on `PATH` — see step 1 |

If nothing appears, reload the shell:

```bash
omarchy restart shell
```

### If you would rather install by hand

```bash
git clone https://github.com/justhosi/v2ray-plugin
cp -r v2ray-plugin ~/.config/omarchy/plugins/community.v2ray-client
omarchy plugin validate ~/.config/omarchy/plugins/community.v2ray-client
omarchy plugin enable community.v2ray-client right
```

Either way, saving anything under `~/.config/omarchy/plugins/` hot-reloads the
plugin. If the icon stubbornly refuses to appear:

```bash
omarchy-shell shell rescanPlugins
omarchy restart shell
```

### Updating it later

```bash
omarchy plugin update community.v2ray-client
```

---

## Use it

### Import your first server

1. **Left-click** the shield. The popup opens with the cursor already in the
   text field.
2. **Paste** your share link and press **Enter** (or click **Add**).
3. The server appears under **SERVERS**. If the link was malformed you get a red
   line at the top telling you what was wrong, and your text stays in the field
   so you can fix it.
4. **Click the row** to connect. The row gets an accent dot, the subtitle reads
   "Connected", and the bar shield fills in.

### Then point something at it

Connection alone does not move anyone's traffic — see the next section.

The engine only listens on two local ports:

```
SOCKS5   127.0.0.1:10808
HTTP     127.0.0.1:10809
```

So the quickest proof that the tunnel works is a terminal:

```bash
# Direct: shows your real IP
curl -s https://api.ipify.org; echo
# Through the tunnel: shows the server's IP
curl -s --proxy socks5h://127.0.0.1:10808 https://api.ipify.org; echo
```

Two different addresses means the tunnel is fine. To make an app use it, either
set `127.0.0.1:10808` as its SOCKS5 proxy, or start it from a terminal that has:

```bash
export all_proxy=socks5h://127.0.0.1:10808
```

The popup has a **copy** button for that exact line, and another for the proxy
address, so you never have to retype them.

### Every interaction

| Where | What it does |
|---|---|
| **Left click** the icon | open the popup |
| **Right click** the icon | connect / disconnect (the "VPN switch") |
| **Middle click** the icon | re-read state |
| **Left click** a server row | connect it (or disconnect it, if it is the active one) |
| **Right click** a server row | copy that server's original share link |
| **Speedometer** row button | measure real latency through that server |
| **Copy** row button | copy the share link |
| **Bin** row button | delete — needs a second click to confirm |
| **Paste + Enter** in the field | import the link |

Every row button answers a click: it darkens and shrinks as you press, shows a
**check mark** when the action lands, and **pulses** while a slow action (a
latency probe) is running.

### Keyboard

| Key | Action |
|---|---|
| `Tab` | leave the text field, hand the keyboard to the list |
| `Up` / `Down` (or `j` / `k`) | move the row cursor |
| `Enter` | connect / disconnect the highlighted row |
| `Delete` | arm delete for the highlighted row (press twice) |
| `t` | toggle the connection |
| `r` | refresh |
| `p` | ping the highlighted server |
| `c` | copy the highlighted server's link |
| `Esc` | close |

### Reading the popup

* A **red line** reports the last failure, capped at three lines. The **copy**
  button beside it hands over the untruncated text for a bug report; the **✕**
  dismisses it. It is also cleared every time the popup opens.
* A **dim line** confirms things that worked — "Copied to clipboard",
  "Added <server>". It fades by itself.
* The **LOCAL PROXY** section, visible while connected, spells out the ports and
  the `all_proxy` line.

### What "connect" actually does

The engine binds the two local proxies above and nothing else.

**This proxy is not system-wide.** "Connected" means the engine is up and its
local port is open. It does **not** mean your traffic is going through it. Only
apps that were told to use `127.0.0.1:10808` are tunnelled, so a browser with no
proxy configured happily keeps loading pages *and* keeps showing your real IP —
the single most common "it isn't working" report. The two `curl` commands above
tell you which of the two you are looking at.

If the "direct" command also shows the server's IP, then something else on your
system (tun2socks, another VPN, a proxy environment variable) is already routing
everything, and this plugin is redundant.

There is deliberately **no TUN mode**: hijacking all system traffic needs root,
and a bar widget must never prompt for a password. That is a real limitation,
not an oversight — see "Extending" below for the supported way to add it.

---

## Supported links

| Scheme | Notes |
|---|---|
| `vless://` | `tcp`, `ws`, `grpc`, `http`, `xhttp`, `kcp` transports; `none`/`tls`/`reality` security; `flow=xtls-rprx-vision` |
| `vmess://` | base64-JSON links and the rarer URI form; `alterId`, `scy` |
| `trojan://` | TLS by default when the link omits `security=` |
| `ss://` | both SIP002 (`ss://b64(method:pass)@host:port`) and the legacy all-in-one form |

Malformed links are rejected in the panel with a readable reason ("This is a
REALITY link but the public key (pbk=) is missing") instead of failing later
inside the engine.

---

## Where your data lives

```
~/.config/omarchy-v2ray/
├── profiles/
│   ├── <id>.meta.json      # name, host, ports, original link   (0600)
│   └── <id>.config.json    # the real engine config w/ your UUID (0600)
└── state/
    ├── engine.log          # engine output — read this first when stuck
    ├── engine.pid
    ├── active.id
    ├── started.epoch
    └── autostart.id        # profile to connect when the shell starts
```

Profiles are written with `umask 077`, because the config file contains your
UUID — treat that directory like a password store. The popup's footer has a
button that opens it in your file manager.

### The backend CLI

The plugin is a thin UI over `bin/omarchy-v2ray`, which you can run yourself.
Every subcommand prints JSON (except `log`):

```bash
bin/omarchy-v2ray status              # engine + connection state
bin/omarchy-v2ray list                # imported profiles
bin/omarchy-v2ray start <id>
bin/omarchy-v2ray stop
bin/omarchy-v2ray toggle
bin/omarchy-v2ray ping <id>           # real latency, via a throwaway engine
bin/omarchy-v2ray link <id>           # print the share link
bin/omarchy-v2ray log 50
bin/omarchy-v2ray autostart <id>|off
bin/omarchy-v2ray remove <id>
bin/omarchy-v2ray import "$(cat payload.json)"
```

This is the file to read when something breaks: it is plain bash, it needs no
display, and it explains itself.

---

## Settings

Edit the widget's entry in `~/.config/omarchy/shell.json` (or use Omarchy's
plugin settings UI):

| Key | Default | Meaning |
|---|---|---|
| `refreshIntervalSec` | `30` | how often the icon re-checks engine state |
| `socksPort` | `10808` | local SOCKS port for **newly imported** profiles |
| `httpPort` | `10809` | local HTTP port for **newly imported** profiles |

> Ports are baked into a profile's config at import time (that is what makes
> `start <id>` work from a bare terminal with no plugin involved). To move an
> existing profile to new ports, re-import its link after changing the setting.

---

## Troubleshooting

**The icon has a "!" badge.** No `xray`/`v2ray` on `PATH`. Use the install
button in the popup, or `omarchy pkg add v2ray` in a terminal.

**There is no icon at all in the bar.** Check the shell journal — a QML error
in the widget makes the whole widget fail to load:

```bash
journalctl --user -t omarchy-shell -n 200 | grep -i v2ray
```

**"This server needs REALITY / XHTTP — only the xray core supports it."**
This is the big one, and the reason it looks like nothing is wrong at first.

`v2ray-core` (the official `extra/v2ray` package) does **not** implement REALITY
or the XHTTP transport. Worse, it does not *reject* them either: `security` is
just a string to its config parser, so a REALITY link produces a config that
loads with "Configuration OK", and then the engine dials the server with **no
REALITY handshake at all**. The server stays silent and every layer above
reports the only thing it can see — "bad UUID / wrong server / blocked port" —
for a link that works perfectly in your phone client.

REALITY and XHTTP live in **xray**, which is in the AUR:

```bash
omarchy pkg aur add xray     # or: yay -S xray
```

The plugin then prefers xray automatically (`engine_bin` picks it first) and
your existing profiles keep working unchanged. Every other link type —
VLESS+TCP/TLS, VMess, Trojan, Shadowsocks — is fine on plain v2ray.

**"Engine starting…" never becomes "Connected".** Read the engine log from the
popup's error line, or directly:

```bash
bin/omarchy-v2ray log 40
```

A REALITY server on the v2ray core cannot work at all (see the REALITY entry
above). On xray, a stale `pbk=` public key or a mismatched `sni=` is the usual
cause.

**Connecting works but nothing loads.** Check you actually pointed the app at
the proxy (`127.0.0.1:10808`) — the tunnel is not system-wide by design. See
"What connect actually does" above for the two `curl` commands that tell you
whether the app or the tunnel is at fault.

**The bar says ON, pages load, but my IP is still my own.** This is the same
thing, seen from the other end: the pages are loading *directly*, not through
the tunnel, because the browser was never pointed at `127.0.0.1:10808`. Nothing
is broken. Set the proxy in the app, or `export all_proxy=socks5h://127.0.0.1:10808`
before launching it.

**I clicked a button and nothing seemed to happen.** Every row action now
answers visibly: the button shrinks and darkens the moment the mouse goes down,
a **check mark** replaces the glyph when the action lands, and a slow action (a
latency probe) **pulses** and refuses a second click while it runs. Copying also
prints a short "Copied to clipboard" line under the server list, which expires
by itself. Before this, a copy was completely silent and a ping only showed up
as small grey text in the row.

**A red error line would not go away.** It is now cleared every time the popup
opens, and the **✕** button at the right end of the line dismisses it
immediately. It used to survive until the *next* action, so it could sit there
for a whole session.

**The report says "authentication SUCCEEDED" yet the request still failed.**
Read the `handshake time :` line in `bin/omarchy-v2ray debug <profile-id>`. It
measures from the moment the engine accepted the request to the moment it
forwarded it into the tunnel. On a slow uplink that can eat most of the probe
deadline, so raise it and try again:

```bash
OMARCHY_V2RAY_PING_TIMEOUT=30 ./bin/omarchy-v2ray ping <profile-id>
OMARCHY_V2RAY_DEBUG_TIMEOUT=30 ./bin/omarchy-v2ray debug <profile-id>
```

**A REALITY link's `alpn` seemed to be ignored.** It used to be written into
`realitySettings`, and Xray **silently drops** that key — the config still says
"Configuration OK", so nothing ever complained. ALPN is now written into a
sibling `tlsSettings` block (verified with `xray run -dump`), which Xray does
honour. Profiles imported **before** this fix keep the old config, so re-import
the link (or re-importing is only needed if the link carries `alpn=`).

**🔴 The error line in the popup is a wall of text.** A failed latency probe
appends the engine's own debug lines, which are hundreds of characters each. The
line is therefore clamped to three lines, and the **copy** button beside it hands
over the full text for a bug report.

**`ping` says "the tunnel did not answer".** The link parses, the probe engine
starts, but no traffic comes back: revoked UUID, wrong `pbk` public key, an
unreachable server, or a blocked port. The probe deliberately checks the HTTP
status, so a hung proxy is never reported as a fast one.

A *slow* link and a *dead* one look identical here, because the probe gives up
after 8 seconds. If your phone connects to the same link but takes a while, run
`debug` instead: its `handshake:` line says whether the server accepted your
credentials. If it says authentication succeeded, the tunnel is fine and the
probe simply ran out of time — raise the deadline for that run with:

```bash
OMARCHY_V2RAY_PING_TIMEOUT=20 bin/omarchy-v2ray ping <profile-id>
```

`OMARCHY_V2RAY_DEBUG_TIMEOUT=20` does the same for `debug`. Both are
placeholders for the number of seconds; `OMARCHY_V2RAY_SOCKS_PORT`,
`OMARCHY_V2RAY_PING_URL` and `OMARCHY_V2RAY_CLOCK_URL` are the other tunables.

**Anything else, or you want the engine's exact words.** Run the diagnoser:

```bash
bin/omarchy-v2ray debug <profile-id> | jq -r .report
```

`<profile-id>` is a placeholder — get yours from `bin/omarchy-v2ray list`.
It re-runs the same config on spare ports with `loglevel: debug`, makes one real
request through the tunnel, and prints a report ending in the engine's own log.
Nothing is modified and your live tunnel, if any, is left alone.

The report also measures the two things that break REALITY without ever
mentioning REALITY:

* **clock skew** — the difference between your clock and a directly-reached TLS
  server. REALITY timestamps every handshake, so a server with `maxTimeDiff` set
  rejects a client whose clock has drifted, and the client only ever sees
  "received real certificate".
* **certificate identity** — what the server IP presents for your `sni` versus
  what the real domain presents. The two are compared by *signing organisation*,
  not by the full certificate text: different datacenters legitimately sign with
  different issuer names (`CN=WE2` vs `CN=WR2`, both "Google Trust Services"), so
  comparing the whole string reported interception on healthy connections. A
  genuine mismatch names two different organisations.
* **handshake evidence** — whether the engine's own log shows that REALITY
  *accepted* us (`XtlsFilterTls found tls client hello` / `tunneling request
  to`) or *rejected* us (`received real certificate`). This separates "the
  credentials are wrong" from "the credentials were fine and the reply was slow
  or blocked" — the distinction the certificate check alone cannot make.

`"received real certificate (potential MITM or redirection)"` is the one engine
message that cannot be read on its own: it covers a wrong `pbk`/`sid`, clock
drift, a client/server version gap, *and* genuine interception. The two probes
above are what separate those cases.

Two bugs this command was built to catch, both of which produced a *completely
misleading* "bad UUID, wrong server, or blocked port":

1. `mktemp` hands back a file with **no `.json` extension**, and xray's
   `-format auto` guesses the format from the extension — so the probe engine
   died with "Failed to get format" before it bound a single port.
2. The failure message had no way to tell "the engine never came up" apart from
   "the tunnel was up but silent", so it blamed the server for both.

**The bar looks broken after an edit.** `omarchy restart shell`, then
`omarchy refresh shell` if it persists (the latter resets layout, not your
plugin).

---

## Files

| file | what it is |
|---|---|
| `Panel.qml` | the bar button and the popup; draws only, runs nothing |
| `Service.qml` | all state and every process spawn |
| `V2rayShield.qml` | the hand-drawn bar icon (three states + a warning badge) |
| `V2rayActionButton.qml` | the small row buttons, with press/busy/confirmed feedback |
| `Model.js` | share-link parsing and engine-config building |
| `bin/omarchy-v2ray` | the backend CLI; every subcommand answers with JSON |
| `tests/test-backend.sh` | the offline test suite |

## Extending it

* **TUN mode / system-wide VPN.** Add a subcommand to the backend script that
  writes an engine `tun` inbound and re-executes it through `pkexec`, then a
  button in the popup that calls it. Keep the privileged part in its own
  script: the shell process must never try to prompt for a password.
* **Subscriptions.** A `refresh-subscription <url>` subcommand that fetches,
  splits, and imports every link would slot in without touching the QML — the
  parser already handles all four schemes.
* **Auto-reconnect.** The engine is already detached, so a small loop in the
  backend script can restart it when `status` reports it dead.

## Tests

The failure paths worth testing here all need a *misbehaving* server — one that
refuses the REALITY handshake, or accepts it and then never answers — which no
test machine has on demand. So `tests/test-backend.sh` swaps three external
programs for doubles placed first on `PATH`:

| double | pretends to be |
|---|---|
| `xray` | an engine that prints a scripted log and then lingers |
| `ss` | a machine with the proxy port open (no sockets are opened at all) |
| `curl` | a proxy that accepted the connection and never replied |

Everything else is the real code, including all of `bin/omarchy-v2ray`. The suite
runs in a scratch directory (`OMARCHY_V2RAY_HOME`), so it never touches your
profiles or your tunnel.

```bash
./tests/test-backend.sh
```

It covers the signer comparison (`WE2` vs `WR2` must *not* be an alarm), the two
handshake verdicts, the collapsed error text, and the `set -u` trap that once made
`debug` abort with `sni: unbound variable`.

---

## Uninstall

```bash
omarchy plugin disable community.v2ray-client
omarchy plugin remove community.v2ray-client --yes
rm -rf ~/.config/omarchy-v2ray      # your profiles and links — delete only if sure
```

## License

MIT.
