"""Install QuestieVerify into WoW Forever, with ForeverDB data built from your installed ForeverDB addon.

Usage (from this folder):
    python install.py                      # finds WoW Forever in the default place
    python install.py "D:\\Games\\World of Warcraft\\_forever_"   # or tell it where WoW Forever is

What it does:
  1. Finds your WoW Forever AddOns folder and checks that Questie is installed.
  2. If the ForeverDB addon is installed there, builds QuestieVerify's data file from it
     (Data from ForeverDB.net, https://foreverdb.net). If QuestieForeverFixes is installed, its fixes are added too.
  3. Copies QuestieVerify into the AddOns folder.
Run it again after ForeverDB updates to refresh the data.
"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FILES = ["QuestieVerify.toc", "QuestieVerify.lua", "README.md", "LICENSE"]
DEFAULT_ROOTS = [
    r"C:\Program Files\World of Warcraft\_forever_",
    r"C:\Program Files (x86)\World of Warcraft\_forever_",
    r"D:\World of Warcraft\_forever_",
    r"D:\Games\World of Warcraft\_forever_",
]


def fail(msg):
    print("\nERROR: " + msg)
    sys.exit(1)


def find_addons(arg):
    candidates = [arg] if arg else DEFAULT_ROOTS
    for root in candidates:
        if not root:
            continue
        for path in (os.path.join(root, "Interface", "AddOns"), root):
            if os.path.isdir(path) and os.path.basename(path).lower() == "addons":
                return path
    if arg:
        fail('No AddOns folder found under "%s". Point to your _forever_ folder.' % arg)
    fail("Couldn't find WoW Forever. Run again with its folder, for example:\n"
         '  python install.py "C:\\Program Files\\World of Warcraft\\_forever_"')


def main():
    addons = find_addons(sys.argv[1] if len(sys.argv) > 1 else None)
    print("WoW Forever AddOns folder: " + addons)

    if not os.path.isdir(os.path.join(addons, "Questie")):
        fail("Questie isn't installed. Install Questie for WoW Forever first (CurseForge or Wago), then run this again.")
    print("  Questie: found")

    data_file = os.path.join(HERE, "Data", "ForeverDB.lua")
    fdb = os.path.join(addons, "ForeverDB")
    if os.path.isfile(os.path.join(fdb, "ForeverDB.toc")):
        print("  ForeverDB addon: found, building QuestieVerify's data from it")
        cmd = [sys.executable, "-I", os.path.join(HERE, "tools", "build_data.py"), fdb]
        qff = os.path.join(addons, "QuestieForeverFixes")
        cmd.append(qff if os.path.isfile(os.path.join(qff, "Fixes.lua")) else "")
        cmd.append(data_file)
        if subprocess.call(cmd) != 0:  # (an empty questie-forever-fixes path means none)
            fail("Building the data failed (see above).")
    elif os.path.isfile(data_file):
        print("  ForeverDB addon: not installed; keeping the data file already in this folder")
    else:
        print("  ForeverDB addon: not installed. QuestieVerify will work, but without ForeverDB's quest data,\n"
              "  which is what catches most wrong markers. Install the free ForeverDB addon\n"
              "  (https://foreverdb.net/addon, or 'ForeverDB' on CurseForge/Wago) and run this again.")

    target = os.path.join(addons, "QuestieVerify")
    os.makedirs(os.path.join(target, "Data"), exist_ok=True)
    for name in FILES:
        src = os.path.join(HERE, name)
        if os.path.isfile(src):
            shutil.copy2(src, os.path.join(target, name))
    if os.path.isfile(data_file):
        shutil.copy2(data_file, os.path.join(target, "Data", "ForeverDB.lua"))
    print("\nInstalled QuestieVerify to " + target)
    print("Restart WoW completely (not just /reload). Type /qv in game for the commands.")


if __name__ == "__main__":
    main()
