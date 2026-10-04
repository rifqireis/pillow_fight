#!/usr/bin/env python3
"""
dump.py - Mengekstrak script dari place.rbxlx ke struktur src/
1:1 dengan struktur Explorer Roblox Studio (PascalCase).
"""

import os
import xml.etree.ElementTree as ET

PLACE_FILE = "place.rbxlx"

def get_prop(item, prop_name):
    props = item.find("Properties")
    if props is not None:
        for child in props:
            if child.attrib.get("name") == prop_name:
                return child.text or ""
    return ""

def export_tree(item, target_dir):
    os.makedirs(target_dir, exist_ok=True)
    for child in item.findall("Item"):
        cls = child.attrib.get("class", "")
        name = get_prop(child, "Name")

        if cls == "Folder":
            export_tree(child, os.path.join(target_dir, name))
        elif cls == "Script":
            clean_name = name[:-7] if name.endswith(".server") else name
            filename = f"{clean_name}.server.luau"
            source = get_prop(child, "Source")
            filepath = os.path.join(target_dir, filename)
            with open(filepath, "w", encoding="utf-8") as f:
                f.write(source)
            print(f"  [Script]       {filepath}")
        elif cls == "LocalScript":
            clean_name = name[:-7] if name.endswith(".client") else name
            filename = f"{clean_name}.client.luau"
            source = get_prop(child, "Source")
            filepath = os.path.join(target_dir, filename)
            with open(filepath, "w", encoding="utf-8") as f:
                f.write(source)
            print(f"  [LocalScript]  {filepath}")
        elif cls == "ModuleScript":
            filename = f"{name}.luau"
            source = get_prop(child, "Source")
            filepath = os.path.join(target_dir, filename)
            with open(filepath, "w", encoding="utf-8") as f:
                f.write(source)
            print(f"  [ModuleScript] {filepath}")
        elif cls in ("StarterPlayerScripts", "StarterCharacterScripts"):
            export_tree(child, target_dir)

def main():
    if not os.path.exists(PLACE_FILE):
        print(f"Error: {PLACE_FILE} tidak ditemukan!")
        return

    print(f"Membaca {PLACE_FILE}...")
    tree = ET.parse(PLACE_FILE)
    root = tree.getroot()

    for item in root.findall("Item"):
        name = get_prop(item, "Name")

        if name == "ServerScriptService":
            print("\nMengekstrak ServerScriptService -> src/ServerScriptService...")
            export_tree(item, "src/ServerScriptService")

        elif name == "ReplicatedStorage":
            for child in item.findall("Item"):
                cname = get_prop(child, "Name")
                if cname == "Configs":
                    print("\nMengekstrak ReplicatedStorage/Configs -> src/ReplicatedStorage/Configs...")
                    export_tree(child, "src/ReplicatedStorage/Configs")
                elif cname == "Shared":
                    print("\nMengekstrak ReplicatedStorage/Shared -> src/ReplicatedStorage/Shared...")
                    export_tree(child, "src/ReplicatedStorage/Shared")

        elif name == "StarterPlayer":
            for child in item.findall("Item"):
                cname = get_prop(child, "Name")
                if cname == "StarterPlayerScripts":
                    print("\nMengekstrak StarterPlayerScripts -> src/StarterPlayer/StarterPlayerScripts...")
                    export_tree(child, "src/StarterPlayer/StarterPlayerScripts")

        elif name == "ReplicatedFirst":
            print("\nMengekstrak ReplicatedFirst -> src/ReplicatedFirst...")
            for child in item.findall("Item"):
                cls = child.attrib.get("class", "")
                if cls in ("Script", "LocalScript", "ModuleScript"):
                    cname = get_prop(child, "Name")
                    clean_name = cname[:-7] if cname.endswith(".client") else cname
                    filename = f"{clean_name}.client.luau" if cls == "LocalScript" else f"{clean_name}.server.luau"
                    filepath = os.path.join("src/ReplicatedFirst", filename)
                    os.makedirs("src/ReplicatedFirst", exist_ok=True)
                    with open(filepath, "w", encoding="utf-8") as f:
                        f.write(get_prop(child, "Source"))
                    print(f"  [{cls}] {filepath}")

    print("\nEkstraksi selesai 1:1! Semua script sudah tersinkronisasi.")

if __name__ == "__main__":
    main()
