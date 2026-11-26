extends RefCounted
## Compatibility with APKs/EXEs shipped before the updater was split.
## The old autoload is already instantiated when its PCK mounts, but the main
## scene and this script are loaded from the mounted pack afterwards.

const Runtime = preload("res://scripts/update_runtime.gd")

static func attach(owner: Node) -> Node:
    var tree := owner.get_tree()
    var bootstrap := tree.root.get_node_or_null("UpdateManager")
    var build := int(str(ProjectSettings.get_setting("application/config/version", "0.1.0")).get_slice(".", 2))
    if bootstrap != null:
        build = maxi(build, int(bootstrap.get("_current_build")))
        # Older binaries do their own UI setup in _ready. Disconnect it before
        # its deferred network request can present a second dialog. Keep the
        # autoload alive because the old startup script is still referenced.
        for child in bootstrap.get_children():
            if child is HTTPRequest:
                for connection in child.request_completed.get_connections():
                    child.request_completed.disconnect(connection["callable"])
                child.cancel_request()
                # The legacy _check_for_update call may already be deferred.
                child.call_deferred("cancel_request")
            elif child is Window:
                child.hide()
                child.process_mode = Node.PROCESS_MODE_DISABLED
        bootstrap.process_mode = Node.PROCESS_MODE_DISABLED
    var updater := Runtime.new()
    updater.name = "PatchableUpdater"
    updater.configure(build)
    owner.add_child(updater)
    return updater
