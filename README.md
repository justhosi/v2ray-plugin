# v2ray Client — an Omarchy bar plugin

Paste a share link, get a working tunnel.

This plugin puts a **shield icon** in your Omarchy bar. You paste a server link
(`vless://`, `vmess://`, `trojan://` or `ss://`), press **Add**, and click the
server — a tunnel comes up.

That tunnel comes in two shapes. **Proxy mode** is the default: the engine opens
a SOCKS and an HTTP proxy on loopback, and only the apps you point at them are
tunnelled. It runs entirely as your user — no root, no password prompt, and
nothing written in `/etc`. **TUN mode** is the second switch in the popup: it
routes every packet on the machine and points DNS into the tunnel. That needs
`CAP_NET_ADMIN`, so it is done by a separate privileged helper, installed once,
that only ever runs through a polkit prompt. The bar itself never holds root;
see "What TUN mode actually does" below.

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
compile — the QML and the shell script are the whole program. Proxy mode is
complete at this point; TUN mode has one more, one-time install (see below).

### Step 3 — look at your bar

A **shield** appears in the bar section you picked. It has these looks:

| look | meaning |
|---|---|
| dim shield with a slash | the tunnel is off |
| bright shield with a check mark | the tunnel is on, as a local proxy |
| bright shield with a check mark **and a dot** underneath | the tunnel is on, in TUN mode — the whole machine is routed |
| pulsing shield | starting or stopping right now |
| shield with a **!** badge | no v2ray core on `PATH` — see step 1 |

Both kinds of tunnel are "on", so the check mark keeps that one meaning and the
dot is what tells them apart. At bar size the difference is deliberately quiet:
it is the *mode*, not another state.

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

### Only for TUN mode: install the privileged helper

TUN mode is the one part of this plugin that needs root, so it is split in two:
the bar and `bin/omarchy-v2ray` decide *what* to do, and a small root-owned
helper at `/usr/local/lib/omarchy-v2ray/omarchy-v2ray-tun` does the privileged
part. Install it once — from the popup (press the TUN switch; the backend refuses
without a prompt and offers an **Install the TUN helper** row), or from a
terminal:

```bash
bin/omarchy-v2ray install-tun
```

It opens a visible terminal and runs one `pkexec` command, so you can watch the
install happen and are asked for your password once. Nothing else in the plugin
prompts: proxy mode never asks, and TUN asks only when you start it. Stopping
needs no password — the engine runs as you, so your own session can stop it, and
the still-running supervisor finishes the part that needs root.

**Why it is installed outside the plugin tree.** `~/.config/omarchy/plugins/`
belongs to you, and any process running as you can rewrite it. A helper that
`pkexec` executed from there would be replaceable, and one password prompt later
the replacement would run as root — silently so, once a polkit rule named that
path. The executed copy therefore lives in a root-owned directory, and both
halves verify its owner and mode before anything privileged happens. That is a
security property, not an implementation detail; do not "helpfully" symlink it
back into the plugin directory.

The installed file is a copy. Updating the plugin does not update it, so run
`install-tun` again after an update, and remove it yourself when you remove the
plugin (see [Uninstall](#uninstall)).

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

### Then point an app at it

**This is the step people skip, and then think the plugin is broken.** In
**proxy mode**, connecting only *opens* the tunnel — it does not reroute
anything by itself. Until an app is told to use it, that app keeps talking to the
internet directly, on your real IP. In **TUN mode** this whole section is
unnecessary: every app is already routed, though the two ports below stay bound
for apps that prefer an explicit proxy.

The engine listens on two doors:

| door | address | use it for |
|---|---|---|
| **SOCKS5** | `127.0.0.1:10808` | browsers and most things — it also carries DNS, so lookups do not leak |
| **HTTP** | `127.0.0.1:10809` | the occasional app that only understands an "HTTP proxy" |

Prefer the SOCKS5 one. The popup has a **copy** button for the SOCKS5
address and another for the ready-made `all_proxy` line, so you never have to
retype either.

#### Prove it in a terminal first

```bash
# Direct: prints your real IP
curl -s https://api.ipify.org; echo
# Through the tunnel: prints the server's IP
curl -s --proxy socks5h://127.0.0.1:10808 https://api.ipify.org; echo
```

Two **different** addresses means the tunnel is healthy and the problem — if any
— is in the app's settings, not here. In TUN mode they are the *same* address:
the direct `curl` is inside the tunnel too, and there is nothing left to point.

#### Worked example: Brave

Brave is Chromium underneath, so it takes a `--proxy-server` switch. Three ways,
easiest first.

**1. Try it right now (nothing is saved).** Close Brave completely, then:

```bash
brave --proxy-server="socks5://127.0.0.1:10808"
```

**2. Check it worked.** In that Brave window, open `https://api.ipify.org`. It
must show the **server's** address, not yours. You can also open
`brave://net-internals/#proxy` and read the "Effective proxy settings" line —
it should name `socks5://127.0.0.1:10808`.

**3. Make it permanent.** Give your user a private copy of Brave's launcher so a
system update cannot undo the edit:

```bash
mkdir -p ~/.local/share/applications
cp /usr/share/applications/brave-browser.desktop ~/.local/share/applications/
```

Now open that file in a text editor, find the first line starting with `Exec=`,
and add the switch to it:

```ini
Exec=brave %U                                                      # before
Exec=brave --proxy-server="socks5://127.0.0.1:10808" %U             # after
```

(That is the real first `Exec=` line in Brave's launcher. Leave the other
`Exec=` lines — the incognito and new-window ones — alone unless you want those
tunnelled too.)

Save, and start Brave from the launcher as usual. To undo, delete the copy:

```bash
rm ~/.local/share/applications/brave-browser.desktop
```

> **Leave the flag off and Brave is untouched.** The switch only exists in that
> one launcher, so your normal Brave still uses your normal connection — handy
> for keeping a "tunnelled" and a "direct" Brave side by side.

#### What about every other app?

* **A GUI app with its own proxy setting** (most chat apps, some editors):
  paste `127.0.0.1` / `10808` and pick **SOCKS5**.
* **A terminal program** (`curl`, `git`, `wget`, `pip`…): start it with the
  environment variable, which is the line the popup's copy button gives you:

  ```bash
  export all_proxy=socks5h://127.0.0.1:10808
  ```

  The `h` in `socks5h` matters: it sends hostnames to the proxy instead of
  resolving them locally, so your DNS lookups stay inside the tunnel too.

* **Every app you start after logging in**, with no root and no code — a
  systemd user environment file:

  ```bash
  mkdir -p ~/.config/environment.d
  printf 'all_proxy=socks5h://127.0.0.1:10808\n' > ~/.config/environment.d/v2ray.conf
  ```

  Log out and back in for it to take effect. This covers most apps that read
  proxy environment variables, but **not** all of them — apps that ignore the
  environment, and anything already running, will still go direct. It also
  applies whether or not the tunnel is up, so a stopped engine means those apps
  simply fail to connect. Delete the file to undo it.

### TUN mode, and why it is not part of the bar process

Routing all system traffic needs a tun device, and a tun device needs
`CAP_NET_ADMIN` — root's authority. A bar widget must never hold that: the shell
runs unsandboxed code, reloads on every file save, and must not be able to
prompt for a password or quietly acquire a capability. So the privileged part is
a separate file, `bin/omarchy-v2ray-tun`, installed outside the plugin tree by
`install-tun` and executed only through `pkexec`. The bar launches it, forgets
about it, and polls the state file it writes.

That split is why TUN asks for authorisation once per start, while proxy mode
never asks at all. Stopping is free: the engine runs as **you**, with only
`CAP_NET_ADMIN` added, so your own session can signal it, and the root supervisor
that is still running does the part that needs root — restoring DNS and removing
the routes — before it exits. polkit's keep-alive shortens a rapid off/on into a
single prompt, but it is still an authorisation, not a switch the bar can flip
by itself. "What TUN mode actually does" below covers the mechanics;
[Troubleshooting](#troubleshooting) covers a prompt that never appears.

### Every interaction

| Where | What it does |
|---|---|
| **Left click** the icon | open the popup |
| **Right click** the icon | connect / disconnect (the "VPN switch"); while TUN is on, this stops TUN — no prompt |
| **Middle click** the icon | re-read state |
| **Left click** a server row | connect it (or disconnect it, if it is the active one) |
| **Right click** a server row | copy that server's original share link |
| **TUN (SYSTEM-WIDE)** switch | turn the system-wide tunnel on (one polkit prompt) or off (no prompt) |
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
| `u` | turn TUN mode on or off |
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
  the `all_proxy` line. In TUN mode it says outright that nothing has to be
  pointed at them — they stay bound for apps that prefer an explicit proxy.
* The **TUN (SYSTEM-WIDE)** section, with its switch and one line of state. The
  line is the backend's own answer: "waiting for authorisation" while polkit is
  up, the interface name while the tunnel is live, or the reason it cannot start
  here (no xray). When the privileged helper is missing, a refused click turns
  the section into an **Install the TUN helper** row instead of a password
  prompt that cannot work. While TUN is live the bar shield gains a small dot
  under its check mark: both modes are "on", but only one reroutes the machine.

### What "connect" actually does

In **proxy mode** the engine binds the two local proxies and nothing else. It
never touches your routing table, your DNS, or any other app's traffic.
"Connected" therefore means *the tunnel is open*, not *your traffic is inside
it* — and that gap is the single most common "it isn't working" report, which is
why the section above exists.

One useful consequence of that design: in proxy mode nothing else on your
machine can break because of this plugin. Stop the engine and the only thing
that changes is that apps pointed at `127.0.0.1:10808` lose their tunnel;
everything else carries on as before. TUN mode deliberately gives that up — it
changes the whole machine, and has its own recovery story below.

If your *direct* `curl` (the one without `--proxy`) already reports the server's
IP while the shield is on, then either something else is routing everything —
tun2socks, another VPN, your router's own v2ray, a proxy environment variable —
or TUN mode is on, where that is the expected result, not a sign of redundancy.

#### What TUN mode actually does

The switch stops the local proxy engine first. That is not tidiness: the TUN
config is the same profile with a tun inbound added, so it still binds the
profile's SOCKS and HTTP ports, and two engines cannot own 10808/10809. Without
the handover the privileged one dies inside its readiness window, and the error
it reports is about the engine exiting, not about the port collision that
actually caused it.

The helper then rebuilds the profile's config — server, transport and REALITY
parameters untouched — with a `tun` inbound, and runs the engine as **you**, with
only `CAP_NET_ADMIN` added, never as root. Routing is the helper's job, not the
engine's: this xray build accepts the tun inbound's `gateway`,
`autoSystemRoutingTable` and `autoOutboundsInterface` and silently ignores them
on Linux, so the device alone would come up with no address and no routes. The
helper therefore gives the interface its address (`10.66.0.1/16`, plus
`fc00:66::1/64` when the host has an IPv6 default), brings the link up, and
installs two pairs of `/1` routes — `0.0.0.0/1` and `128.0.0.0/1`, plus `::/1`
and `8000::/1` for IPv6. Together they cover the whole address space and are more
specific than the real default route, so the kernel prefers them without the
helper replacing — and later having to guess at — your default route. Before the
`/1`s exist it resolves the proxy outbound's address once — while your system's
own resolvers still answer, before DNS is moved into the tunnel — and rewrites it
to that literal (the SNI/serverName is untouched, so only the dial target
changes). That one literal is then pinned to the physical gateway as a `/32` (or
`/128`) exemption, so the route names exactly what xray will dial. Direct traffic
is kept out of the tun the other way round: see the next paragraph.

Direct traffic stays off the tun by binding its socket, not by adding routes. The
`direct` (freedom) outbound — which answers LAN, printer and any traffic the
profile refuses to tunnel — used to have its private CIDRs pinned as routes,
which could override a route that mattered (a VPN split tunnel, a bridge, a
container network) and made teardown delete a route the helper never created. The
helper now sets `streamSettings.sockopt.interface` on that outbound to the
physical uplink, so a direct dial opens its socket on the link and never re-enters
the tun, and no routing-table entry is touched at all. That is the price of not
touching routes: a bound socket's route lookup is restricted to its device, so on
a split-interface host an IPv6 direct dial bound to the IPv4 uplink fails, and a
direct dial the table would have sent via another device — a second NIC, a VPN
interface, a container bridge — is forced onto the default uplink and usually
fails there too. An IP-literal server still gets its `/32`/`/128` exemption
through the physical gateway.

DNS is moved into the tunnel as soon as the interface exists. On a
systemd-resolved machine the helper attaches `1.1.1.1` and `9.9.9.9` to the tun
link, claims `~.` for every domain and sets the link as the default route
(`resolvectl default-route … yes`), so an unlisted name cannot still be resolved
through the physical link; elsewhere it rewrites `/etc/resolv.conf` from a backup
it took first. Both are undone on the way out.

`up` does not exit when the engine starts: it supervises. On every exit path —
clean engine exit, crash, or a signal during the readiness window — it restores
DNS (including the `resolvectl default-route` it set), removes the four `/1`
routes and the server-exemption prefixes it recorded in
`/run/omarchy-v2ray-tun/routes`, and deletes its state file, so a dead engine
cannot leave the machine pointed at a tun device that no longer exists.
`tun-down` does the same work explicitly and is safe when nothing is running.

Stopping is prompt-free and escalates rather than guessing. `tun-down` signals
the engine you own, waits ~5 s for the supervisor to clean up, and — only if the
engine is still there because it ignored the signal — sends `SIGKILL` from your
own session and waits ~3 s more; the privileged helper's password prompt is
reached only if that still has not worked, worst case ~8 s after you asked to
stop.

"Connected" in TUN mode is evidence rather than optimism: the helper writes its
state file only after the interface exists, the routes through it are installed
and verified — a probe address must come back through the tun and every server
address must not — and the profile's SOCKS port is listening. The probe is not a
fixed `1.1.1.1`: it walks `1.1.1.1`, then `8.8.8.8`, then `9.9.9.9`, skipping
any candidate that is itself one of the profile's server addresses, so a server
that happens to sit on the usual probe address cannot fail its own start.
`status` reports TUN as the connection only from that file. If the proof fails the start
fails instead: the panel shows the error rather than claiming a tunnel your
traffic is still bypassing.

TUN needs the **xray** core. `v2ray` has no tun inbound and does not reject the
key either, so a TUN config handed to it starts an ordinary local proxy and the
system-wide tunnel silently never exists. The switch says so and offers the xray
install instead of a password prompt that cannot help.

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

TUN mode keeps nothing here. Its transient state is written by the privileged
helper into a root-owned directory that `status` only ever reads:

```
/run/omarchy-v2ray-tun/          # tmpfs, 0711 — gone at reboot, not your data
├── state.json                   # profile id, interface, pid, start time  (0644)
├── last-error                   # why the last start failed               (0644)
├── engine.log                   # engine narration                        (0640)
├── helper.log                   # the helper's own log                    (0640)
├── routes                       # the server-exemption prefixes the helper
│                                # installed (`4 <ip>/32`, `6 <ip>/128`), so
│                                # `down` deletes exactly what `up` put in —
│                                # it never holds direct-range prefixes   (0600)
└── config.json                  # the credential; deleted once the engine
                                 # has parsed it                           (0600)
```

`state.json` and `last-error` are the two files worth reading when TUN misbehaves:
the first is what makes the switch say "on", the second is what the panel shows
in its red line. The state file holds the profile id, interface, pid and start
time and no secret; the error file is a flattened engine log tail, never the
profile config.

### The backend CLI

The plugin is a thin UI over `bin/omarchy-v2ray`, which you can run yourself.
Every subcommand prints JSON (except `log`):

```bash
bin/omarchy-v2ray status              # engine + connection state, and mode: tun/proxy/off
bin/omarchy-v2ray tun-status          # TUN: available here, active, why not
bin/omarchy-v2ray tun-up <id>         # start TUN (pkexec; returns before you authenticate)
bin/omarchy-v2ray tun-down            # stop it — idempotent, safe when nothing runs
bin/omarchy-v2ray tun-toggle <id>     # down when active, otherwise up
bin/omarchy-v2ray list                # imported profiles
bin/omarchy-v2ray start <id>
bin/omarchy-v2ray stop
bin/omarchy-v2ray toggle
bin/omarchy-v2ray ping <id>           # real latency, via a throwaway engine
bin/omarchy-v2ray link <id>           # print the share link
bin/omarchy-v2ray log 50
bin/omarchy-v2ray install-tun         # install the privileged helper (see the install section)
bin/omarchy-v2ray autostart <id>|off
bin/omarchy-v2ray remove <id>
bin/omarchy-v2ray import < payload.json   # JSON on stdin — and only on stdin
```

`tun-up` prints a receipt and exits; the authorisation and the tunnel happen in
the privileged process behind it, so poll `tun-status` for the result. `tun-down`
needs no authorisation — it signals the engine you own, escalates to `SIGKILL` if
the engine is still there ~5 s later, and lets the still-running supervisor finish
the root part — but it too returns before that finishes, so poll `tun-status`
here as well. While TUN is active the backend refuses `start`
and `toggle`: the TUN engine owns the same local ports, and the way out is
`tun-down`.

This is the file to read when something breaks: it is plain bash, it needs no
display, and it explains itself.

> **Why `import` refuses arguments.** The payload contains your UUID (or your
> Trojan/Shadowsocks password). A command line and an environment block are
> readable by *every* user on the machine for as long as the process runs —
> `ps -ww`, `/proc/<pid>/cmdline` and `/proc/<pid>/environ` need no privileges —
> so the payload is accepted on stdin only, which is a pipe held just by the
> caller. The same reasoning governs the widget: it writes the payload to the
> backend's stdin instead of passing it as an argument, and it feeds the
> clipboard (where a share link *is* the credential) the same way.

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

TUN mode has no settings of its own, but it uses those same ports: the
privileged config is the profile's config plus a tun inbound, so it rebinds
whatever SOCKS/HTTP pair that profile was imported with. That is also why the
proxy engine is stopped before TUN starts, and why the two modes cannot run at
once. The interface name (`omarchy-tun`) and the resolvers used inside the tunnel
(`1.1.1.1`, `9.9.9.9`) are chosen by the installed helper, not by the widget.

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

**Connecting works but nothing loads (proxy mode).** Check you actually pointed
the app at the proxy (`127.0.0.1:10808`) — in proxy mode the tunnel is not
system-wide by design. See "What connect actually does" above for the two `curl`
commands that tell you whether the app or the tunnel is at fault. (With TUN on,
this entry does not apply: everything is already routed.)

**The bar says ON, pages load, but my IP is still my own (proxy mode).** This is
the same thing, seen from the other end: the pages are loading *directly*, not
through the tunnel, because the browser was never pointed at `127.0.0.1:10808`.
Nothing is broken. Set the proxy in the app, or
`export all_proxy=socks5h://127.0.0.1:10808` before launching it. If the shield
has the TUN dot, this cannot happen — every app is routed — so treat it as "TUN
is not actually up" and check `bin/omarchy-v2ray tun-status`.

**The TUN switch is disabled and says TUN needs the xray core.** `v2ray` has no
`tun` inbound, and it does not reject the key either, so a TUN config handed to
it would start an ordinary local proxy and never create a tun device. Install
xray (see the REALITY entry above); the switch becomes usable and existing
profiles keep working unchanged, because only an inbound is added.

**The TUN switch says the helper is not installed.** The privileged half is not
part of the plugin tree and `omarchy plugin add` does not install it; run
`bin/omarchy-v2ray install-tun` (see "Only for TUN mode" above). The panel offers
an **Install the TUN helper** row for the same thing. The backend refuses
*before* asking for a password in this case, so a missing helper never leaves a
dialog you cannot satisfy.

**Pressing TUN does nothing, and no password prompt appears.** TUN launches
`pkexec`, and `pkexec` needs a polkit authentication agent in your graphical
session to draw the dialog. Without one the request is never shown, and because
the launcher is detached and its output discarded, nothing happens on screen. A
normal Omarchy desktop runs that agent; a bare TTY login or a hand-rolled session
may not. Check whether a prompt can appear at all with `pkexec true` in a
terminal, and ask the backend what it sees with `bin/omarchy-v2ray tun-status`.
The panel pulses for 30 seconds, then reports that the attempt is still
unconfirmed; it keeps proxy connects refused for up to two minutes, so a late
authorisation cannot race a second engine onto the same ports.

**I cancelled the password prompt and now nothing connects.** Starting TUN stops
the local proxy engine first, because the privileged engine needs the same
10808/10809 ports. A cancelled prompt therefore leaves you with no proxy and no
tunnel — and nothing recorded, because no helper ran to write an error. The panel
treats the hand-off as unconfirmed for up to two minutes and then says so. A
terminal is not gated: `bin/omarchy-v2ray start <id>` brings the proxy back
immediately.

**TUN is on but names no longer resolve.** The helper points the system resolver
at `1.1.1.1` and `9.9.9.9` *through* the tunnel. A server that does not carry UDP
(or drops port 53) leaves IP traffic working while every lookup fails.
`resolvectl status omarchy-tun` — or `/etc/resolv.conf` on a machine without
systemd-resolved — shows where lookups are being sent. Turn TUN off and DNS comes
back with the routing.

**How do I get out of TUN mode?** `bin/omarchy-v2ray tun-down`, or the switch
itself — neither asks for a password, because the engine runs as you and your own
session can stop it, while the root supervisor finishes restoring DNS and the
routes (and, if the engine ignores the polite signal, your session escalates to
`SIGKILL` and waits a little longer before ever falling back to a password
prompt). It is idempotent, it works after the profile has been deleted, and
restoring DNS and removing the routes is its only job. `bin/omarchy-v2ray
tun-status` is the read-only way to ask what is actually up. If the supervisor
was killed outright, the next start recovers `/etc/resolv.conf` from its backup
before taking a fresh snapshot, and `tun-down` still cleans up an interface left
without a state file.

**TUN start fails with "could not route traffic through omarchy-tun".** The
helper got the interface up but could not *prove* the routing, so it tore
everything back down rather than claim a tunnel your traffic would bypass. Either
the kernel refused one of the routes it tried to install (there was no default
route to pin the server against, or a conflicting route table), or its proof
failed — the probe address did not come back through the tun, or one of the
server's addresses still resolved through it. Nothing is left half-on: the
address, the `/1` routes and the server exemptions are all removed on the way
out, so the machine is back on a normal direct connection.

**A server named by hostname no longer connects after its address changed.** The
server's name is resolved once, when TUN starts, and the proxy outbound's address
is rewritten to that literal — so the `/32`/`/128` exemption names exactly what
xray dials, and a dial can no longer slip past it into the tun. The flip side is
that a changed address is not re-resolved: if the server moves to a new IP — a
CDN or a load balancer rotating its records — the engine keeps dialling the pinned
old address until you re-start TUN (`tun-down`, then `tun-up`), which resolves and
pins the new one. The SNI/serverName is left alone throughout, so the certificate
name you presented is unchanged.

**Why can't I turn the proxy back on while TUN is up?** Both engines bind the
same ports: the TUN config is the profile's config plus a tun inbound. The
backend therefore refuses `start` and `toggle` with "TUN mode is on — turn it off
from the TUN switch first", rather than starting a second engine that would lose
the bind and leave `status` describing a connection the machine is not using.
Turn TUN off first.

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
| `V2rayShield.qml` | the hand-drawn bar icon: on, off, starting, a warning badge, and the dot that marks TUN |
| `V2rayActionButton.qml` | the small row buttons, with press/busy/confirmed feedback |
| `Model.js` | share-link parsing and engine-config building |
| `bin/omarchy-v2ray` | the backend CLI; every subcommand answers with JSON, and it never gains privilege |
| `bin/omarchy-v2ray-tun` | the privileged half of TUN mode; installed outside the plugin tree, only ever run through `pkexec` |
| `tests/test-backend.sh` | the offline test suite |
| `tests/test-service-import.sh` | drives the real panel under quickshell — import, clipboard and public IPC surface — to prove the credential never reaches argv |
| `tests/test-service-tun.sh` | drives the real `Service.qml` through the TUN state machine, including slow and cancelled prompts |
| `tests/test-tun-helper.sh` | the privileged helper in dry-run, plus the launcher's refusal paths with a recording `pkexec` |

## Extending it

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
handshake verdicts, the collapsed error text, the `set -u` trap that once made
`debug` abort with `sni: unbound variable`, and the credential-handling rules:
an `import` payload is refused on argv and in the environment, and the widget is
checked for the two argv patterns that used to leak the UUID through `/proc` —
the import itself, and the clipboard copy, which now hands the link to a bare
`wl-copy` on stdin.

The same script ends by running `tests/test-service-import.sh`, which is the
counterpart on the caller's side: it starts quickshell with the real
`Service.qml`, imports a link carrying a sentinel credential, and reads the
kernel's view of the process that panel spawned — `/proc/<pid>/cmdline`,
`/proc/<pid>/environ` and its stdin — to show the secret travels on stdin and
nowhere else. It replays the same import against the pre-fix `Service.qml` first,
because an absence check that could never fail proves nothing.

The same file then holds the panel's *public IPC surface* to that rule.
`qs ipc call <target> <function> <arguments…>` puts every argument on the
caller's command line and IPC has no stdin channel, so a public handler taking a
share link would be an argv leak by construction — and `Panel.qml` used to
publish exactly that (`importLink(link: string)`, with a comment encouraging
`omarchy-shell … importLink "vless://…"`). The test loads the real `Panel.qml`,
asks the running panel over its own IPC what it publishes, and fails if the old
name is back *or* if any handler declares a parameter at all; the pre-fix
`Panel.qml` is replayed as the control, where that signature has to appear.

It needs
quickshell and a Wayland session and prints `SKIP` without them, so the suite
stays green headless, and can also be run on its own:

```bash
./tests/test-service-import.sh
```

### TUN: the helper and the panel switch

`tests/test-tun-helper.sh` is the counterpart for `bin/omarchy-v2ray-tun`, the
only part of the project that would need root. No test may create a tun device,
rewrite `/etc/resolv.conf` or ask polkit for anything, so the behavioural cases
drive the real helper in dry-run mode (`OMARCHY_V2RAY_TUN_DRY_RUN=1`): the whole
validation path runs, the exact argv of every command it *would* run is printed,
and it exits without touching `/run`, DNS or a process. The launcher cases put a
recording `pkexec` double on `PATH` and prove that an uninstalled, user-owned or
symlinked helper is refused with `needsHelper` and never reaches `pkexec` at all.

```bash
./tests/test-tun-helper.sh
```

Two checks need root and print `SKIP` for a normal user: a foreign-owned config
(changing a file owner needs root) and the positive launch (it needs a root-owned
helper to execute). They are the only intended skips, and the suite still exits
0 with them.

`tests/test-service-tun.sh` is the panel side. It starts quickshell with the real
`Service.qml`, calls `applyStatus()` with crafted replies, and pins the state
machine around a prompt that can take minutes: a TUN start is gated so a connect
click cannot race it onto the same ports, the gate survives a stale error file
and the 30-second pulse, it gives up after two minutes instead of blocking for
the session, and a stop still reaches the helper so an unanswered stop cannot
strand the switch. It prints `SKIP` without quickshell and a Wayland
session, like the import suite.

```bash
./tests/test-service-tun.sh
```

Both are also invoked by `./tests/test-backend.sh`.

---

## Uninstall

```bash
omarchy plugin disable community.v2ray-client
omarchy plugin remove community.v2ray-client --yes
sudo rm -rf /usr/local/lib/omarchy-v2ray    # the TUN helper installed by install-tun
rm -rf ~/.config/omarchy-v2ray      # your profiles and links — delete only if sure
```

TUN's transient state in `/run/omarchy-v2ray-tun` disappears at reboot; run
`bin/omarchy-v2ray tun-down` first if a tunnel is still up.

## License

MIT.
