# HCTrade (WoW 1.12.1)

**HCTrade** is a notification tool for WoW 1.12.1 designed to monitor Hardcore and Guild chat. It filters messages to identify "WTS", "WTB", or "WTT" posts and displays a popup alert if the trade falls within your level proximity.

---

<img width="450" height="605" alt="image" src="https://github.com/user-attachments/assets/86d2beb8-c76f-4813-9a5b-4b08194ac846" />
<img width="246" height="143" alt="image" src="https://github.com/user-attachments/assets/ff9b1445-04f1-4c7e-b870-636e6dfb4948" />
<img width="306" height="163" alt="image" src="https://github.com/user-attachments/assets/85354716-4e37-472d-8ea5-5bda9b047433" />



## Features

* **Hardcore Chat Filtering**: Scans messages in the Hardcore channel for trade activity.
* **Guild Chat Filtering**: Independently monitors guild chat via the `CHAT_MSG_GUILD` event. Works regardless of which chat tabs display guild chat — no duplicate notifications even if guild is shown in multiple tabs, and no chat tab setup required.
* **Three-Tier Notification Toggle**: Master "Notifications" switch plus independent "Hardcore Notifications" and "Guild Notifications" sub-toggles. Disabling the master grays out and locks both sub-toggles.
* **Level Proximity Matching**: Detects level ranges (e.g., "10-20", "25+-", "40±", "23+") and triggers an alert if your character is within 5 levels of the trade. The same level filtering applies to both Hardcore and Guild messages.
* **Custom Keywords**: Add custom items to watch for (e.g., "armor kit", "wand") with automatic plural/singular matching and color-coded display.
* **Item Color Coding**: Items you own (in bags or bank) automatically display in their quality colors (green/blue/purple/etc) in popups.
* **Profession Matching**: Alerts when someone needs your profession skills, including crafting requests like "craft my mats".
* **Inventory Alerts**: Get notified when someone wants to buy items you have in your bags or bank (shows location: "In Bags", "In Bank", or "Bags + Bank").
* **WTB Filtering**: Optional filter to only show WTB messages if you own at least one of the mentioned items.
* **Bank Scanning**: Automatically scans your bank when opened and caches the items - alerts work even when bank is closed.
* **One-Click Whispers**: Click the player's name in the alert to automatically open a whisper to that sender.
* **Right-Click Dismiss**: Right-click anywhere on a popup to dismiss it instantly.
* **ESC to Clear All**: Press ESC while popups are visible to dismiss the entire stack at once.
* **Adjustable Popup Duration**: Set how long popups stay on screen (5-30 seconds) with an in-game slider.
* **Adjustable Layout**: Move and lock the notification area anywhere on your screen using a dedicated anchor.
* **Sound Alerts**: Separate sounds for trade notifications (WTS), WTB/WTT inventory matches, and profession requests — each can be muted independently.
* **Class-Colored Sender Names**: Sender names in popups are colored by class when known (cached from friends list, guild roster, party, raid, target, mouseover, and /who results).



---

## Installation
1.  Download this repository
2.  Navigate to your WoW directory: `Interface\AddOns`.
3.  Place the `HCTrade` folder into this directory. (remove the `-main` from the folder name if it's there)
4.  Restart the game or reload your UI.

---

## Setup & Controls

**Hardcore chat** is monitored by hooking a chat frame tab named **"HC"**, which the addon attempts to find automatically on login. If your HC chat is in a tab with a different name, use `/hct status` and `/hct hook #` to point it manually.

**Guild chat** is monitored independently through the game's `CHAT_MSG_GUILD` event. It does not depend on any chat tab, so no setup is required — it works as long as you're in a guild and "Guild Notifications" is enabled in the menu.

### Notification Toggles

The settings menu (`/hct menu`) has three notification checkboxes:

* **Notifications** (master) — Disables all popups and sounds from both Hardcore and Guild. When off, the two sub-toggles are grayed out and locked.
* **Hardcore Notifications** — Enables/disables the Hardcore channel monitor independently.
* **Guild Notifications** — Enables/disables the Guild chat monitor independently.

Background scans (inventory, level cache, profession detection) keep running while notifications are disabled, so re-enabling is instant. `/hct test` always works regardless of the toggle state.

### Commands

* **`/hct`** or **`/hct menu`**: Opens the settings panel to toggle sounds, manage notification toggles, adjust popup duration, and manage custom keywords.
* **`/hct help`**: Lists the available commands in chat.
* **`/hct help <command>`**: Shows detailed help for a specific command (e.g., `/hct help ls`).
* **`/hct unlock`**: Shows a drag handle to change where alerts appear.
* **`/hct lock`**: Saves the anchor position and hides the handle.
* **`/hct test`**: Generates sample alerts to verify your setup.
* **`/hct status`**: Shows which chat tab is currently being monitored for HC.
* **`/hct hook #`**: Manually attaches the HC monitor to a specific chat window number.
* **`/hct ls`**: Lists all your custom keywords.
* **`/hct rm #`**: Removes custom keyword number # from your list.
* **`/hct cache`**: Shows how many players are in the level cache.
* **`/hct cache clear`**: Wipes the level cache.
* **`/hct on`** / **`/hct off`** / **`/hct toggle`**: Toggle the master Notifications switch.
* **`/hct debug`**: Toggles debug mode to see detailed message processing.
* **`/hct sniff`**: Toggles sniff mode to see all raw messages in the hooked HC chat frame.

---

## Custom Keywords

Add items you're specifically looking for via the in-game menu (`/hct` or `/hct menu`):

1. Type the item name in the input box (e.g., "armor kit")
2. Select the quality color (Common, Uncommon, Rare, Epic, Junk)
3. Click the **+** button to add it

**Features:**
* **Color-coded alerts**: Your keyword will display in the chosen color in popups (e.g., add "wand" as green, and all wand mentions will show in green)
* Automatic plural/singular matching: Adding "armor kit" will match both "armor kit" and "armor kits"
* Duplicate prevention: Can't add "boot" if "boots" already exists (and vice versa)
* Manage your list with `/hct ls` and `/hct rm #`

**Note**: Custom keywords trigger notifications and display in your chosen color, even for items you don't own. This is a great way to color items that don't appear in your inventory.

---

## Item Color Coding

Items you own (in bags or bank) automatically display in their quality colors:
* **Gray** - Poor quality items
* **White** - Common items
* **Green** - Uncommon items
* **Blue** - Rare items
* **Purple** - Epic items

**How it works:**
* When someone posts an item in HC or guild chat, the addon scans your bags/bank for that item
* If found, it reads the item's quality color from the tooltip and caches it permanently
* Colors persist across sessions (saved in WTF folder)
* Items you don't own will display in white (in HC), or in their original color codes (in guild chat, since guild messages preserve item link colors)

**Note on HC vs Guild**: The HC chat addon strips item link color data before HCTrade can access it, so HC items need to be matched against your bags. Guild chat preserves item link colors natively, so guild item links display correctly even for items you don't own.

**Workaround for HC**: Use custom keywords to manually color items you're interested in but don't own.

---

## WTB Filtering

Enable "Only show WTB/WTT items you own" in the settings menu (`/hct menu`) to filter WTB messages:

* **Enabled**: Only see WTB messages if you own at least one of the mentioned items
* **Disabled** (default): See all WTB messages in your level range

WTS messages are never filtered - you always see those.

---

## Profession Matching

The addon detects profession requests in two ways:

1. **Direct mentions**: "LF BS 27+-", "LF tailor", "need enchanter"
2. **Crafting requests**: "craft my mats + tip", "make [Mageweave Bag] your mats"

When someone needs your profession skills, you'll get a notification with a special sound (Tradeskill.ogg). Profession matching works in both Hardcore and Guild chat.

---

## Troubleshooting

* **Manual HC Hooking**: If your Hardcore chat is in a window not named "HC", use `/hct status` to find the correct window number, then use `/hct hook [number]`.
* **Guild Chat Not Triggering**: Make sure "Guild Notifications" is enabled in the menu and the master "Notifications" toggle is on. Guild monitoring uses the game event directly and doesn't depend on chat tabs, so there's nothing to "hook" for guild.
* **Alert Audio**: Sound alerts can be toggled on or off via the graphical menu (`/hct menu`). WTS sound, WTB/WTT (inventory) sound, and Profession sound can be muted independently.
* **Custom Keywords Not Triggering**: Make sure your level is within range of the trade message, and enable `/hct debug` to see detailed matching information.
* **Popup Duration**: Adjust how long popups stay visible using the slider in the menu (default: 12 seconds).
* **Items Showing in White (HC)**: Only items you own (in bags or bank) can be colored automatically in HC chat. Items you don't own will show in white. Use custom keywords to manually color important items.
* **Bank Items Not Alerting**: Make sure "WTB/WTT sound" is enabled in settings. Open your bank at least once to scan and cache bank items - the cache persists when the bank is closed.
