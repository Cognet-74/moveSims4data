# 🏠 Sims 4 Data Transfer Tool 🏠

## What is this? ✨

This tool helps you safely move your precious Sims 4 data from one computer to another without causing chaos! It's perfect for when you:

- 💻 Got a shiny new computer
- 🛠️ Need to reinstall your game
- 🚨 Want to backup your Sims lives (just in case!)

## What it transfers 📦

- 👪 Your saved Sims families and worlds
- 🏘️ Your custom lots and builds (tray files)
- 👗 All your custom content and mods
- 📸 Your screenshots and memories
- ⚙️ Your game options (optional)

## What it WON'T transfer 🚫

Don't worry about breaking your game! This tool is smart enough to avoid transferring system-specific files that could cause problems on your new computer, like:

- Configuration logs
- Cache files
- Game version info
- Other technical stuff that should stay on your old computer

## How to use it 🔧

### First Time Setup:

Never used PowerShell before? No worries! Follow these steps:

1. Download the script (save it as `moveSims4data.ps1`)
2. **Enable PowerShell to run scripts:**
   - Right-click on the Start button and select "Windows PowerShell (Admin)" or "Terminal (Admin)"
   - When the blue window opens, type this command and press Enter:
   ```
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```
   - Type "Y" and press Enter when asked for confirmation
   - This only needs to be done once on your computer!

3. **Run the script:**
   - Navigate to the folder where you saved the script:
   ```
   cd C:\path\to\folder\with\script
   ```
   - Run this command (replace the paths with your own!):
   ```
   .\moveSims4data.ps1 -SourcePath "E:\Documents\Electronic Arts\The Sims 4" -DestinationPath "C:\Users\YourUsername\Documents\Electronic Arts\The Sims 4" -Force
   ```

### Want to see what will happen first? 👀

Add `-WhatIf` to test the transfer without actually moving anything:

```
.\moveSims4data.ps1 -SourcePath "E:\Documents\Electronic Arts\The Sims 4" -DestinationPath "C:\Users\YourUsername\Documents\Electronic Arts\The Sims 4" -Force -WhatIf
```

### Just want to transfer your mods and saves? 🎮

Use these options:

```
.\moveSims4data.ps1 -SourcePath "E:\Documents\Electronic Arts\The Sims 4" -DestinationPath "C:\Users\YourUsername\Documents\Electronic Arts\The Sims 4" -TransferMods -TransferSaves -Force
```

### Want to back up your destination folder first? 🔒

Add `-Backup` to create a backup of your *destination* folder (where you're copying to) before making changes:

```
.\moveSims4data.ps1 -SourcePath "E:\Documents\Electronic Arts\The Sims 4" -DestinationPath "C:\Users\YourUsername\Documents\Electronic Arts\The Sims 4" -Force -Backup
```

This creates a safety copy of your existing destination folder in case anything goes wrong during the transfer.

## Options you can use 🛠️

- `-TransferSaves`: Only transfer save files
- `-TransferMods`: Only transfer mod files
- `-TransferTray`: Only transfer tray files (lots, households, Sims)
- `-TransferScreenshots`: Only transfer screenshot files
- `-TransferOptions`: Transfer Options.ini file
- `-Backup`: Create a backup of your destination folder (not your source folder) first
- `-WhatIf`: Preview what would happen without making changes
- `-Force`: Don't ask for confirmation when replacing files

## Important Tips 💡

- **Close your game** before running this script!
- If something goes wrong, check the console for error messages
- For **HUGE mod collections** (we see you, CC shoppers! 👀), the transfer might take some time - be patient!
- After transfer, start your game and check that everything loaded correctly

## Common Issues & Solutions 🔍

- **"PowerShell says 'running scripts is disabled'"**: Follow the First Time Setup instructions to enable script execution
- **"I'm getting 'Access Denied' errors"**: Make sure you're running PowerShell as Administrator
- **"I don't know where my Sims 4 folder is"**: It's usually in Documents\Electronic Arts\The Sims 4
- **"My game crashes after transfer"**: Try running the game without mods first, then add them back in small batches
- **"My CC isn't showing up"**: Make sure the Mods folder transferred correctly and that mods are enabled in your game settings
- **"My saves aren't appearing"**: Verify that the saves transferred to the correct location

## Troubleshooting PowerShell 🛠️

- **"I can't find PowerShell"**: 
  - Windows 10/11: Right-click Start button → Windows PowerShell or Terminal
  - Older Windows: Search for "PowerShell" in the Start menu

- **"What are these weird terms like 'execution policy'?"**:
  - Windows has security features that prevent running unknown scripts
  - The command we provided temporarily allows YOUR user account to run scripts you've downloaded
  - This is safer than disabling security completely

- **"I'm totally confused by all this computer stuff!"**:
  - Ask a tech-savvy friend to help you run the script
  - Many modders and Sims communities have helpful members who can assist

## For Advanced Users 🧠

The script has additional options for performance tuning and custom file filtering. Check the script header comments if you want to tweak these settings.

---

## Special Thanks ❤️

A huge thank you to Clara for the inspiration behind this tool! After watching her struggle to transfer her heavily modded Sims 4 installation to a new computer (and seeing how heartbreaking it was when things went wrong), this tool was born to make the process smooth and painless for everyone.

Happy Simming! 🎮✨
