# Prusa Connect for Omarchy

Monitor your Prusa Connect printer fleet from the Omarchy bar: printer state,
current job and progress, temperatures, and the reason a printer wants
attention. It is read-only except for one action: **Set ready** on a finished
printer, the same command Connect's own button sends, always behind a
confirmation.

![The panel listing four printers: one printing with progress and ETA, one
finished with an unanswered dialog, and two offline](preview.png)

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
your Prusa account. Sign in once from a terminal:

```bash
~/.config/omarchy/plugins/io.github.hegjon.prusa-connect/prusa-connect-login
```

It asks for your Prusa account email and password, and for a two-factor code
if your account has one, then runs the same OAuth authorization-code + PKCE
flow the Prusa mobile app runs: the sign-in form on `account.prusa3d.com` is
driven directly, and the authorization code is read from the redirect back to
Connect rather than a browser. Only the resulting refresh token is stored.

**The password is sent once, over HTTPS, to `account.prusa3d.com` and nowhere
else.** It is never stored, never logged (even with `--debug`), and never passed
on the command line. This is form scraping, though: if Prusa adds a captcha or
reshapes the page it will stop working, and the paste route below is the
fallback.

### Pasting a token instead

With Prusa Connect open and signed in, run this in the browser console and
paste the result at the prompt of `prusa-connect-login --paste`:

```js
localStorage['auth.refresh_token']
```

Connect stores two tokens side by side and both are JWTs, so they are easy to
confuse. `auth.access_token` lasts about two hours and cannot be renewed;
`auth.refresh_token` is the one to copy. The script reads the `type` claim and
tells you if the wrong one was pasted.

### Why not a browser sign-in flow

`prusa-connect-login --browser` implements the standard OAuth flow with a
loopback redirect. Prusa currently rejects it with `invalid_request —
Mismatching redirect URI`, because no loopback address is registered for their
client; the only registered redirect is Connect's own callback, which is what
the default flow uses. The code is kept for the day that changes.

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
prusa-connect-login --email me@example.com   # skip the email prompt
prusa-connect-login --status    # is a credential present?
prusa-connect-login --forget    # remove it from the keyring
prusa-connect-login --paste     # paste a refresh token from the browser
prusa-connect-login --stdin     # read the token from stdin, for scripted setup
prusa-connect-login --debug     # print request shape (never values) to stderr
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
| Background poll interval | `60` s | From 60 to 3600. Used when nothing is printing |
| Poll interval while printing | `5` s | From 2 to 120. Used whenever any printer is printing, panel open or not |
| Notify when a print finishes | enabled | |
| Notify when a printer needs attention | enabled | |
| Notify on printer errors | enabled | |
| Re-notify cooldown | `10` min | Minimum gap before the same printer notifies again |
| Celsius | enabled | Off shows Fahrenheit |

Polling adapts to what the fleet is doing. A running print is polled every
`printingIntervalSec` (5 s by default) whether or not the panel is open, because
its progress moves continuously and that is what people watch. An idle fleet is
polled every `watchIntervalSec` (60 s), since it does not change. Opening the
panel on an idle fleet polls at `refreshIntervalSec`.

Be aware of the cost: at 5 s a print makes roughly 720 requests an hour, and
Prusa documents no rate limit. If Connect starts refusing, the panel shows the
error rather than hiding it, and raising `printingIntervalSec` is the fix.

If a poll fails, the panel keeps showing the last known fleet with the age in
its footer, but the bar stops showing a progress percentage or an attention
badge once the data is older than three polls — an unqualified "61%" in the bar
has no way to say it might be stale. The tooltip reports the age instead, and
failures are logged (`journalctl --user | grep "prusa-connect: poll failed"`).

Notifications fire on a *transition*, so a printer sitting in ATTENTION across
many polls notifies once rather than every poll. Nothing is announced on the
first poll after the shell starts — the widget waking up is not an event.

### What counts as needing attention

Connect splits a dialog into a short title and the explanation under it —
"Warning" over "Bed leveling failed…". The notification carries both, since
the title alone often says nothing. The panel shows one elided line, because a
fleet overview should stay scannable and a wrapped three-line dialog pushes
every other printer down the list.

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

Each printer shows an illustration of its model, its name, state, current job
with progress and ETA, and either live temperatures or when it was last seen. A
printer asking for attention shows the text of the dialog waiting on its screen.

A job reads **Preparing** until progress leaves zero. Connect reports `PRINTING`
from the moment a job is accepted, through heating, mesh bed levelling and
priming — on a short print that is most of the wall clock, and one six-minute
job spent three and a half minutes there. The wording is deliberately vague:
Connect exposes no sub-phase, and temperatures cannot separate heating from bed
levelling either, since levelling runs with the nozzle held at 175 °C, at target
rather than below it. The one thing that can be said truthfully is that nothing
has been printed yet. The temperatures on the row show what is actually warming.

"Printing with no progress" alone is not enough to mean preparing: a printer
cooling down after a job can report `PRINTING` with a reset job, which looks
identical to warmup. The job's own `state` (`FIN_OK` when done) and its `end`
timestamp settle it — both distinct from the printer-level state.

The illustrations are Prusa's own, bundled from Connect — see
[`assets/printers/NOTICE`](assets/printers/NOTICE). The model is derived from
Connect's model code and tool count, so an MK4IS shows an MK4 (Input Shaper is
firmware, not a different chassis) and a two-tool XL shows the two-tool XL. An
unrecognised model falls back to a generic printer.

Printers Connect cannot currently reach are listed last — their detail is stale
by definition, so they are the least worth reading first. Everything else keeps
the order Connect sends, which is by name.

### Set ready

A finished printer shows a **Set ready** button, matching Connect's own "Set
ready!". It is offered only where it applies: the job has finished, Connect can
reach the printer, and the account has write rights on it.

It always confirms first, with a checklist rather than a single question:

> - Is the print sheet in place?
> - Is the print sheet empty?
> - Is the print sheet clean?

**Set ready** stays disabled until all three are ticked. They are separate
points because each is a separate thing to walk over and look at, and one
combined "yes" invites skimming all three.

That is the point of the command. Marking a printer ready tells the fleet it can
accept another job, so a queued job could start printing onto whatever is still
on the sheet. The questions worth answering are physical ones.

Connect accepts the command before its fleet data reflects it. The panel waits a
second, then polls every two seconds for about fifteen; without that the row
would keep reading `Finished` until the next scheduled poll, up to a minute
later on an idle fleet.

While that is happening the button stays in place, disabled, reading "Setting
ready…" with a slow pulse. It stays rather than vanishing because the row still
says `Finished` until Connect catches up, and a button that disappears looks
like something went wrong. It re-enables if the command fails, and is replaced
by the normal row once the printer reports its new state.

The command goes to Prusa's mobile API (`PUT /api/v1/printers/{uuid}/command/ready`),
which documents it and accepts the same account token the fleet is read with.
Connect's web app uses an unpublished endpoint that would have to be
reverse-engineered from its bundle.

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
details replaced, as is `test/fixtures/printing.json`, captured from a printer
mid-job.

Two things that fixture pins down, both of which would be easy to get wrong:
`job_info.progress` is a **percentage**, not a fraction — the capture reads
`1.0` while `weight_remaining` is still 99% of `model_weight` — and Connect
signals "no time estimate yet" with both `0` and `-1`, the same job reporting
`0` at 117 seconds in and `-1` at 228. Neither may reach the panel as an ETA.

Printer illustrations are refreshed with:

```bash
./tools/fetch-printer-assets --dry-run   # list what would be downloaded
./tools/fetch-printer-assets             # download into assets/printers/
```

Connect's asset filenames carry a build hash that changes on every redeploy, so
the script follows the app's own chunk graph (`/login` → `index-<hash>.js` →
`main-<hash>.js` → the SVG list) rather than hardcoding URLs, and stores the
files with the hash stripped.

## Licence

MIT, **except** the printer illustrations in `assets/printers/`, which belong to
Prusa Research a.s. and are not covered by it — see [`NOTICE`](NOTICE) and
[`assets/printers/NOTICE`](assets/printers/NOTICE) for provenance and the terms
they are included under. Deleting that directory costs nothing but the
illustrations: the panel falls back to generic status glyphs.

This plugin is not affiliated with, endorsed by, or supported by Prusa Research.
