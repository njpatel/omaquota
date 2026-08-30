![Omaquota](assets/title.png)

<!--
 ▄█████▄    ▄███████████▄     ▄███████   ▄█████▄    ▄█   █▄    ▄█████▄   ▄███████▄  ▄███████
███   ███  ███   ███   ███   ███   ███  ███   ███  ███   ███  ███   ███     ███    ███   ███
███   ███  ███   ███   ███   ███   ███  ███   ███  ███   ███  ███   ███     ███    ███   ███
███   ███  ███   ███   ███  ▄███▄▄▄███  ███   ███  ███   ███  ███   ███     ███   ▄███▄▄▄███
███   ███  ███   ███   ███  ▀███▀▀▀███  ███   ███  ███   ███  ███   ███     ███   ▀███▀▀▀███
███   ███  ███   ███   ███   ███   ███  ███   ███  ███   ███  ███   ███     ███    ███   ███
███   ███  ███   ███   ███   ███   ███  ███  ▄███  ███   ███  ███   ███     ███    ███   ███
 ▀█████▀    ▀█   ███   █▀    ███   █▀    ▀█████▀    ▀█████▀    ▀█████▀      ▀█▀    ███   █▀
                                              ▀█▄
-->

[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) usage and per-subscription quota in the [Omarchy](https://omarchy.org) bar.

![Omaquota](assets/omaquota.png)

## Install

```sh
omarchy plugin add https://github.com/njpatel/omaquota.git --enable
~/.config/omarchy/plugins/njpatel.omaquota/bin/omaquota-setup
omarchy restart shell
```

Setup asks for the proxy URL and its management key (the plaintext one, not the hash in `config.yaml`). The proxy needs `remote-management.allow-remote` if it is not on localhost and `usage-statistics-enabled` for the stats block. Omaquota consumes the proxy's usage queue, so run only one consumer; the cost line is an estimate at [models.dev](https://models.dev) list prices. If the `cap-token-usage-tracker` plugin is installed, history from before Omaquota is seeded from it once.

## Use

Click the icon.

| key | |
|---|---|
| `e` | aggregate per provider / every account |
| `t` | 24h / 7d |
| `h` | redact account names |
| `r` | cycle what the bar shows |
| `i` | cycle the bar icon |
| `Enter` | refresh |
| `j` `k` | scroll |

The icon turns urgent when a 5h or 7d window drops to 10%. The number beside it always covers the **last 24 hours**; choose what it shows with `r` in the panel or `barMetric`: `tokens` (in+out, default), `tokens-split` (`↑in ↓out`), `requests`, `cost`, or `none` - e.g. `omarchy bar set njpatel.omaquota barMetric cost`. The icon is `barIcon`: a name such as `gauge`, `speedometer`, `pulse`, `waveform`, `coins`, `usd`, `counter`, `chart`, `brain`, `robot`, `server` (full list in `manifest.json`), or any Nerd Font glyph.

## Where the numbers come from

- **Usage** is built from the proxy's own per-request records (`GET /v0/management/usage-queue`), folded into hourly buckets and kept for 7 days. Per request: uncached input, cache reads, cache writes and output (output includes reasoning tokens). `input` in the panel is uncached + cache reads; `cached %` is cache reads ÷ input.
- **Cost** prices those four parts separately at [models.dev](https://models.dev) list rates for the model, refreshed daily. It is an estimate: context-tier and service-tier surcharges are ignored.
- **Quota** is what each provider reports for the account (Anthropic `oauth/usage`, ChatGPT `wham/usage`, grok billing), fetched through the proxy's `api-call` passthrough, no more often than `quotaIntervalSec`.

## License

Apache-2.0
