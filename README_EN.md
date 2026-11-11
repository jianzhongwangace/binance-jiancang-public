# Binance Position-Building Realtime Monitor (Public Page)

[中文](README.md) | English

An original project by 王建中. This is the public GitHub Pages deployment of the desktop “Binance position-building” monitor, for viewing main- and sub-account positions, P&L, and related charts at any time.

**Live page:** [https://jianzhongwangace.github.io/binance-jiancang-public/](https://jianzhongwangace.github.io/binance-jiancang-public/)

## Features

- **Account summary:** wallet balance, margin, unrealized P&L, available balance, equity, and accumulated fees, also converted to CNY.
- **One product per row:** Binance position card on the left, add-position calculator in the middle, matching US-stock card on the right.
- **Position cards:** size, entry, mark, leverage, margin, liquidation price, realized P&L, and more. Each field is annotated with its actual freshness, e.g. “refreshed x seconds ago.”
- **Charts:** Binance cards default to the 15-minute candlestick interval (the 5-minute interval uses a line chart); US-stock cards default to the weekly interval. Entry, last, and liquidation prices are all drawn at their true values; the price scale expands to include all three lines.
- **Add-position calculator:** enter an extra position size or extra margin (each can be inferred from the other) to see the blended entry, margin required for the chosen leverage, extra margin needed to keep the current liquidation price, total margin required, real leverage before and after, and the new liquidation price. Amounts include a CNY note.
- **US-stock comparison:** quotes for the related ticker (including pre-market when available).

The page is for display and calculation only. It does not place orders.

## What’s in this repo

| File | Purpose |
| --- | --- |
| `index.html`, `实时价格监控_WebSocket版.html` | The monitor page (kept identical) |
| `positions_live.js` / `.json`, `subaccount_live.js` / `.json` | Live snapshots for the main and sub accounts |
| `vendor/` | Chart library used by the page |
| `sync_positions.ps1`, `sync_subaccount.ps1`, `publish_live_to_github.ps1` | Local scripts that fetch positions and publish snapshots |

Position data is synced from a local computer to this repository; the public page updates automatically. Do not commit API keys, secrets, or `.env` files.

## Viewing locally

Clone or copy this repository and open `index.html` in a browser. The local page and the public page share the same UI.

© Original by 王建中. Public deployment of the desktop “Binance position-building” web page, as-is.
