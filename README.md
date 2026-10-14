# Auto Farm Premium

Script for **Build A Boat For Treasure** (Chillz Studios).

## Run it

Paste this into your executor:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/tobybt747-ship-it/BABFT-Autofarm/refs/heads/main/loader.lua"))()
```

`loader.lua` is a thin wrapper that fetches `premium.lua` and runs it, so
updates land automatically — re-pasting a 3,000-line script is never needed.

If the raw URL is blocked in your executor, paste the contents of
`loader.lua` directly instead. It falls back to reading `premium.lua` from
your executor's workspace folder if the network path fails.

## Files

| File | What it is |
| --- | --- |
| `premium.lua` | The script. Never paste this directly. |
| `loader.lua` | One-line wrapper that fetches and runs `premium.lua`. |

## Notes

- Safe to re-run. It tears the previous instance down instead of stacking
  connections, flags or UI.
- "Unload Script" on the Dashboard tears it down cleanly.
- Uses the real place IDs. `5374135` is a different game; the main place for
  Build A Boat For Treasure is `537413528`.
- The teleport interval has a hard floor of 2.0s. The server only pays for a
  stage it considers loaded, and that needs ~2 seconds inside it.
