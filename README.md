# HCTrade (WoW 1.12.1)

**HCTrade** is a notification tool for WoW 1.12.1 designed to monitor Hardcore chat. It filters messages to identify "WTS" or "WTB" posts and displays a popup alert if the trade falls within the allowed level proximity.

---

## Features

* **Hardcore Chat Filtering**: Scans messages specifically within the Hardcore channel for trade activity.
* **Level Proximity Matching**: Detects level ranges (e.g., "10-20", "25+-", "40±", "23+") and triggers an alert if your character is within 5 levels of the trade.
* **Custom Keywords**: Add custom items to watch for (e.g., "armor kit", "wand") with automatic plural/singular matching.
* **Profession Matching**: Alerts when someone needs your profession skills, including crafting requests like "craft my mats".
* **One-Click Whispers**: Click the player's name in the alert to automatically open a whisper to that sender.
* **Right-Click Dismiss**: Right-click anywhere on a popup to dismiss it instantly.
* **Adjustable Popup Duration**: Set how long popups stay on screen (5-30 seconds) with an in-game slider.
* **Adjustable Layout**: Move and lock the notification area anywhere on your screen using a dedicated anchor.
* **Sound Alerts**: Separate sounds for trade notifications and profession requests (can be muted independently).

  <img width="438" height="448" alt="image" src="https://github.com/user-attachments/assets/025f85be-9045-472f-9ece-88f072f6d4b2" />
  <img width="416" height="209" alt="image" src="https://github.com/user-attachments/assets/bea21427-5d61-4db3-8b13-3202782f372c" />
  <img width="273" height="161" alt="image" src="https://github.com/user-attachments/assets/bb668588-86cb-48b5-bbf7-970d7fc05163" />
  <img width="271" height="137" alt="image" src="https://github.com/user-attachments/assets/4a27d623-6d76-4a3c-beea-445c8c1a84fa" />




---

## Installation
1.  Download this repository
2.  Navigate to your WoW directory: `Interface\AddOns`.
3.  Place the `HCTrade` folder into this directory. (remove the `-main` from the folder name if it's there)
4.  Restart the game or reload your UI.

---

## Setup & Controls

The addon automatically attempts to find and monitor a chat tab named **"HC"** upon login.

### Commands

* **`/hct`** or **`/hct menu`**: Opens the settings panel to toggle sounds, adjust popup duration, and manage custom keywords.
* **`/hct help`**: Lists the available commands in chat.
* **`/hct help <command>`**: Shows detailed help for a specific command (e.g., `/hct help ls`).
* **`/hct unlock`**: Shows a drag handle to change where alerts appear.
* **`/hct lock`**: Saves the anchor position and hides the handle.
* **`/hct test`**: Generates sample alerts to verify your setup.
* **`/hct status`**: Shows which chat tab is currently being monitored.
* **`/hct hook #`**: Manually attaches the addon to a specific chat window number.
* **`/hct ls`**: Lists all your custom keywords.
* **`/hct rm #`**: Removes custom keyword number # from your list.
* **`/hct debug`**: Toggles debug mode to see detailed message processing.
* **`/hct sniff`**: Toggles sniff mode to see all raw messages in the hooked chat frame.

---

## Custom Keywords

Add items you're specifically looking for via the in-game menu (`/hct` or `/hct menu`):

1. Type the item name in the input box (e.g., "armor kit")
2. Select the quality color (Common, Uncommon, Rare, Epic, Junk)
3. Click the **+** button to add it

**Features:**
* Automatic plural/singular matching: Adding "armor kit" will match both "armor kit" and "armor kits"
* Duplicate prevention: Can't add "boot" if "boots" already exists (and vice versa)
* Manage your list with `/hct ls` and `/hct rm #`

---

## Profession Matching

The addon detects profession requests in two ways:

1. **Direct mentions**: "LF BS 27+-", "LF tailor", "need enchanter"
2. **Crafting requests**: "craft my mats + tip", "make [Mageweave Bag] your mats"

When someone needs your profession skills, you'll get a notification with a special sound (Tradeskill.ogg).

---

## Troubleshooting

* **Manual Hooking**: If your Hardcore chat is in a window not named "HC", use `/hct status` to find the correct window number, then use `/hct hook [number]`.
* **Alert Audio**: Sound alerts can be toggled on or off via the graphical menu (`/hct menu`). Trade sounds and profession sounds can be muted independently.
* **Custom Keywords Not Triggering**: Make sure your level is within range of the trade message, and enable `/hct debug` to see detailed matching information.
* **Popup Duration**: Adjust how long popups stay visible using the slider in the menu (default: 12 seconds).
