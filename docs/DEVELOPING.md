# Working on omaquota

> Not called `AGENTS.md`, and not at the repository root, on purpose. Omarchy
> installs a plugin's whole tree into `~/.config/omarchy/plugins/`, so a root
> agent-instruction file would become ambient context for any coding agent the
> *installing user* happens to run — instructions they never chose to load.
> Marketplace review raised this on omapager; the same reasoning applies here.
> If you keep a `CLAUDE.md` symlink to this file locally, leave it untracked.

CLIProxyAPI usage and per-subscription quota in the Omarchy bar: a bar icon
with a number, and a TUI-style panel behind it.

**The fetcher is the only thing that talks to the proxy.** `Widget.qml` renders
`snapshot.json` and nothing else. If a change would make the QML reach the
network, it belongs in `bin/omaquota-fetch` instead.

## Layout

| | |
| --- | --- |
| `bin/omaquota-fetch` | talks to the proxy, prices the result, writes `snapshot.json` |
| `bin/omaquota-setup` | asks for the proxy URL and management key, once |
| `Widget.qml` | the bar entry and the panel; **also where settings live** |

Settings only reach a bar widget, so `Widget.qml` reads them from the plugin's
`shell.json` entry and passes them to the fetcher as one JSON argument:
`baseUrl`, `keyFile`, `hostLabel`, `refreshIntervalSec`, `quotaIntervalSec`,
`barMetric`, `barIcon`.

## Running and testing

```bash
qmllint Widget.qml                 # CHECK THE EXIT CODE
omarchy-restart-shell              # reload (never omarchy-refresh-shell)
bin/omaquota-fetch --print         # fetch once and dump the snapshot
omarchy-shell njpatel.omaquota demo   # staged proxy, again to go back
```

`demo` swaps in an invented fleet. Use it for anything you would otherwise
screenshot: **while it is on nothing is fetched**, so a demo can never drain
the real proxy's usage queue or put anyone's email on screen. Like omabot's, it
is an IPC verb rather than a setting because writing the bar entry reloads the
widget and would throw the roster away.

## The thing that will bite you first

**The usage queue is pop-on-read.** `GET /v0/management/usage-queue` *removes*
what it returns. Consequences, in order of how much time they cost:

- **Run exactly one consumer.** Two omaquotas, or omaquota plus anything else
  reading that endpoint, silently split the records and both undercount.
- **Never drain it by hand while debugging.** Curling that endpoint to "see
  what's there" destroys records the widget will never get back. Read
  `~/.local/state/omarchy/omaquota/usage.json` instead — it is the folded
  result and it is safe.
- The proxy drops queued records older than
  `redis-usage-queue-retention-seconds`, **default 60**, max 3600. At 60s
  anything between two refreshes is lost and every number is an undercount.
  Set it to 3600. This is the bug that made the figures wrong before 30 Aug.

`drain_queue()` pops up to 40 batches of 500 per run and stops on a short
batch, so a busy proxy still empties in one pass.

## Things that cost a day to learn

- **Prices come from models.dev, not from a table here.** The catalogue is
  cached six hours, and refreshed early the moment usage names a model it has
  never heard of — a model released this morning would otherwise price at zero,
  which reads as *free* rather than as *unknown*.
- **Model ids must match exactly.** `price_for()` tries the mapped provider,
  then the raw one, then any provider listing that exact id. A model the
  catalogue does not carry lands in `unpriced_requests` rather than quietly
  costing nothing.
- **Cache reads dominate everything.** Agentic traffic re-sends the whole
  conversation every turn, so cache-read tokens run 10-100x the fresh input.
  That is why the bar counts only uncached input, and why a wrong cache-read
  price moves the total more than a wrong input price.
- **The panel is one rich-text block on a fixed monospace grid.** Every piece
  of text goes through `cell()`, which clips to its column width. Adding a
  column means re-checking the widths, not appending to a row.
- Windows are **rolling**, filling as data arrives, and the panel says so until
  they are full. A 24h figure on a fresh install is not wrong, it is young.
- **The management key is the plaintext one**, in `~/.config/omaquota/`, not
  the bcrypt hash in the proxy's `config.yaml`. The hash cannot authenticate
  and never leaves the server.

## State

`~/.local/state/omarchy/omaquota/` — `snapshot.json` (what the widget draws),
`usage.json` (hourly buckets, 7 days), `models-dev.json` (the price catalogue).
The key lives in `~/.config/omaquota/`, separately, and is the only secret.

## Conventions

Comments say **why**, and especially why not the obvious thing. Keep them when
you move code; delete them when they stop being true. No new runtime
dependencies: Quickshell, Python 3, `curl`.

## Contributing

### How we review contributions

We review the idea first: does it fit the project, and does it solve a useful problem?

If it does, we prefer helping it land over sending you through repeated rounds of small adjustments. We’ll offer directly applicable suggestions where useful. For remaining maintainer preferences, we may prepare and verify a follow-up fix, merge your contribution, then land our adjustments immediately afterwards. Your contribution keeps its GitHub authorship and credit; our follow-up changes are ours.

Further review rounds are appropriate when the idea fits but the implementation still has substantial correctness, security or design problems. We may also offer to finish the agreed changes on your PR branch, with your consent and without rewriting your commits.

We won’t knowingly merge a broken or unsafe intermediate version. Required checks and release or verification gates still apply. If a contribution doesn’t fit the project, we’ll explain that and close it rather than leave it waiting indefinitely.
