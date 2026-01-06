# RX Parameter Loading Logic

The mLRS Ethos tool uses a dynamic, asynchronous approach to manage receiver (RX) parameters. This ensures the UI remains responsive and only displays configuration options that are relevant to the connected hardware.

## 1. Initial Discovery

Upon script startup, the tool executes `requestBasics()` to fetch device identification:
- It requests **Device Items** (names/versions) and **INFO** (link status).
- **RX-Aware Load**: If the link status confirms a receiver is connected (`rx_available == 1`), the script initiates a full load of all parameters (TX and RX).
- **TX-Only Load**: If no receiver is found, it loads only the TX parameters to provide immediate access to the transmitter configuration.

## 2. Parameter Loading Strategy

The `mlrs.lua` API supports a `by_index` strategy with a `skipRx` option:
- **Immediate Requests**: When an index changes or on first request, the script sends immediately without waiting.
- **Retry Threshold**: If no response arrives for the current index, the script waits **100ms** (`REQ_INTERVAL_INDEX_S`) before re-sending the request. This prevents link congestion while allowing recovery from lost packets.
- **Enrichment Handling**: Each param may require multiple frames (`ITEM`, `ITEM2`, `ITEM3`, `ITEM4`) for full enrichment (options, units, etc.). Skipping RX params avoids these extra round-trips when the receiver is offline.

## 3. Dynamic Late-Connection

The script periodically refreshes the link status while the tool is open:
- **Polling**: Every **1.0 second**, `main.lua` calls `pollInfo()` to check the device status via `refreshInfo()`.
- **Connection Detection**: If `rx_available` transitions from `0` to `1`, the script triggers `requestRxParams()`.
- **Cache Invalidation**: RX parameters are cleared from both the API model and local `params` table before re-fetching, ensuring fresh values from the now-connected receiver.
- **Selective Merge**: Newly fetched RX parameters are merged into the existing model, and a UI rebuild is triggered via `dirtyForm = true`.

## 4. Disconnection Handling

If the receiver is disconnected:
- The `pollInfo` loop detects the loss of `rx_available`.
- The UI is flagged as `dirtyForm`, and the subsequent rebuild hides all RX-specific parameters (those with names starting with "Rx "), ensuring the user only sees valid configuration options.
