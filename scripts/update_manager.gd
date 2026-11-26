extends Node
## Small, stable updater bootstrap for the public preview channel.
## This must remain the first autoload so packs override scenes/scripts before they load.

const CHANNEL := "storage-preview"
const MANIFEST_URL := "https://github.com/AkitaAttribute/StorageGame/releases/download/preview/manifest.json"
const UPDATE_DIR := "user://updates"
const INSTALLED_METADATA := "user://updates/installed.json"
const PENDING_PACK := "user://updates/download.pck.part"
const PENDING_METADATA := "user://updates/installed.json.part"
const SUCCESS_DELAY := 3.0
const PCK_MAGIC := 0x43504447

var _manifest_http: HTTPRequest
var _download_http: HTTPRequest
var _download_dialog: ConfirmationDialog
var _install_dialog: ConfirmationDialog
var _notice_dialog: AcceptDialog

var _available_build := 0
var _current_build := 0
var _pending_url := ""
var _pending_sha256 := ""
var _pending_size := 0
var _installed_pack_path := ""
var _installing := false

func _init() -> void:
    _load_installed_pack()

func _ready() -> void:
    if Engine.is_editor_hint() or DisplayServer.get_name() == "headless":
        return
    if OS.get_name() != "Windows" and OS.get_name() != "Android":
        return

    _current_build = _embedded_build()
    var installed := _read_installed_metadata()
    if not _installed_pack_path.is_empty():
        _current_build = maxi(_current_build, int(installed.get("build", 0)))

    _manifest_http = HTTPRequest.new()
    _manifest_http.use_threads = true
    _manifest_http.timeout = 20.0
    add_child(_manifest_http)
    _manifest_http.request_completed.connect(_on_manifest_received)

    _download_http = HTTPRequest.new()
    _download_http.use_threads = true
    _download_http.download_file = PENDING_PACK
    _download_http.timeout = 300.0
    add_child(_download_http)
    _download_http.request_completed.connect(_on_pack_received)

    _download_dialog = ConfirmationDialog.new()
    _download_dialog.title = "Storage Game Update"
    _download_dialog.ok_button_text = "Download"
    _download_dialog.cancel_button_text = "Later"
    _download_dialog.confirmed.connect(_begin_download)
    add_child(_download_dialog)

    _install_dialog = ConfirmationDialog.new()
    _install_dialog.title = "Storage Game Update"
    _install_dialog.ok_button_text = "Install"
    _install_dialog.cancel_button_text = "Later"
    _install_dialog.confirmed.connect(_install_downloaded_pack)
    add_child(_install_dialog)

    _notice_dialog = AcceptDialog.new()
    _notice_dialog.title = "Storage Game Update"
    add_child(_notice_dialog)

    call_deferred("_check_for_update")

func _embedded_build() -> int:
    var version := str(ProjectSettings.get_setting("application/config/version", "0.1.0"))
    return version.get_slice(".", 2).to_int()

func _read_installed_metadata() -> Dictionary:
    if not FileAccess.file_exists(INSTALLED_METADATA):
        return {}
    var file := FileAccess.open(INSTALLED_METADATA, FileAccess.READ)
    if file == null:
        return {}
    var parsed: Variant = JSON.parse_string(file.get_as_text())
    if typeof(parsed) != TYPE_DICTIONARY:
        return {}
    return parsed as Dictionary

func _load_installed_pack() -> void:
    var installed := _read_installed_metadata()
    if str(installed.get("channel", "")) != CHANNEL:
        return

    # Important for in-place Windows/Android recovery: the newest full
    # executable or APK must take precedence over a previously downloaded PCK.
    # Otherwise an installed (possibly broken) patch can override newly fixed
    # scripts on every startup, even after a full application update.
    var installed_build := int(installed.get("build", 0))
    var bundled_build := _embedded_build()
    if bundled_build > 0 and installed_build <= bundled_build:
        print(
            "Storage Game: skipping previous update pack build ",
            installed_build,
            "; bundled app build ",
            bundled_build,
            " is newer or equal."
        )
        return

    var path := str(installed.get("path", ""))
    if not path.begins_with(UPDATE_DIR + "/") or not path.ends_with(".pck"):
        return
    if not FileAccess.file_exists(path):
        push_warning("Storage Game update pack missing: " + path)
        return
    if ProjectSettings.load_resource_pack(ProjectSettings.globalize_path(path), true):
        _installed_pack_path = path
        print("Storage Game: loaded preview patch ", path)
    else:
        push_error("Storage Game: failed to load update " + path + "; starting bundled version.")

func _check_for_update() -> void:
    var err := _manifest_http.request(MANIFEST_URL)
    if err != OK:
        push_warning("Storage Game update check failed to start: " + str(err))

func _on_manifest_received(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
    if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
        print("Storage Game: update manifest unavailable (", result, "/", response_code, ").")
        return
    var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
    if typeof(parsed) != TYPE_DICTIONARY:
        push_warning("Storage Game: invalid update manifest.")
        return
    var manifest: Dictionary = parsed as Dictionary
    if str(manifest.get("channel", "")) != CHANNEL:
        return
    var build := int(manifest.get("build", 0))
    if build <= _current_build:
        return

    var platform_key := "windows" if OS.get_name() == "Windows" else "android"
    var platform_data: Variant = manifest.get(platform_key, {})
    if typeof(platform_data) != TYPE_DICTIONARY:
        return
    var info: Dictionary = platform_data as Dictionary
    var url := str(info.get("url", ""))
    var sha := str(info.get("sha256", "")).to_lower()
    var size := int(info.get("bytes", 0))
    if not url.begins_with("https://github.com/AkitaAttribute/StorageGame/releases/download/preview/"):
        return
    if sha.length() != 64 or not sha.is_valid_hex_number() or size <= 0:
        return

    _available_build = build
    _pending_url = url
    _pending_sha256 = sha
    _pending_size = size
    _download_dialog.dialog_text = "preview build %d is available.\nInstalled build: %d.\n\nDownload this update?" % [build, _current_build]
    _download_dialog.popup_centered(Vector2i(520, 230))

func _begin_download() -> void:
    if _installing:
        return
    if _pending_url.is_empty() or _available_build <= _current_build:
        _show_notice("No newer update is available to download.")
        return
    var directory_error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(UPDATE_DIR))
    if directory_error != OK:
        _show_notice("Unable to create the update folder.")
        return
    if FileAccess.file_exists(PENDING_PACK):
        var remove_error := DirAccess.remove_absolute(ProjectSettings.globalize_path(PENDING_PACK))
        if remove_error != OK:
            _show_notice("Unable to remove the previous partial download: " + error_string(remove_error))
            return
    _download_http.download_file = PENDING_PACK
    var err := _download_http.request(_pending_url)
    if err != OK:
        _show_notice("Could not begin the download (%d)." % err)
        return
    _notice_dialog.dialog_text = "Downloading preview build %d...\nKeep Storage Game open until the download completes." % _available_build
    _notice_dialog.popup_centered(Vector2i(510, 180))
    print("Storage Game: downloading preview build ", _available_build)

func _on_pack_received(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
    _notice_dialog.hide()
    if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
        _show_notice("Update download failed (%d / HTTP %d)." % [result, response_code])
        return
    var verification_error := _verify_pending_pack()
    if not verification_error.is_empty():
        _show_notice(verification_error)
        return
    _install_dialog.dialog_text = "Build %d has been downloaded and verified.\n\nInstall it now? Storage Game will restart or close automatically after a successful installation." % _available_build
    _install_dialog.popup_centered(Vector2i(550, 250))

# Revalidate at install time too, rather than trusting an earlier download.
func _verify_pending_pack() -> String:
    if _available_build <= _current_build or _pending_size <= 0 or _pending_sha256.length() != 64:
        return "The update metadata is invalid or the build is not newer."
    if not FileAccess.file_exists(PENDING_PACK):
        return "The downloaded update was not found."
    var file := FileAccess.open(PENDING_PACK, FileAccess.READ)
    if file == null:
        return "Unable to read the downloaded update: " + error_string(FileAccess.get_open_error())
    if file.get_length() != _pending_size or file.get_length() < 4:
        file.close()
        return "The downloaded update has an unexpected size."
    var magic := file.get_32()
    file.close()
    if magic != PCK_MAGIC:
        return "The downloaded update is not a valid Godot resource pack."
    if FileAccess.get_sha256(PENDING_PACK).to_lower() != _pending_sha256:
        return "The downloaded update failed SHA-256 verification."
    return ""

# The activation metadata is committed last, by same-directory atomic rename.
# Never overwrite the currently active resource pack or truncate its metadata.
# Returns an error message without quitting, even if the new pack is orphaned.
func _commit_downloaded_pack() -> String:
    var verification_error := _verify_pending_pack()
    if not verification_error.is_empty():
        return verification_error
    var installed_path := "%s/storage-preview-build-%d-%s.pck" % [UPDATE_DIR, _available_build, Crypto.new().generate_random_bytes(8).hex_encode()]
    if FileAccess.file_exists(installed_path):
        return "Unable to allocate a unique update filename. Please retry."
    var absolute_target := ProjectSettings.globalize_path(installed_path)
    var err := DirAccess.rename_absolute(ProjectSettings.globalize_path(PENDING_PACK), absolute_target)
    if err != OK:
        return "Unable to install the downloaded update: " + error_string(err)
    # The verified pack must still be intact at its final destination.
    if FileAccess.get_sha256(installed_path).to_lower() != _pending_sha256:
        return "The installed resource pack failed SHA-256 verification."
    var metadata := {"channel": CHANNEL, "build": _available_build, "path": installed_path}
    var config := FileAccess.open(PENDING_METADATA, FileAccess.WRITE)
    if config == null:
        return "Unable to write update activation metadata: " + error_string(FileAccess.get_open_error())
    config.store_string(JSON.stringify(metadata))
    config.flush()
    var write_error := config.get_error()
    config.close()
    if write_error != OK:
        return "Unable to save update activation metadata: " + error_string(write_error)
    var check := FileAccess.open(PENDING_METADATA, FileAccess.READ)
    if check == null:
        return "Unable to verify update activation metadata."
    var parsed: Variant = JSON.parse_string(check.get_as_text())
    check.close()
    if not parsed is Dictionary or str(parsed.get("channel", "")) != CHANNEL or int(parsed.get("build", 0)) != _available_build or str(parsed.get("path", "")) != installed_path:
        return "Update activation metadata failed verification."
    err = DirAccess.rename_absolute(ProjectSettings.globalize_path(PENDING_METADATA), ProjectSettings.globalize_path(INSTALLED_METADATA))
    if err != OK:
        return "Unable to activate the update: " + error_string(err)
    return ""

func _install_downloaded_pack() -> void:
    if _installing:
        return
    _installing = true
    var verification_error := _verify_pending_pack()
    if not verification_error.is_empty():
        _installing = false
        _show_notice(verification_error)
        return
    # Persist an active game before committing the update. Do not quit if
    # saving fails. A menu-only session has no active game to save.
    var scene := get_tree().current_scene
    if scene != null and scene.has_method("save_game"):
        var saved: Variant = scene.call("save_game")
        if saved is bool and not saved:
            _installing = false
            _show_notice("Unable to save your current game. The update was not activated.")
            return
    var install_error := _commit_downloaded_pack()
    if not install_error.is_empty():
        _installing = false
        _show_notice(install_error + "\n\nStorage Game will remain open. Your previous update is retained.")
        return
    _current_build = _available_build
    await _finish_successful_install()

func _finish_successful_install() -> void:
    # Godot's restart-on-exit API is desktop-only. A normal Android quit
    # is the supported fallback; do not launch a second activity/process.
    var restart := OS.get_name() == "Windows"
    process_mode = Node.PROCESS_MODE_ALWAYS
    get_tree().paused = true
    _notice_dialog.title = "Update installed successfully"
    _notice_dialog.dialog_text = ("Build %d installed successfully.\n\nRestarting Storage Game in 3 seconds." if restart else "Build %d installed successfully.\n\nStorage Game will close in 3 seconds. Reopen it to play the new build.") % _available_build
    _notice_dialog.popup_centered(Vector2i(560, 240))
    _notice_dialog.get_ok_button().hide()
    await get_tree().create_timer(SUCCESS_DELAY, true, false, true).timeout
    if restart:
        OS.set_restart_on_exit(true)
    get_tree().quit(0)

func _show_notice(message: String) -> void:
    push_warning("Storage Game updater: " + message)
    _notice_dialog.title = "Storage Game Update"
    _notice_dialog.get_ok_button().show()
    _notice_dialog.dialog_text = message
    _notice_dialog.popup_centered(Vector2i(530, 200))
