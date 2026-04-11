# HCTrade (WoW 1.12.1)

**HCTrade** is a notification tool for WoW 1.12.1 designed to monitor Hardcore chat. It filters messages to identify "WTS" or "WTB" posts and displays a popup alert if the trade falls within the allowed level proximity.

---

## Features

* **Hardcore Chat Filtering**: Scans messages specifically within the Hardcore channel for trade activity.
* **Level Proximity Matching**: Detects level ranges (e.g., "10-20", "25+-", "40±") and triggers an alert if your character is within 5 levels of the trade.
* **One-Click Whispers**: Clicking the player's name in the alert automatically opens a whisper to that sender.
* **Adjustable Layout**: Move and lock the notification area anywhere on your screen using a dedicated anchor.

---

## Installation
1.  Download this repository
2.  Navigate to your WoW directory: `Interface\AddOns`.
3.  Place the `HCTrade` folder into this directory.
4.  Restart the game or reload your UI.

---

## Setup & Controls

The addon automatically attempts to find and monitor a chat tab named **"HC"** upon login.

### Commands

* **`/hct menu`**: Opens the settings panel to toggle sounds and test alerts. |
* **`/hct help`**: Lists the available commands in chat. |
* **`/hct unlock`**: Shows a drag handle to change where alerts appear. |
* **`/hct lock`**: Saves the anchor position and hides the handle. |
* **`/hct test`**: Generates sample alerts to verify your setup. |
* **`/hct status`**: Shows which chat tab is currently being monitored. |
* **`/hct hook #`**: Manually attaches the addon to a specific chat window number. |

---

## Troubleshooting

* **Manual Hooking**: If your Hardcore chat is in a window not named "HC", use `/hct status` to find the correct window number, then use `/hct hook [number]`.
* **Alert Audio**: Sound alerts can be toggled on or off via the graphical menu (`/hct menu`).
