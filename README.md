# mLRS Ethos Tool

A streamlined Lua configuration tool for **Ethos transmitters** to manage **mLRS ** devices over CRSF.

---

## 🚀 Features

- 📡 **Direct Integration**: Communicates via CRSF telemetry using the mBridge layer.
- 🧱 **Dynamic UI**: Automatically builds configuration fields from device parameter descriptors.
- 🔄 **Smart Loading**: Loads parameters on-demand (50Hz polling) and handles RX connection changes dynamically.
- 🛠️ **Dev Friendly**: Includes VS Code automation for fast deployment and simulator testing.

---

## 🕹️ Installation

1. Create a folder named `mlrs` in your radio's `/scripts/` directory.
2. Copy the following files from the `src/mlrs/` directory of this repo into that folder:
   - `main.lua`
   - `mlrs.lua` (API Library)
   - `icon.png`
3. Resulting path: `RADIO:/scripts/mlrs/main.lua`

**Usage**:
- In Ethos 1.7+, the script will appear automatically under **Model → MLRS**.
- For Ethos 1.6 and earlier, use the **crsf** in **External RF**, the script will be available as a **System Tool**.

---

## 💾 Saving & Rebooting

- **Save**: Tap **Save Params** to write changes to module flash. A 3-second safety "dead-time" is enforced during the write.
- **Auto-Reload**: The tool periodically polls for the receiver. If you power-cycle the RX, it will detect the connection and reload RX parameters automatically.

---

## 🧑‍💻 Development

The project includes a robust `.vscode` automation suite:
- **Deploy**: Fast MD5-based deployment to radio or simulator.
- **Debug**: Integrated serial log tailing.
- **I18n**: Pre-configured scripts for internationalization support.

---

## 📜 License & Credits

- **License**: GPL-3.0 © 2026 Rob Thomson
