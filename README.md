# QuestieVerify

A small companion add-on for [Questie](https://github.com/Questie/Questie) on **World of Warcraft: Forever**.

Questie puts a "!" on the map for every quest its database thinks you can take. When the database is missing a
prerequisite (common for quest chains that Forever changed or added) or lists the wrong quest giver, you travel there
and find nothing. QuestieVerify checks each "!" before Questie draws it and hides or dims the ones you can't take yet.

## How it decides

0. **ForeverDB.net data** (optional, built locally, see below): whether the quest is for your side, race and class,
   its prerequisites, exclusive quests, characters its giver doesn't offer it to, and which NPC players actually got it
   from (a quest giver Questie lists that players never got it from is dropped). Plus the community prerequisite list
   from [questie-forever-fixes](https://github.com/xelblch/questie-forever-fixes).
1. **The game's own quest-line data** (`C_QuestLine`). If the quest is a step in a quest line and the step before it
   isn't completed or in your quest log, its "!" is hidden.
2. **BtWQuests chains** (optional). The same check, for quests that aren't in a game quest line and that Questie has no
   prerequisite for.
3. **What NPCs actually offer.** When you talk to a quest giver, every quest Questie expected there that the NPC
   doesn't offer is hidden at that NPC for that character. It comes back dimmed after 2 levels, or straight away when
   the NPC offers it. If you then pick the quest up somewhere else, the NPC is remembered on all your characters as a
   wrong quest giver.
4. **Optional dimming** of markers whose evidence is unclear.

**Pointing to the prerequisite.** A quest hidden because a step before it isn't done doesn't just vanish: QuestieVerify
follows the chain back to the first quest you can pick up now, makes sure that quest has a "!" (drawing one if Questie
doesn't), and adds "QuestieVerify: <quest> unlocks <quest>" to its map tooltip. If that step is already in your quest
log, or needs a higher level, `/qv why` says so. A previous step counts once it's handed in, not while it's in your log.

**Automatic scans.** Each zone you enter is scanned quietly (no chat output) and saved in the SavedVariables file, so
`/qv scan` is only needed to see the summary in chat.

## Prerequisites

| What | Needed? | Where to get it |
|---|---|---|
| World of Warcraft: Forever | Required | |
| [Questie](https://github.com/Questie/Questie) | Required | CurseForge or Wago (search "Questie") |
| [ForeverDB addon](https://foreverdb.net/addon) | Strongly recommended: its quest data catches most wrong markers | CurseForge or Wago (search "ForeverDB"), or the zip from foreverdb.net |
| [Python 3](https://www.python.org/downloads/) | Needed to run the installer, which builds the ForeverDB data | python.org (tick "Add Python to PATH") |
| BtWQuests + BtWQuests: Classic | Optional | CurseForge or Wago |
| [questie-forever-fixes](https://github.com/xelblch/questie-forever-fixes) | Optional, adds 76 community prerequisites | GitHub |

## Install

1. Install **Questie** and the **ForeverDB** addon in WoW Forever (CurseForge or Wago is easiest).
2. Download QuestieVerify: on GitHub, click **Code > Download ZIP**, then extract it anywhere.
3. Open the extracted folder, click the address bar, type `cmd` and press Enter. In the window that opens, run:

   ```
   python install.py
   ```

   If WoW isn't in `C:\Program Files\World of Warcraft`, add its `_forever_` folder:
   `python install.py "D:\Games\World of Warcraft\_forever_"`
   If it says "Access is denied", open the command window as administrator and run it again.
4. Restart WoW completely (not just `/reload`). Type `/qv` in game to see the commands.

After ForeverDB updates, run `python install.py` again to refresh the data. You can turn the ForeverDB addon off in
game if you don't want it running: the installer only reads its files.

**Without Python:** rename the extracted folder from `QuestieVerify-main` to `QuestieVerify` and copy it into `World of Warcraft\_forever_\Interface\AddOns\`. It works,
but without ForeverDB's data (only the game's quest lines, BtWQuests and what NPCs offer).

**Uninstall:** delete `Interface\AddOns\QuestieVerify`. Questie's own files are never changed.

## About the ForeverDB data

The data file (`Data/ForeverDB.lua`) isn't in this repository: the installer builds it on your PC from your ForeverDB
addon with `tools/build_data.py`. ForeverDB's data is GPL-3.0 with an attribution term. WoW Forever's own quest-line
table is nearly empty (3 quest lines in client build 1.60.1), so ForeverDB is the main source.

## Commands

| Command | What it does |
|---|---|
| `/qv scan` | Test the current zone: which quests each data source covers |
| `/qv scan all` | The same for every quest Questie shows |
| `/qv why <questID>` | Why a quest's marker is shown, dimmed or hidden |
| `/qv dim off\|uncertain\|unverified` | Dimming: off, only unclear cases (default), or also quests no source can confirm |
| `/qv learn on\|off` | Learn from what NPCs offer |
| `/qv chains on\|off` | Use quest-chain data |
| `/qv foreverdb on\|off` | Use the local ForeverDB data |
| `/qv redirect on\|off` | Point blocked quests to the prerequisite to do first |
| `/qv autoscan on\|off` | Quietly record a scan of each zone you enter |
| `/qv revisit <n>` | Levels before a "not offered here" marker comes back dimmed |
| `/qv forget <questID>` / `/qv forget all` | Forget what was learned |
| `/qv refresh` | Re-check every marker now |

Turn on Questie → Advanced → Show Quest IDs to see quest IDs in Questie's tooltips.

## Credits

- Quest data and map markers: [Questie](https://github.com/Questie/Questie) and QuestieDB.
- Optional chain data: [BtWQuests](https://www.curseforge.com/wow/addons/btw-quests).
- Quest data: <a href="https://foreverdb.net">Data from ForeverDB.net</a>, from the ForeverDB.net Companion addon
  (GPL-3.0 with an attribution term). Wherever the add-on shows information based on ForeverDB data (`/qv why`,
  `/qv scan`, `/qv help`), it prints "Data from ForeverDB.net (https://foreverdb.net)" next to it.
- Community prerequisites: [xelblch/questie-forever-fixes](https://github.com/xelblch/questie-forever-fixes) (MIT).

Not affiliated with Blizzard Entertainment, the Questie team, BtWQuests or ForeverDB.

## License

MIT
