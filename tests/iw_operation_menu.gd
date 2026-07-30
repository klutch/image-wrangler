extends SceneTree

## The Add-operation dropdown: its groups, its order, and its icons.
##
## [b]Worth its own file because the list is the one thing every new operation touches.[/b]
## Adding one means a script, a group to put it in, an icon name and a place in the
## alphabet, and three of those four fail silently — a missing icon draws nothing, a
## misplaced entry just sits in the wrong group, and an operation listed twice offers
## itself twice. None of that stops the addon working, so none of it would be noticed.
##
## Run it:
## [codeblock]
## godot --headless --path . --script res://tests/iw_operation_menu.gd
## [/codeblock]

const PANEL := preload("res://addons/image_wrangler/ui/iw_panel.gd")
const StackView := preload("res://addons/image_wrangler/ui/iw_stack_view.gd")

const ICON_DIR := "res://addons/image_wrangler/ui/icons/"

var _failures := 0


func _initialize() -> void:
    _check_groups_are_sound()
    _check_alphabetical()
    _check_icons_exist()
    _check_flattening()
    await _check_the_menu_itself()

    if _failures == 0:
        print("Operation Menu OK — every operation is offered once, under a heading, in "
                + "alphabetical order, with an icon that exists.")
    quit(1 if _failures > 0 else 0)


# --- The list as data ---------------------------------------------------

func _check_groups_are_sound() -> void:
    var groups: Array = PANEL.OPERATION_GROUPS
    _expect(not groups.is_empty(), "there are no operation groups at all")

    var names := {}
    var scripts := {}
    for group: Dictionary in groups:
        var name := String(group.get("name", ""))
        _expect(not name.is_empty(), "a group has no name")
        _expect(not names.has(name), "two groups are both called %s" % name)
        names[name] = true

        var entries: Array = group.get("entries", [])
        _expect(not entries.is_empty(), "the %s group is empty" % name)
        for entry: Dictionary in entries:
            var path := String(entry.get("script", ""))
            _expect(not scripts.has(path), "%s is offered twice" % path.get_file())
            scripts[path] = true
            _expect(ResourceLoader.exists(path), "%s does not exist" % path)
            var script: Script = load(path)
            if not _expect(script != null, "%s did not load" % path):
                continue
            var probe: Variant = script.new()
            _expect(probe is IWStackOperation,
                    "%s is not a stack operation" % path.get_file())
            _expect(not String(probe.get_operation_name()).is_empty(),
                    "%s has no name to show" % path.get_file())


## Alphabetical by the name the dropdown shows, which is the name being read.
##
## Sorted on [method IWOperation.get_operation_name] rather than on the filename, because
## those disagree — island_picker_op.gd shows as "Island Picker" and edge_cleanup.gd as
## "Edge Cleanup", so a list sorted by path would look wrong on screen and right in the
## source.
func _check_alphabetical() -> void:
    for group: Dictionary in PANEL.OPERATION_GROUPS:
        var shown := []
        for entry: Dictionary in group["entries"]:
            var script: Script = load(String(entry["script"]))
            if script == null:
                continue
            shown.append(String(script.new().get_operation_name()))
        var sorted := shown.duplicate()
        sorted.sort()
        _expect(shown == sorted,
                "the %s group is out of order:\n  got  %s\n  want %s"
                % [group["name"], shown, sorted])


func _check_icons_exist() -> void:
    for group: Dictionary in PANEL.OPERATION_GROUPS:
        for entry: Dictionary in group["entries"]:
            var icon := String(entry.get("icon", ""))
            _expect(not icon.is_empty(),
                    "%s names no icon" % String(entry["script"]).get_file())
            _expect(ResourceLoader.exists("%s%s.svg" % [ICON_DIR, icon]),
                    "%s names the icon %s, which is not in ui/icons/"
                    % [String(entry["script"]).get_file(), icon])


## The flat list the registry is built from has to be the grouped one with the headings
## taken out — a script reachable from the dropdown but missing here would load a sidecar
## that then decoded to nothing.
func _check_flattening() -> void:
    var flat: Array = PANEL.operation_scripts()
    var expected := []
    for group: Dictionary in PANEL.OPERATION_GROUPS:
        for entry: Dictionary in group["entries"]:
            expected.append(String(entry["script"]))
    _expect(flat == expected,
            "the flattened list does not match the groups\n  got  %s\n  want %s"
            % [flat, expected])


# --- The dropdown as built ----------------------------------------------

## Driven through the real control, because the thing most likely to go wrong is not the
## data but what a separator does to it: it takes an index of its own, so anything reading
## meaning off the index reads the wrong row.
func _check_the_menu_itself() -> void:
    var view: Control = StackView.new()
    view.operation_groups = PANEL.OPERATION_GROUPS
    root.add_child(view)
    await process_frame

    var menu: OptionButton = view._selector
    if not _expect(menu != null, "the stack view built no dropdown"):
        view.queue_free()
        return

    var groups: Array = PANEL.OPERATION_GROUPS
    var operations := 0
    for group: Dictionary in groups:
        operations += (group["entries"] as Array).size()
    _expect(menu.item_count == operations + groups.size(),
            "the dropdown holds %d rows for %d operations and %d headings"
            % [menu.item_count, operations, groups.size()])

    # Headings carry their group's name and nothing else; rows carry a script and are
    # selectable. Walked together so their order is checked as well as their contents.
    var expected := []
    for group: Dictionary in groups:
        expected.append({"separator": true, "text": String(group["name"])})
        for entry: Dictionary in group["entries"]:
            expected.append({"separator": false, "path": String(entry["script"])})

    for i in mini(menu.item_count, expected.size()):
        var want: Dictionary = expected[i]
        if want["separator"]:
            _expect(menu.is_item_separator(i), "row %d should be a heading" % i)
            _expect(menu.get_item_text(i) == want["text"],
                    "heading %d reads %s rather than %s"
                    % [i, menu.get_item_text(i), want["text"]])
            _expect(menu.get_item_metadata(i) == null,
                    "heading %d carries metadata, which _on_pick would try to load" % i)
        else:
            _expect(not menu.is_item_separator(i), "row %d should be an operation" % i)
            _expect(menu.get_item_metadata(i) == want["path"],
                    "row %d points at %s rather than %s"
                    % [i, menu.get_item_metadata(i), want["path"]])

    # What shows on the closed dropdown is a real operation, not the first heading.
    _expect(not menu.is_item_separator(menu.selected),
            "the dropdown opens showing heading %d rather than an operation" % menu.selected)
    _expect(menu.get_item_metadata(menu.selected) != null,
            "the row showing on the closed dropdown has no operation behind it")

    # And picking a heading does nothing, which is what stops a stray index adding a stage.
    var before: int = (view._entries as Array).size()
    view._on_pick(0)
    _expect((view._entries as Array).size() == before,
            "picking a heading added a stage")

    view.queue_free()


# --- Reporting ---------------------------------------------------------

func _expect(condition: bool, message: String) -> bool:
    if not condition:
        printerr("FAIL: %s" % message)
        _failures += 1
    return condition
