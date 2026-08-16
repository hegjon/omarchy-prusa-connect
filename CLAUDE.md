# Working notes for agents

Omarchy bar-widget plugin. This checkout *is* the installed plugin
(`~/.config/omarchy/plugins/hegjon.prusa-connect`), so edits are live.

## Verifying changes

- `test/lint` (qmllint over `*.qml` and `components/*.qml`), `test/test-normalize`,
  `test/test-manifest`, and `omarchy-plugin-validate .`. `shellcheck` is not
  installed locally; CI runs it (`.github/workflows/ci.yml`), so watch the run
  after pushing shell changes.
- The shell hot-reloads the plugin on file change, but not reliably for
  everything (a changed `backendPath` was not picked up). For a trustworthy
  check run `omarchy-restart-shell`, wait ~7 s, then read
  `journalctl --user --since "30 sec ago" | grep -i prusa` for QML errors.
- IPC: `omarchy-shell hegjon.prusa-connect open|close|toggle|refresh`.
  The widget replaces Panel's IpcHandler so `refresh` exists.
- Screenshots: `grim` + `magick -crop` on the right of the 3840×2160 monitor
  (panel is roughly `-crop 1100x1000+2740+40`). No mouse automation is
  available (`wtype` only), so buttons cannot be clicked from a script.
- To render the panel without a signed-in account, point `backendPath` at a
  stub that runs `jq -f normalize.jq < test/fixtures/printers.json`
  (temporarily — revert before committing). `printers.json` has one FINISHED
  printer with a dialog, which exercises the attention line and Set ready.
- End-to-end auth check: `./prusa-connect-fetch | jq .summary`. Forcing a
  token refresh: `rm $XDG_RUNTIME_DIR/omarchy-prusa-connect/access-token`.
  Forcing the 401 arm: write `<future-epoch>\tbogus\n` into that file.

## Things that bit before

- The access-token cache reader once rejected every file because `read`
  returns 1 at EOF without a trailing newline; every poll then rotated the
  refresh token. Keep the trailing newline and the `|| [[ -n $token ]]` guard.
- The plugin id (`hegjon.prusa-connect`) is also the keyring `application`
  attribute and the IPC target. Renaming it orphans stored tokens.
- Sign-in scrapes account.prusa3d.com's login form (see `prusa-connect-login`);
  Prusa's OAuth client has no loopback redirect and no password grant.
  `--paste` is the fallback. Never let a password or authorization code reach
  argv, logs or `--debug` output.

## Style

- Comments in this repo explain *why*, and several document deliberate
  choices (alternative field spellings in `normalize.jq`, `offline_last`
  ordering, `detailColor`, "Preparing" wording). Read them before "simplifying".
- Commit messages: imperative subject, body explains the reasoning; tags are
  annotated `vX.Y.Z` "Prusa Connect for Omarchy X.Y.Z"; version lives in
  `manifest.json` and the `USER_AGENT` in `prusa-connect-login`.
