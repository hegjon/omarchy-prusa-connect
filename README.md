# Prusa Connect for Omarchy

Monitor your Prusa Connect printer fleet from the Omarchy bar: printer state,
current job and progress, temperatures, and the reason a printer wants
attention. Monitoring only — this plugin never sends commands to a printer.

Because it reads Prusa Connect rather than the printers directly, it sees every
printer on your account, wherever they are, not just the ones on your network.

## Install

```bash
omarchy plugin add https://github.com/hegjon/omarchy-prusa-connect.git --enable
omarchy restart shell
```

If the widget is enabled but not visible, place it explicitly:

```bash
omarchy plugin enable io.github.hegjon.prusa-connect --section right
omarchy restart shell
```

Update or remove:

```bash
omarchy plugin update io.github.hegjon.prusa-connect --yes
omarchy plugin remove io.github.hegjon.prusa-connect
```

Requires `curl`, `jq`, `python3` and `secret-tool` (package `libsecret`), all
of which are present on a stock Omarchy system.

## Signing in

Prusa Connect has no API keys, so the plugin needs an OAuth refresh token for
your Prusa account. Prusa's OAuth client is registered only for their own web
and mobile apps, so the token has to be copied out of a signed-in browser
session:

```bash
~/.config/omarchy/plugins/io.github.hegjon.prusa-connect/prusa-connect-login --paste
```

With Prusa Connect open and signed in, run this in the browser console and paste
the result at the prompt:

```js
localStorage['auth.refresh_token']
```

Connect stores two tokens side by side and both are JWTs, so they are easy to
confuse. `auth.access_token` lasts about two hours and cannot be renewed;
`auth.refresh_token` is the one to copy. The script reads the `type` claim and
tells you if the wrong one was pasted.

**No password is ever handled by this plugin.** Authentication happens in your
browser; only the resulting refresh token is stored.

### Why not a browser sign-in flow

`prusa-connect-login` also implements a standard OAuth authorization-code flow
with PKCE and a loopback redirect. Prusa currently rejects it with
`invalid_request — Mismatching redirect URI`, because no loopback address is
registered for their client. The code is kept for the day that changes; until
then use `--paste`.

The OAuth password grant is also closed: `account.prusa3d.com` answers every
credential combination with `invalid_grant`.

### Staying signed in

Prusa's refresh tokens last about 30 days and rotate on every use, and the
plugin writes each rotated token straight back to the keyring. So as long as it
polls at least once every 30 days it stays signed in indefinitely. Leave the
machine off for longer than that, or sign out of Connect in your browser, and
you will need to paste a fresh token.

Other commands:

```bash
prusa-connect-login --status    # is a credential present?
prusa-connect-login --forget    # remove it from the keyring
prusa-connect-login --stdin     # read the token from stdin, for scripted setup
prusa-connect-login --debug     # print request shape and raw responses
```

### Where the credential lives

Only the refresh token is stored, and only in the GNOME keyring under
`application=io.github.hegjon.prusa-connect`. It is never written to a config
file, never passed as a command-line argument where `ps` could show it, and
never logged. Access tokens are cached in `$XDG_RUNTIME_DIR` at mode 0600 and
expire on their own.

`prusa-connect-login --forget` removes the credential completely. Signing out of
Prusa Connect in your browser also invalidates it.

## Configuration

Settings appear in the Omarchy bar widget settings.

| Setting | Default | Description |
| --- | --- | --- |
| Show print progress on the bar icon | enabled | Replaces the icon with a percentage while one printer is running |
| Hide idle and offline printers | disabled | Show only printers doing something |
| Refresh interval while the panel is open | `30` s | From 10 to 300 |
| Keep polling in the background | enabled | Needed for the bar summary and notifications |
| Background poll interval | `300` s | From 60 to 3600 |
| Notify when a print finishes | enabled | |
| Notify when a printer needs attention | enabled | |
| Notify on printer errors | enabled | |
| Re-notify cooldown | `10` min | Minimum gap before the same printer notifies again |
| Celsius | enabled | Off shows Fahrenheit |

Notifications fire on a *transition*, so a printer sitting in ATTENTION across
many polls notifies once rather than every poll. Nothing is announced on the
first poll after the shell starts — the widget waking up is not an event.

### What counts as needing attention

A printer wants a human when it reports `ATTENTION` or `ERROR`, **or** when it
has an unanswered dialog on its screen — a printer can sit in `FINISHED` with a
dialog waiting, which is easy to miss. Either lights a count badge on the bar
icon and raises a notification.

A dialog on a printer Connect cannot currently reach does not count. That dialog
is as stale as the printer state next to it, and badging the bar over something
last seen months ago is noise.

The rule lives in one place, `needsAttention` in `normalize.jq`, so the badge,
the summary count and the notification cannot drift apart.

## Panel

Each printer shows a status icon, its name, state, current job with progress and
ETA, and either live temperatures or when it was last seen. A printer asking for
attention shows the text of the dialog waiting on its screen.

Printers Connect cannot currently reach are listed last — their detail is stale
by definition, so they are the least worth reading first. Everything else keeps
the order Connect sends, which is by name.

The status icon follows `needsAttention`, so a printer sitting in `FINISHED`
with an unanswered dialog shows an alert rather than a tick. The state word
keeps its own colour: a finished print is not a problem just because a dialog is
also waiting, and the icon and dialog line already carry that.

Icons come from the Nerd Font's Material Design set — generic status shapes
(`md-play`, `md-check_circle`, `md-alert`, `md-lan_disconnect`, `md-pause`)
rather than printer variants, which are harder to tell apart at this size when
every row is already a printer. `stateGlyph()` in `PrusaWidget.qml` lists the
printer-family codepoints in a comment for anyone who prefers them.

| Input | Action |
| --- | --- |
| Click the bar icon | Open or close the panel |
| Middle-click the bar icon | Refresh now |
| `R` | Refresh now |
| `Esc` | Close |

## Notes on Prusa Connect

Connect reports two state fields that can disagree. `connect_state` is whether
Connect can currently reach the printer; `printer_state` is the last thing the
printer itself said, which may be months stale. This plugin treats liveness as
authoritative, so a printer unplugged since February reads `Offline` rather than
showing a stale `Attention` badge.

Temperatures, tool details and job information are omitted entirely for a
printer Connect cannot reach, so every one of those fields is optional.

`account.prusa3d.com` sits behind Cloudflare, which answers Python's default
`User-Agent` with a `1010` browser-signature ban. Every request the plugin makes
therefore sends an explicit `User-Agent`.

## Development

```bash
./test/test-normalize    # response normalization, against fixtures
./test/lint              # qmllint over the QML
```

Neither involves credentials or network access.

`qmllint` ships with `qt6-declarative`, which Quickshell already depends on, but
it lives in Qt's versioned bin directory (`/usr/lib/qt6/bin/qmllint`) rather than
on `PATH`. `test/lint` finds it either way and builds the import root that
Quickshell provides at runtime for the `qs.*` modules.

It suppresses two warning classes that are not defects: `missing-property` on
`Style.*` / `Color.*`, whose nested `QtObject` groups qmllint cannot introspect
(first-party plugins report the same — `weather/BarWidget.qml` alone produces
15), and the `QProcess::ExitStatus` signal parameter on `onExited`. Anything
else, particularly `[unqualified]`, is a real finding.

`test/fixtures/printers.json` is a real Connect response with identifying
details replaced. `test/fixtures/printing.json` is synthetic: the job field
names it uses have not yet been confirmed against a live printing printer, and
`normalize.jq` deliberately accepts several spellings until they are.

## Licence

MIT.
