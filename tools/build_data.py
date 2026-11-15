"""Build QuestieVerify's local data file (Data/ForeverDB.lua) from:

  * the ForeverDB.net Companion addon (https://foreverdb.net/addon): its Data/*.lua files.
    Data from ForeverDB.net (https://foreverdb.net). GPL-3.0 with an attribution term (see its NOTICE.txt).
  * xelblch/questie-forever-fixes (https://github.com/xelblch/questie-forever-fixes), MIT.

The output is for personal use and is not committed to the QuestieVerify repository (.gitignore).

Usage: python build_data.py <ForeverDB addon folder> [<questie-forever-fixes folder>] [<output file>]
"""
import os
import re
import sys

LUA_STR = r'"((?:[^"\\]|\\.)*)"'


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def block(src, name):
    """The text of `ns.<name> = { ... }` (top level, one entry per line)."""
    m = re.search(r"^ns\." + re.escape(name) + r"\s*=\s*\{", src, re.M)
    if not m:
        raise SystemExit("ns.%s not found" % name)
    end = src.find("\n}", m.end())
    return src[m.end():end]


def string_entries(src, name):
    out = {}
    for m in re.finditer(r"^\[(\d+)\]=" + LUA_STR, block(src, name), re.M):
        out[int(m.group(1))] = m.group(2)
    return out


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def unpoint(tok):
    try:
        v = int(tok, 36)
    except ValueError:
        return None
    return v // 1000000


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    fdb_dir = sys.argv[1]
    if os.path.isdir(os.path.join(fdb_dir, "ForeverDB")):
        fdb_dir = os.path.join(fdb_dir, "ForeverDB")
    qff_dir = sys.argv[2] if len(sys.argv) > 2 else None
    here = os.path.dirname(os.path.abspath(__file__))
    out_path = sys.argv[3] if len(sys.argv) > 3 else os.path.join(here, "..", "Data", "ForeverDB.lua")
    data = os.path.join(fdb_dir, "Data")

    toc = read(os.path.join(fdb_dir, "ForeverDB.toc"))
    version = re.search(r"^## Version:\s*(\S+)", toc, re.M).group(1)
    qf_src = read(os.path.join(data, "QuestForever.lua"))
    qc_src = read(os.path.join(data, "QuestClassic.lua"))
    build = re.search(r"build (\S+?)\.\s", qf_src).group(1)

    qf = string_entries(qf_src, "qfQuests")
    qc = string_entries(qc_src, "qcQuests")

    def spots(name):
        out = {}
        for m in re.finditer(r'^\[(\d+)\]=\{s="([^"]*)"', block(qf_src, name), re.M):
            maps = sorted({unpoint(t) for t in m.group(2).split() if unpoint(t)})
            if maps:
                out[int(m.group(1))] = maps
        return out

    seen_maps = spots("qfSeen")
    poi_maps = spots("qfPoi")

    gone = {int(m.group(1)) for m in re.finditer(r"^\[(\d+)\]=1", block(qc_src, "qcGone"), re.M)}
    excl = string_entries(qc_src, "qcExcl")

    offers = {}
    for m in re.finditer(r"^\[(\d+)\]=\{(.*)\},?$", block(read(os.path.join(data, "QuestOffers.lua")), "questOffers"), re.M):
        offers[int(m.group(1))] = re.findall(LUA_STR, m.group(2))

    trainers = {}
    npcs_src = read(os.path.join(data, "NPCs.lua"))
    m = re.search(r"^ns\.classTrainers\s*=\s*\{(.*)\}\s*$", npcs_src, re.M)
    if m:
        for cls, ids in re.findall(r"([A-Z]+)=\{([\d,\s]*)\}", m.group(1)):
            trainers[cls] = [int(x) for x in re.findall(r"\d+", ids)]

    # Merge Classic + Forever the way the ForeverDB addon does (QuestData.lua Q.quest): Forever wins for what it has.
    rows = {}
    for qid in sorted(set(qf) | set(qc)):
        side, races, classes, need_all, need_any, ex, starts, ssrc = "", 0, 0, "", "", 0, "", ""
        after, by, new, seen_min, min_lv = 0, 0, 0, 0, 0
        if qid in qc:
            f = qc[qid].split("|")
            min_lv = int(f[2] or 0)
            side, classes, races = f[3], int(f[4] or 0), int(f[5] or 0)
            need_all, need_any, ex = f[6], f[7], int(f[8] or 0)
            starts, ssrc = f[9], "c"
        if qid in qf:
            f = qf[qid].split("|")
            if int(f[2] or 0) > 0:
                min_lv = int(f[2])
            if f[4].strip():
                starts, ssrc = f[4], "s"
            by = int(f[6] or 0)
            new = 1 if f[7] == "1" else 0
            after = int(f[8] or 0)
            seen_min = int(f[9] or 0)
            if side == "" and f[10] in ("a", "h"):
                side = f[10]
        omaps = seen_maps.get(qid) or poi_maps.get(qid) or []
        osrc = "s" if qid in seen_maps else ("p" if qid in poi_maps else "")
        rows[qid] = [side, races, classes, need_all.strip(), need_any.strip(), ex, after, starts.strip(), ssrc,
                     1 if (qid in gone and qid not in qf) else 0, by, new, " ".join(str(x) for x in omaps), osrc,
                     min_lv, seen_min, 1 if qid in qf else 0]

    # questie-forever-fixes: manual (Fixes.lua) wins over generated (Generated.lua)
    qff = {}
    if qff_dir:
        for fname in ("Generated.lua", "Fixes.lua"):
            src = read(os.path.join(qff_dir, fname))
            for m in re.finditer(r"\[(\d+)\]\s*=\s*\{", src):
                depth, i = 1, m.end()
                while depth and i < len(src):
                    depth += {"{": 1, "}": -1}.get(src[i], 0)
                    i += 1
                body = src[m.end():i - 1]
                single = re.search(r"preQuestSingle\s*=\s*\{([\d,\s]*)\}", body)
                group = re.search(r"preQuestGroup\s*=\s*\{([\d,\s]*)\}", body)
                if single or group:
                    qff[int(m.group(1))] = (
                        " ".join(re.findall(r"\d+", single.group(1))) if single else "",
                        " ".join(re.findall(r"\d+", group.group(1))) if group else "",
                    )

    lines = [
        "-- Data from ForeverDB.net (https://foreverdb.net), ForeverDB Companion %s, client build %s." % (version, build),
        "-- ForeverDB.net's data is GPL-3.0 with an attribution term: credit \"Data from ForeverDB.net (https://foreverdb.net)\".",
        "-- Community prerequisites from xelblch/questie-forever-fixes (https://github.com/xelblch/questie-forever-fixes), MIT.",
        "-- Generated by tools/build_data.py for personal use. Do not edit by hand.",
        "local _, ns = ...",
        "ns.fdb = { version = %s, build = %s }" % (lua_str(version), lua_str(build)),
        "-- [quest] = { side, races mask, classes mask, needs all, needs one of, exclusive group, offered after,",
        "--   starts, starts source (s players, c Classic), gone, players who saw it, new in Forever,",
        "--   uiMaps where offered, those maps' source (s players, p client), min level, lowest level seen completing, in Forever data }",
        "ns.fdb.quests = {",
    ]
    for qid, r in rows.items():
        lines.append("[%d]={%s}," % (qid, ",".join(lua_str(v) if isinstance(v, str) else str(v) for v in r)))
    lines.append("}")
    lines.append("-- [quest] = rules of who it is NOT offered to: \"side;CLASS;Race\", empty = any")
    lines.append("ns.fdb.offers = {")
    for qid in sorted(offers):
        lines.append("[%d]={%s}," % (qid, ",".join(lua_str(s) for s in offers[qid])))
    lines.append("}")
    lines.append("ns.fdb.excl = {")
    for g in sorted(excl):
        lines.append("[%d]=%s," % (g, lua_str(excl[g])))
    lines.append("}")
    lines.append("ns.fdb.trainers = {")
    for cls in sorted(trainers):
        lines.append("%s={%s}," % (cls, ",".join(str(x) for x in trainers[cls])))
    lines.append("}")
    lines.append("-- [quest] = { preQuestSingle (one of), preQuestGroup (all) }")
    lines.append("ns.qff = {")
    for qid in sorted(qff):
        lines.append("[%d]={%s,%s}," % (qid, lua_str(qff[qid][0]), lua_str(qff[qid][1])))
    lines.append("}")

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("ForeverDB %s (build %s): %d quests (%d in Forever data), %d offer rules, %d exclusive groups; "
          "questie-forever-fixes: %d -> %s" % (version, build, len(rows), sum(1 for r in rows.values() if r[16]),
                                             len(offers), len(excl), len(qff), os.path.abspath(out_path)))


if __name__ == "__main__":
    main()
