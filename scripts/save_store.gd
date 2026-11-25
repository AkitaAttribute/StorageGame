extends RefCounted

const DIRECTORY := "user://saves"
const SCHEMA := 1

static func read_slot(id: String) -> Dictionary:
    if id.is_empty() or not id.is_valid_filename():
        return {}
    for suffix in [".json", ".bak"]:
        var path := DIRECTORY.path_join(id + suffix)
        if not FileAccess.file_exists(path):
            continue
        var f := FileAccess.open(path, FileAccess.READ)
        if f == null:
            continue
        var parsed: Variant = JSON.parse_string(f.get_as_text())
        f.close()
        if parsed is Dictionary and parsed.get("schema") == SCHEMA and parsed.get("id") == id:
            var pos: Variant = parsed.get("position")
            if pos is Array and pos.size() == 3 and pos.all(func(x): return x is float or x is int):
                return parsed
    return {}

static func latest() -> Dictionary:
    var dir := DirAccess.open(DIRECTORY)
    if dir == null:
        return {}
    var best: Dictionary = {}
    for file in dir.get_files():
        if not file.ends_with(".json") and not file.ends_with(".bak"):
            continue
        var candidate := read_slot(file.get_basename())
        if not candidate.is_empty() and float(candidate.get("updated", 0)) > float(best.get("updated", 0)):
            best = candidate
    return best

static func new_slot() -> Dictionary:
    var id := "%d-%s" % [Time.get_ticks_usec(), Crypto.new().generate_random_bytes(12).hex_encode()]
    return {"schema": SCHEMA, "id": id, "position": [-10.4, 0.1, 5.0], "rotation": 0.0, "doors": {}, "updated": Time.get_unix_time_from_system()}

static func write_slot(state: Dictionary) -> bool:
    var id := str(state.get("id", ""))
    if id.is_empty() or not id.is_valid_filename():
        return false
    if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIRECTORY)) != OK:
        return false
    state["updated"] = Time.get_unix_time_from_system()
    var target := ProjectSettings.globalize_path(DIRECTORY.path_join(id + ".json"))
    var temp := target + ".tmp"
    var backup := target.get_basename() + ".bak"
    var f := FileAccess.open(temp, FileAccess.WRITE)
    if f == null:
        return false
    f.store_string(JSON.stringify(state))
    f.flush()
    f.close()
    if FileAccess.file_exists(target):
        if FileAccess.file_exists(backup):
            DirAccess.remove_absolute(backup)
        if DirAccess.rename_absolute(target, backup) != OK:
            return false
    return DirAccess.rename_absolute(temp, target) == OK
