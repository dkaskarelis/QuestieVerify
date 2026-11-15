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

## ForeverDB data (local build)

The ForeverDB data file isn't in this repository. Build it yourself from the free
[ForeverDB.net Companion addon](https://foreverdb.net/addon) (GPL-3.0 with an attribution term):

```
python tools/build_data.py <path to the ForeverDB addon folder> [<path to questie-forever-fixes>]
```

This writes `Data/ForeverDB.lua`. Without it, QuestieVerify works with its other sources. Note: WoW Forever's own
quest-line table is nearly empty (3 quest lines in client build 1.60.1), so source 1 rarely helps; ForeverDB is the
main source.

QuestieVerify doesn't modify Questie's files. It wraps two Questie functions at runtime, so uninstalling is just
deleting the folder.

## Install

Copy the `QuestieVerify` folder into `World of Warcraft\_forever_\Interface\AddOns\` and restart the game.
Requires Questie. BtWQuests (with BtWQuests: Classic) is optional.

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
