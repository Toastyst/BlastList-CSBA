# Blastlist

A World of Warcraft addon for blacklisting toxic players in Mythic+ dungeons. Tracks players by GUID to prevent re-encounters, detects premade clusters, and automatically rejects blacklisted applicants from LFG listings.

## Features

- **GUID-Based Tracking**: Permanent blacklisting that survives name/realm changes
- **Premade Cluster Detection**: Automatically identifies and associates players who joined your group together
- **Auto-Reject LFG Applicants**: Instantly declines blacklisted players from your dungeon listings
- **Minimap Button**: Clean circular icon with drag, click, and tooltip
- **Data Management**: Export/import blacklists, cleanup old entries
- **Safe-Guard System**: Never blasts friends or guildmates

## Installation

1. Download the latest release from [GitHub](https://github.com/Toastyst/BlastList-CSBA)
2. Extract to `World of Warcraft/_retail_/Interface/AddOns/`
3. Restart WoW or `/reload`
4. Minimap icon appears automatically

## Usage

### Basic Commands
- `/blast` - Blast your current target (shows confirmation popup)
- `/blast check` - Scan your group for blacklisted players
- `/blast list` - Show all blacklisted players
- `/blast cleanup` - Remove entries older than 180 days

### Advanced Commands
- `/blast export` - Generate a shareable export string
- `/blast import [string]` - Import a shared blacklist

### Minimap Button
- **Left-click**: Quick status summary
- **Drag**: Reposition the button
- **Hover**: Detailed tooltip with entry count

## How It Works

When you blast a player, Blastlist:
1. Records their GUID, name, and reason
2. Scans for associates (players who joined within 100ms of them)
3. Adds all to your blacklist
4. Automatically rejects them from future LFG applications

Safe-guards prevent blasting friends or guildmates.

## Data Storage

Blacklists are stored in `BlastListDB` SavedVariable, persisting across sessions and characters.

## Support

Report issues or request features on [GitHub](https://github.com/Toastyst/BlastList-CSBA).

## License

This addon is provided as-is for personal use in World of Warcraft.