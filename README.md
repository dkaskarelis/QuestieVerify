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

**Pointing to the prerequisite.** When a quest's earlier chain step isn't done, QuestieVerify follows the chain back
to the first quest you can pick up now (step 1 in a chain of steps 1, 2 and 3):

- The later steps (2 and 3) keep their marker, drawn as a **red "!"**. Its tooltip says what to do first, for example
  "Step 3 is locked: first pick up Step 1 from Gryan Stoutmantle in Westfall". When step 1 is in your quest log it
  says to hand it in; when step 1 needs a higher level it says which level.
- Step 1 gets a normal "!" (QuestieVerify draws one if Questie doesn't), and its tooltip says
  "Step 1 unlocks Step 2, Step 3".
- When you hand in step 1, step 2's marker turns normal and step 3's red marker points to step 2.
- When the step to do first is at the **same NPC**, the later steps' markers are hidden instead: that NPC already
  shows the "!" for the step it will give you.

A previous step counts once it's handed in, not while it's in your log. QuestieVerify only does this for quests
Questie would otherwise show: when Questie already knows the chain, it shows only step 1, as usual.
`/qv redirect off` hides blocked quests instead.

**Automatic scans.** Each zone you enter is scanned quietly (no chat output) and saved in the SavedVariables file, so
`/qv scan` is only needed to see the summary in chat.

## Prerequisites

| What | Needed? | Where to get it |
|---|---|---|
| World of Warcraft: Forever on Windows | Required | |
| [Questie](https://github.com/Questie/Questie) | Required | CurseForge or Wago app (search "Questie") |
| [ForeverDB addon](https://foreverdb.net/addon) | Strongly recommended: its quest data catches most wrong markers | CurseForge or Wago app (search "ForeverDB"), or the zip from foreverdb.net |
| BtWQuests + BtWQuests: Classic | Optional | CurseForge or Wago app |
| [questie-forever-fixes](https://github.com/xelblch/questie-forever-fixes) | Optional, adds 76 community prerequisites | GitHub |

Nothing else is needed: the installer uses only what comes with Windows 10 and 11.

## Install

1. Install **Questie** and the **ForeverDB** addon (the CurseForge or Wago app is easiest).
2. On this GitHub page, click the green **Code** button, then **Download ZIP**.
3. Open your Downloads folder, right-click the ZIP and choose **Extract All...**, then **Extract**.
4. In the extracted folder, double-click **Install QuestieVerify**.
   - If Windows shows "Windows protected your PC", click **More info**, then **Run anyway**. Windows shows this
     for any file downloaded from the internet that isn't from a big publisher.
   - It finds WoW Forever by itself. If it can't, a window asks you to pick your World of Warcraft folder.
   - If WoW is in Program Files, Windows may ask whether to allow changes: click **Yes**. The install then
     carries on in a second window; the first one can be closed with any key.
5. When it says **Done!**, close the window (press any key, or Enter in the second window). Then quit WoW
   completely and start it again (not just `/reload`). Type `/qv` in game to see the commands.

**When ForeverDB updates**, QuestieVerify says so in chat once. Double-click **Install QuestieVerify** again to
refresh its copy of the data. The installer only reads ForeverDB's files, so you can switch the ForeverDB addon off in
game if you don't want it running; the update reminder still works, as long as ForeverDB stays installed.

**Uninstall:** delete `Interface\AddOns\QuestieVerify`. Questie's own files are never changed.

## About the ForeverDB data

The data file (`Data/ForeverDB.lua`) isn't in this repository: the installer (`tools/install.ps1`) builds it on your
PC from your ForeverDB addon. ForeverDB's data is GPL-3.0 with an attribution term. WoW Forever's own quest-line table
is nearly empty (3 quest lines in client build 1.60.1), so ForeverDB is the main source.

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
| `/qv redirect on\|off` | Show blocked quests as red markers that point to the quest to do first (off: hide them) |
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
