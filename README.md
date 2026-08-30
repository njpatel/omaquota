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
| `x` | redact account names |
| `r` | refresh |
| `j` `k` | scroll |

The icon turns urgent when a 5h or 7d window drops to 10%. The number beside it always covers the **last 24 hours**; choose what it shows with `barMetric`: `tokens` (in+out, default), `tokens-split` (`↑in ↓out`), `requests`, `cost`, `lowest` remaining quota, or `none` — e.g. `omarchy bar set njpatel.omaquota barMetric cost`.

## License

Apache-2.0
