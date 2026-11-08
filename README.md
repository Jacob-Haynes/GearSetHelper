# GearSetHelper

**GearSetHelper** is a lightweight World of Warcraft (Retail / 11.x) addon designed to streamline equipment set management while leveling or gearing up. Whenever you equip a new piece of gear, GearSetHelper prompts you with a native confirmation dialogue to automatically update your active equipment set or all configured sets—eliminating the need to open the Character Pane and manually overwrite each set.

---

## Features

- **Automatic Equipment Change Detection:** Listens for individual gear changes and prompts to update your sets (`Active Set`, `All Sets`, or `Ignore`).
- **Smart Set Swap & Dual-Wield Filtering:** Ignores full equipment set swaps (`EQUIPMENT_SWAP_PENDING` / `EQUIPMENT_SWAP_FINISHED`) and debounces rapid dual-wield, ring, or trinket swaps (`0.25s`) into a single prompt.
- **Combat Lockdown Safe:** Respects `InCombatLockdown()`. Prompts and equipment set mutations are suppressed during combat and automatically queued until combat ends (`PLAYER_REGEN_ENABLED`).
- **Zero-Config Persistence:** Remembers your enabled/disabled preference across sessions via `GearSetHelperDB`.

---

## Slash Commands

Use `/gsh` or `/gearsethelper` in-game:

| Command | Description |
| :--- | :--- |
| `/gsh toggle` | Enable or disable equipment set update prompts. |
| `/gsh status` | Show current addon state, total configured sets, and detected active set. |

---

## Manual Installation

1. Download the latest release zip or clone this repository.
2. Copy the `GearSetHelper` folder into your World of Warcraft Retail `AddOns` directory:
   - **Windows:** `C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\GearSetHelper`
   - **macOS:** `/Applications/World of Warcraft/_retail_/Interface/AddOns/GearSetHelper`
3. Verify the folder structure matches:
   ```text
   Interface/AddOns/GearSetHelper/
   ├── GearSetHelper.toc
   ├── GearSetHelper.lua
   └── README.md
   ```
4. Launch World of Warcraft (or run `/reload` if already logged in) and ensure **GearSetHelper** is enabled in the AddOns list.

---

## GitHub Actions & CurseForge Release Setup

This repository includes an automated release workflow (`.github/workflows/release.yml`) powered by [BigWigsMods/packager](https://github.com/BigWigsMods/packager) that builds and uploads tagged releases directly to GitHub Releases and CurseForge.

### 1. Create a CurseForge Project & API Token
1. Create a new World of Warcraft addon project on [CurseForge Authors Console](https://authors.curseforge.com/).
2. Copy your **Project ID** from the project overview page and add it to `GearSetHelper.toc`:
   ```toc
   ## X-Curse-Project-ID: YOUR_PROJECT_ID
   ```
3. Generate a CurseForge API token at [CurseForge API Tokens](https://authors.curseforge.com/account/api-tokens).

### 2. Configure GitHub Repository Secrets
In your GitHub repository, navigate to **Settings → Secrets and variables → Actions** and add:
- `CF_API_KEY`: Your CurseForge API token.

### 3. Trigger a Release
Push a version tag matching `v*` (e.g., `v1.0.0`):
```bash
git tag v1.0.0
git push origin v1.0.0
```
GitHub Actions will automatically package the addon, create a GitHub Release with the `.zip` archive, and publish the build to CurseForge.
