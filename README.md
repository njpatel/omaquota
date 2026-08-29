<pre>
                 ▄▄▄
 ▄█████▄    ▄███████████▄     ▄███████   ▄█████▄    ▄█   █▄    ▄█████▄   ▄███████▄    ▄███████
███   ███  ███   ███   ███   ███   ███  ███   ███  ███   ███  ███   ███     ███      ███   ███
███   ███  ███   ███   ███   ███   ███  ███   ███  ███   ███  ███   ███     ███      ███   ███
███   ███  ███   ███   ███  ▄███▄▄▄███  ███   ███  ███   ███  ███   ███     ███     ▄███▄▄▄███
███   ███  ███   ███   ███  ▀███▀▀▀███  ███   ███  ███   ███  ███   ███     ███     ▀███▀▀▀███
███   ███  ███   ███   ███   ███   ███  ███   ███  ███   ███  ███   ███     ███      ███   ███
███   ███  ███   ███   ███   ███   ███  ███  ▄███  ███   ███  ███   ███     ███      ███   ███
 ▀█████▀    ▀█   ███   █▀    ███   █▀    ▀█████▀    ▀█████▀    ▀█████▀      ▀█▀      ███   █▀
                                              ▀█▄
</pre>

An [Omarchy](https://omarchy.org) bar widget for [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI).
One icon in the bar, one TUI-style panel: what the proxy is doing, and how
much quota every subscription behind it has left.

![aggregated 24h · expanded 24h · expanded 7d](assets/omaquota.png)

Left to right: aggregated per provider (`e`), every account, and the 7-day
range (`t`). Account names are redacted with `x`. Works against a remote proxy
— mine runs on another machine over Tailscale.

## Install

```sh
omarchy plugin add https://github.com/njpatel/omaquota.git --enable
~/.config/omarchy/plugins/njpatel.omaquota/bin/omaquota-setup
```

Setup asks for the proxy URL, a label, and the management key, checks the key
against the proxy, and writes:

- `~/.config/omaquota/management-key` (0600) — the **plaintext** key.
  `config.yaml` may hold a bcrypt hash of it; that is not the key.
- `baseUrl` / `hostLabel` on the widget's entry in `~/.config/omarchy/shell.json`.

Requirements on the proxy: `remote-management.allow-remote: true` if it is not
on localhost, and the `cap-token-usage-tracker` plugin for the stats block.
Requirements here: `python3`, `curl`.

## Use

| key | | mouse on the icon | |
|---|---|---|---|
| `j` `k` | scroll | left | open / close |
| `e` | aggregate per provider ↔ every account | middle | 24h ↔ 7d |
| `t` | 24h ↔ 7d | right | refresh |
| `x` `h` | redact account names | | |
| `r` | refresh now | | |

The icon shows requests in the last 24h (`barMetric`: `requests`, `tokens`,
or `lowest` remaining %). It turns urgent when a primary 5h/7d window is at
10% or less; model-scoped weekly caps show in the panel but never light the bar.

Settings: `omarchy bar set njpatel.omaquota <key> <json>` —
`baseUrl`, `hostLabel`, `keyFile`, `refreshIntervalSec` (300),
`quotaIntervalSec` (900), `barMetric`.

IPC: `omarchy-shell njpatel.omaquota open|close|toggle|refresh|expand|scrub|range`.

## How it works

`bin/omaquota-fetch` (Python, stdlib) runs every `refreshIntervalSec` and
writes one snapshot to `~/.local/state/omarchy/omaquota/snapshot.json`;
`Widget.qml` only renders that file, so the panel opens instantly even when
the proxy is down.

- Subscriptions and their success/failure counters: `GET /v0/management/auth-files`.
- Proxy-wide totals and per-model rows: the `cap-token-usage-tracker` plugin's
  `stats/initial` endpoint, 24h and 7d.
- Per-account quota: `POST /v0/management/api-call` with
  `Authorization: Bearer $TOKEN$`, which the proxy swaps for the account's
  own token — Anthropic `api/oauth/usage` for Claude (5h, 7d, model-scoped
  weekly), ChatGPT `backend-api/wham/usage` for Codex (primary, secondary,
  extra limits), grok billing for xAI (best effort).

Quota results are cached for `quotaIntervalSec`; a `429` parks that account
until its `Retry-After` passes and keeps the last good numbers, marked stale.
Anthropic rate-limits the usage endpoint when it is polled hard — keep the
interval generous.

## License

Apache-2.0
