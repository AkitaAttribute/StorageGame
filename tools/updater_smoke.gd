extends SceneTree

const Updater = preload("res://scripts/update_runtime.gd")

func _initialize() -> void:
    call_deferred("run_test")

func check(condition: bool, message: String) -> bool:
    if not condition:
        push_error(message)
        quit(1)
        return false
    return true

func run_test() -> void:
    var updater := Updater.new()
    root.add_child(updater)
    var folder := ProjectSettings.globalize_path(Updater.UPDATE_DIR)
    if not check(DirAccess.make_dir_recursive_absolute(folder) == OK, "Updater test folder failed"):
        return
    var previous := {"channel": Updater.CHANNEL, "build": 1, "path": Updater.UPDATE_DIR + "/previous.pck"}
    var meta := FileAccess.open(Updater.INSTALLED_METADATA, FileAccess.WRITE)
    meta.store_string(JSON.stringify(previous))
    meta.close()
    var previous_text := FileAccess.get_file_as_string(Updater.INSTALLED_METADATA)
    updater._current_build = 1
    updater._available_build = 2
    updater._pending_size = 10
    updater._pending_sha256 = "0".repeat(64)
    if not check(not updater._commit_downloaded_pack().is_empty(), "Missing download was accepted"):
        return
    var payload := FileAccess.open(Updater.PENDING_PACK, FileAccess.WRITE)
    payload.store_32(Updater.PCK_MAGIC)
    payload.store_32(0)
    payload.close()
    if not check(not updater._commit_downloaded_pack().is_empty(), "Wrong-size download was accepted"):
        return
    updater._pending_size = 8
    if not check(not updater._commit_downloaded_pack().is_empty(), "Bad checksum was accepted"):
        return
    if not check(FileAccess.get_file_as_string(Updater.INSTALLED_METADATA) == previous_text, "Failed update changed previous activation"):
        return
    # Generate a real Godot PCK for the successful transaction.
    DirAccess.remove_absolute(ProjectSettings.globalize_path(Updater.PENDING_PACK))
    var packer := PCKPacker.new()
    if not check(packer.pck_start(ProjectSettings.globalize_path(Updater.PENDING_PACK)) == OK, "Test PCK creation failed"):
        return
    if not check(packer.add_file("res://update_smoke.txt", ProjectSettings.globalize_path(Updater.INSTALLED_METADATA)) == OK, "Test PCK add failed"):
        return
    if not check(packer.flush() == OK, "Test PCK flush failed"):
        return
    var pack := FileAccess.open(Updater.PENDING_PACK, FileAccess.READ)
    updater._pending_size = pack.get_length()
    pack.close()
    updater._pending_sha256 = FileAccess.get_sha256(Updater.PENDING_PACK)
    var err := updater._commit_downloaded_pack()
    if not check(err.is_empty(), "Valid update failed: " + err):
        return
    var installed := updater._read_installed_metadata()
    if not check(int(installed.get("build", 0)) == 2 and FileAccess.get_sha256(str(installed.get("path", ""))) == updater._pending_sha256, "Update activation verification failed"):
        return
    print("UPDATER_SMOKE_PASS")
    quit(0)
