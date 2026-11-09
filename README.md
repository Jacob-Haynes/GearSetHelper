# GearSetHelper

**GearSetHelper** is a lightweight World of Warcraft addon that keeps your equipment sets up to date while you level and gear up. When you equip a new item, it asks which set(s) should get it and updates **only that slot**, so you never have to open the character pane and re-save each set by hand.

It is built for **WoW Forever**, which runs on the modern (Midnight 12.x) addon API. It sticks to APIs that also exist on Retail and the Classic flavours, and the TOC lists their interface versions too, but Forever is the client it targets.

---

## Features

- **Update prompt with set picker:** When you equip a new item, a dialog shows a dropdown of your sets (your active set is preselected), plus `Update Set`, `All Sets` and `Ignore`.
- **Slot-only updates:** Only the newly equipped slot(s) change in the chosen set(s); every other slot keeps what was saved.
  - For the set you're wearing, the set is re-saved straight away.
  - Slots a set ignores stay ignored, so a set that ignores its trinkets never picks up a new one. That set is skipped instead.
  - Two-handers count as both weapon slots. Equipping one empties the off-hand in every set you update, and a new off-hand going into a two-hander set takes your current main hand with it.
  - For a set you're *not* wearing (or `All Sets`), GearSetHelper briefly equips that set, puts the new item back in, saves it, and then puts your original gear back on. A set is saved only after its gear swap has been confirmed. If an item is missing (sold, banked) or the swap fails (for example, full bags), that set is skipped and the reason is printed in chat.
- **No prompt for gear you already own in a set:** Re-equipping an item that is already saved in any of your sets (for example, swapping pieces by hand) doesn't open the prompt. You can turn this off in the settings.
- **Toggle on/off:** Use `/gsh toggle`, a key binding, or the settings panel. Your choice is saved between sessions.
- **Settings panel:** In the game menu, go to *Options → AddOns → GearSetHelper*, or type `/gsh config`.
- **Set swaps don't trigger prompts:** Blizzard set swaps (`EQUIPMENT_SWAP_PENDING` / `EQUIPMENT_SWAP_FINISHED`) are ignored, and so is any change of 4 or more slots at once (ItemRack, Outfitter or macro swaps). Quick ring, trinket and dual-wield changes are grouped (`0.25s`) into one prompt. Taking an item off never opens the prompt.
- **Combat safe:** Nothing happens in combat. A prompt that comes up during a fight waits until combat ends. If a fight starts during an update, the update stops and the gear you were wearing is put back once combat ends.
- **Works with several set managers:** Blizzard Equipment Manager sets, [ItemRack](https://www.curseforge.com/wow/addons/itemrack) sets and [Outfitter](https://www.curseforge.com/wow/addons/outfitter) outfits. ItemRack and Outfitter sets are edited directly, with no gear swapping.

---

## Slash Commands

Use `/gsh` or `/gearsethelper` in-game:

| Command | Description |
| :--- | :--- |
| `/gsh toggle` | Turn update prompts on or off. |
| `/gsh on` / `/gsh off` | Turn update prompts on or off explicitly. |
| `/gsh config` | Open the settings panel (`/gsh options` and `/gsh settings` also work). |
| `/gsh status` | Show whether prompts are on, how many sets were found, and the detected active set. |
| `/gsh test` | Open a test prompt for the Finger 1 slot. Its buttons only say what they would do; nothing is changed. |
| `/gsh create <Name>` | Create a Blizzard equipment set from your current gear. |

## Key Binding

Go to *Options → Key Bindings → AddOns → GearSetHelper*, and bind **Toggle update prompts on/off**. The settings panel shows your current key.

## Settings

| Option | Default | What it does |
| :--- | :--- | :--- |
| Enable update prompts | On | Show the set picker when you equip a new item. |
| Don't prompt for items already in a set | On | Skip the prompt when the equipped item is already saved in any of your sets. Turn this off if you often add an item from one set to another. |
| Show login message | On | Print the "Loaded" line in chat when you log in. |

Settings are stored per account in `GearSetHelperDB`.

---

## Manual Installation

1. Download the latest release zip, or clone this repository.
2. Copy the `GearSetHelper` folder into WoW Forever's `Interface/AddOns` folder. Forever has its own folder, separate from the Classic and Retail ones. To find it, in the Battle.net app, pick WoW Forever, click the gear icon, choose **Show in Explorer** (**Show in Finder** on macOS), and open the Forever folder, then `Interface/AddOns`. CurseForge and the Wago app can also install it.
3. Check that the folder looks like this:
   ```text
   Interface/AddOns/GearSetHelper/
   ├── GearSetHelper.toc
   ├── GearSetHelper.lua
   └── Bindings.xml
   ```
4. Start the game (or `/reload` if you're already logged in), and make sure **GearSetHelper** is enabled in the AddOns list.

The Blizzard Equipment Manager must be on. GearSetHelper turns on the `equipmentManager` CVar at login.

---

## Releasing (GitHub Actions & CurseForge)

`.github/workflows/release.yml` uses [BigWigsMods/packager](https://github.com/BigWigsMods/packager) to build tagged releases and upload them to GitHub Releases and CurseForge. `README.md` is left out of the package (see `.pkgmeta`).

1. The CurseForge project ID (`1791430`) is already in `GearSetHelper.toc` as `## X-Curse-Project-ID`.
2. In the GitHub repository, add a `CF_API_KEY` secret (*Settings → Secrets and variables → Actions*) holding a [CurseForge API token](https://authors.curseforge.com/account/api-tokens).
3. Bump `## Version` in `GearSetHelper.toc`, then push a matching tag:
   ```bash
   git tag v1.1.0
   git push origin v1.1.0
   ```
