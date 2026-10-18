# SiliconPulse visual audit

Baseline: PR #1 at `1a784a3`, captured by `--screenshots` on the CI macOS runner (light and dark, 920 / 1180 / 1600 px wide). The runner is a VM with a 768 px tall screen, so window heights are clamped to about 684 px. Two mock AI runtimes (Ollama and llama-server, `scripts/mock-runners.py`) are active.

The app is clean and correct, but it reads as an engineering dashboard: a grid of similarly weighted bordered panels, many tiny uppercase labels, and an info icon next to nearly every number. It does not answer "what is my Mac doing right now?" faster than Activity Monitor does, and its differentiator, local AI, is below the fold.

## Overview

| Problem | Where | Why it matters |
|---|---|---|
| **Flat hierarchy.** Five equal tiles: CPU, GPU, Memory, Pressure, Thermal. | Top strip | "Pressure: Normal" and "Thermal: Normal" take as much space as CPU and GPU, although normal states need no attention. |
| **Equal chart grid.** CPU, GPU, Memory, Disk and Network each get an identical card. | Activity grid | Disk and network are rarely the story, but they get the same weight as compute. At 1600 px all five squeeze into one row; at 1180 px they leave an orphan slot. |
| **Local AI below the fold.** At 1180 × 684 only the "LOCAL AI" header is visible. | Local AI panel | The product's differentiator is the last thing you see. |
| **No machine identity or state.** Nothing says which Mac this is or whether it is healthy. | Page top | The 2-second answer ("my Mac is fine" / "memory is the problem") is missing. |
| **Info-icon noise.** About 15 ⓘ glyphs on the first screen, and on AI cards an extra boxed MODEL/SYSTEM tag on every metric. | Everywhere | Quality metadata is valuable, but showing it on exact and reported values buries the few estimated ones that need a flag. |
| **Uppercase labels everywhere.** CPU, GPU, MEMORY, PRESSURE, THERMAL, ACTIVITY, LOCAL AI, TOP CPU and so on. | Everywhere | Wall-to-wall small caps flattens hierarchy and reads as a web admin panel. |
| **Card soup.** Every block has a fill, a border and a corner radius. | Everywhere | In dark mode they become a stack of grey rectangles; in light mode, grey boxes on grey. |
| **Empty chart halves after launch.** The 60 s window draws from the left edge, so fresh charts are half blank. | Charts | Looks broken for the first minute. |
| **Dead GPU card.** When the GPU does not report utilization (VMs), a full chart card says so in grey. | Activity grid | The space has no information. One line would do. |
| **Chart details.** "100%" / "7.0 GB" scale labels sit inside the plot, the grid is heavy enough to compete with data, no current-value marker, and lines are straight segments. | Charts | Busy without being informative. |
| **Large windows.** At 1600 px the tiles spread out with no maximum width; text lines become very long. | Whole page | Composition falls apart on big displays. |

## AI Models

- **Technical content first.** The SYSTEM / PROCESS / MODEL legend is the first thing on the page, before any model.
- **Every metric carries a boxed scope tag and an ⓘ.** On a two-workload page that is about 20 badges.
- **"The runner's process is not visible…" is repeated** in every card, at body-text weight.
- **The two workloads are visually identical,** whether one is generating at 40 tok/s or idle.
- **The activity timeline is a grey strip** with hairline marks; the "EST" badge next to it is cryptic.
- **Model facts** (identifier, format, source) sit in the main card above the disclosure, mixing diagnostics with the essentials.
- **The detection status block** is a full panel at the bottom, but it is diagnostics for most users.
- The "RUNNING" capsule and the "Inference active" text are stacked separately and compete with each other.

## Processes

- **The six-segment filter** (All · Apps · System · AI · High CPU · High Memory) is crowded and mixes categories with thresholds.
- **Numbers are left-aligned,** so digits do not line up down a column.
- **The Arch column** spends 70 px repeating "Apple" on every row; **User** is truncated at 1180 px.
- **AI processes** are marked only by a 9 pt sparkle after the name.
- **The inspector** is a long list of label/value rows with uppercase section labels and no visual summary.

## Memory

- The top section is good in principle (used / pressure / headroom), but it is boxed, and the composition bar's legend wraps awkwardly.
- **"Breakdown" and "Swap & compression"** are two boxed panels showing similar rows, each with ⓘ icons.
- **Free memory is missing** from the composition bar, so the bar does not add up visually.
- **Swap, compression and pressure** look the same whether normal or alarming.
- History charts repeat the Overview card style.

## Compute

- **CPU and GPU are boxed side panels** with stat lists; the per-core bars are functional but plain.
- **The Neural Engine** gets a full panel to say "Not exposed"; it should be one quiet line.
- **Thermal & power** is another full panel for two values that are normally fine.

## Disk & Network, History

- Two big boxed panels with tiles that repeat the Overview pattern.
- Per-process and per-interface lists use the same row style as everything else, with no hierarchy.
- History is five identical chart cards stacked vertically.

## Menu bar popover

- **A list of label/bar/value rows:** functional, but it does not feel designed. Pressure and thermal take full rows even when normal.
- **The AI block** is small and reads like a footnote.
- **The action rows** sit flush against the content with no visual separation from the data.

## Sidebar & chrome

- **No product identity** in the window: the sidebar starts directly with "Overview".
- **The AI Models row** shows a plain count ("2"). Nothing indicates whether a model is generating right now.
- **The toolbar title** ("Overview") is small and dim; pages have no title of their own.
- **"Sampling every 1 s"** in the toolbar is engineering detail in a prime location.

## Dark mode

- Panels render as flat grey slabs (`controlBackgroundColor` at 55%) on a near-black page; borders are clearly visible.
- Chart fills are muddy; the grey "Running"/"Idle" pills lack contrast.
- Secondary text is fine, but tertiary text (scale labels, notes) is close to unreadable.

## Light mode

- Grey boxes on a grey window background, with no clear surface hierarchy.
- Status colors (green pills) are a little loud next to the otherwise neutral UI.

## Principles for the redesign

1. **Two-second answer.** The Overview starts with machine identity and a single health state, then CPU, GPU and memory as the three dominant numbers, each with its own chart.
2. **AI is the hero.** When a model is loaded, the Active Model section is the most prominent element after the primary metrics, with a live indicator while it generates.
3. **Quiet normal states.** Pressure, thermal and swap collapse into one secondary line unless abnormal; when abnormal they are promoted into a tinted banner.
4. **Quality without noise.** Exact, reported and calculated values carry their source in the tooltip only; estimated values say "Estimated"; unavailable values say "—" with a reason on hover.
5. **Fewer containers.** Three surface levels (page, raised section, emphasized), with hierarchy from type, spacing and hairlines before boxes.
6. **Sentence-case labels.** Uppercase only for a couple of deliberate markers.
7. **Lightweight motion.** One Core Animation pulse for live inference, which stops when idle and respects Reduce Motion; no per-sample number animation.

## After the redesign

Captured with `--screenshots` in CI, in light and dark, at 920, 1180 and 1600 pt wide. The final captures are in `docs/screenshots/`.

| Area | Before | After |
|---|---|---|
| Overview | Five equal tiles, an equal chart grid, Local AI below the fold | Machine name and health, then CPU, GPU and memory as one instrument with hero numbers and charts. Pressure, thermal and swap share one quiet line (a banner when abnormal). The Active Model hero follows, then small disk, network and top-process lists |
| AI Models | Panels of evidence before the model | A hero per runtime with tokens/sec, GPU, memory and CPU (system GPU always labeled whole Mac). Model facts, evidence and scope are behind one disclosure; detection details are collapsed |
| Quality marks | About 15 ⓘ icons and a badge on every value | Sources on hover; only *Estimated* is visible; unavailable values show a dash and the reason |
| Memory | A boxed top section, two similar boxed panels, and no free memory in the bar | A 44 pt used value, then pressure, swap and headroom. A composition bar shows app, wired, compressed, cached and free memory |
| Compute | Boxed CPU and GPU side panels, and full panels for the Neural Engine and thermal | A hero CPU number with P/E clusters, a 130 pt chart and per-core bars grouped by cluster. GPU readouts and per-process GPU time follow; the Neural Engine is one limitation line |
| Processes | Six-segment filter, left-aligned numbers | Four-way segmented filter plus a "High usage" menu, right-aligned numerics, AI rows tinted, and a calmer inspector |
| Popover | A list of label, bar and value rows, with the AI block as a footnote | Brand, health, three columns with bars, a status line, the active model, and hover-highlighted actions |
| Sidebar | No identity; a count on AI Models | Brand mark, a live pulse on AI Models while a model generates, and a quiet "Live · Local only" footer |
| Surfaces | Grey slabs, visible borders | A page color plus two translucent levels; hairline borders only on the emphasized AI hero |
| Icon | Generic | A graphite die with pins and a pulse trace, the same mark as the menu-bar template image |

### Release-candidate pass

- **oMLX** has a first-class identity on AI Models, Overview and the popover: its own runner glyph, model name first, "1 of 3 models loaded", and its session-average tokens/sec labeled as such.
- **Overview memory bar** now has a legend: the colored part is used memory (app, wired, compressed) and the grey remainder is cached files and free memory. A narrow window shows "Used" / "Cached & free".
- **Settings** had a restrained native pass:
  - section footers for explanations;
  - a menu-bar preview drawn like the menu bar;
  - custom endpoints in their own section;
  - oMLX's port listed;
  - stale ⓘ copy removed.
- **History** shares one hover cursor across all charts.
- **Popover** values scale down instead of overflowing for large-memory Macs. It is also captured by clicking the real status item.
- **Captions** wrap to a second line instead of truncating at the minimum window width.

### Still worth more work

- **Compute on a Mac with no GPU utilization or P/E data** (such as the CI virtual machine) is sparse; a physical Apple Silicon Mac fills both sections.
- **Sidebar icons in dark captures** look dimmer than on a real display, because offscreen capture skips sidebar vibrancy.
- **Real-display checks** are still open: popover hover states, Retina rendering and the popover's position. See `docs/VALIDATION.md`.
