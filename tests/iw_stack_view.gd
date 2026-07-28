extends SceneTree

## The stack view's controls: the dropdown that adds, and the row that replaces.
##
## The dropdown is the whole of adding an operation — there is no button beside it to
## press afterwards — so what matters is that a pick lands, and that a pick of the item
## already showing lands too. That second one is not a detail: it is how a second Polygon
## Edit gets into a stack, and the obvious signal to have used does not fire for it.
##
## Reached through [method load] rather than by [code]class_name[/code], so this runs
## before the editor has rescanned the project.
##
## Run it:
## [codeblock]
## godot --headless --path . --script res://tests/iw_stack_view.gd
## [/codeblock]

const StackViewScript := preload("res://addons/image_wrangler/ui/iw_stack_view.gd")
const PanelScript := preload("res://addons/image_wrangler/ui/iw_panel.gd")
const SettingsIO := preload("res://addons/image_wrangler/core/iw_settings_io.gd")

var _failures := 0
var _view: VBoxContainer
var _announced := 0


func _initialize() -> void:
    _view = StackViewScript.new()
    _view.operation_scripts = PanelScript.OPERATION_SCRIPTS
    get_root().add_child(_view)
    # _ready has not run this early, and rebuild builds the controls on demand.
    _view.rebuild()
    _view.stack_changed.connect(func() -> void: _announced += 1)

    _check_no_button()
    _check_pick_adds()
    _check_same_pick_adds_again()
    _check_tool_row()
    _check_tools_only_ask()
    _check_save_load_round_trip()

    _view.queue_free()
    if _failures == 0:
        print("Stack view OK — a pick adds, the same pick adds another, and there is no "
                + "button left to press.")
    quit(1 if _failures > 0 else 0)


## Nothing to press. The dropdown is not a choice waiting to be confirmed any more.
func _check_no_button() -> void:
    var labels := _buttons_under(_view)
    _expect(not labels.has("Create"),
            "there is still a Create button: %s" % str(labels))

    var selectors := 0
    for child in _view.get_children():
        if child is OptionButton:
            selectors += 1
    _expect(selectors == 1, "expected one dropdown sitting on its own, found %d" % selectors)


## A pick from the list adds that operation and says so, once.
func _check_pick_adds() -> void:
    var popup: PopupMenu = _selector().get_popup()
    _expect(popup.item_count == PanelScript.OPERATION_SCRIPTS.size(),
            "the dropdown offers %d operations, not %d"
            % [popup.item_count, PanelScript.OPERATION_SCRIPTS.size()])

    var wanted := _id_at(2)
    _announced = 0
    popup.index_pressed.emit(2)

    var stages: Array = _view.stages()
    if not _expect(stages.size() == 1, "a pick added %d operations" % stages.size()):
        return
    _expect(stages[0].get_operation_id() == wanted,
            "picking item 2 added %s, not %s" % [stages[0].get_operation_id(), wanted])
    _expect(_announced == 1, "a pick announced %d times, not once" % _announced)


## The one the plain item_selected signal would have missed.
func _check_same_pick_adds_again() -> void:
    var popup: PopupMenu = _selector().get_popup()
    var wanted := _id_at(2)
    _announced = 0
    popup.index_pressed.emit(2)
    popup.index_pressed.emit(2)

    var stages: Array = _view.stages()
    _expect(stages.size() == 3,
            "picking the same item twice more left %d operations, not 3" % stages.size())
    _expect(_announced == 2, "two picks announced %d times" % _announced)
    for stage: IWStackOperation in stages:
        _expect(stage.get_operation_id() == wanted, "the stack picked up something else")

    # Three of the same operation, and each with settings of its own — a duplicate that
    # shared them would not be a duplicate, it would be one operation shown twice.
    _expect(stages[0].get_settings() != stages[1].get_settings()
            and stages[1].get_settings() != stages[2].get_settings(),
            "duplicate operations share one settings object")


## The five ways of getting a whole stack at once, in the order they are reached for.
##
## Checked by the word each button falls back on rather than by its icon: headless there
## is no editor theme, so every one of them is wearing its name here. In the editor they
## are wearing icons instead, and the same list decides which.
func _check_tool_row() -> void:
    var row := _tool_row()
    var labels := []
    for button in row:
        labels.append(button.text)
    _expect(labels == ["Save", "Load", "Copy", "Paste", "Reset"],
            "the tool row reads %s" % str(labels))

    # Each one has to have asked for an icon, or in the editor it would be the only bare
    # word in a row of pictures.
    for button in row:
        var icon: StringName = button.get_meta(StackViewScript.META_ICON, &"")
        _expect(not icon.is_empty(), "the %s button asked for no icon" % button.text)

    # And every one has to say what it does, since a picture on its own does not.
    for button in row:
        _expect(button.tooltip_text.length() > 20,
                "the %s button has nothing useful to say on hover" % button.text)


## Every button on the row asks the dock rather than acting, so pressing one has to
## announce and change nothing by itself.
func _check_tools_only_ask() -> void:
    var before: int = _view.stages().size()
    var heard := {}
    for name: String in ["save", "load", "copy", "paste", "reset"]:
        _view.connect("%s_requested" % name,
                func() -> void: heard[name] = int(heard.get(name, 0)) + 1)

    for button in _tool_row():
        button.pressed.emit()

    _expect(heard.size() == 5, "only %d of the five buttons asked for anything" % heard.size())
    for name: String in heard:
        _expect(heard[name] == 1, "%s asked %d times" % [name, heard[name]])
    _expect(_view.stages().size() == before,
            "a tool button changed the stack on its own")


## A saved file has to come back as the stack that went into it.
##
## Through the real codec and a real file, because the point of Save is that what lands
## on disk can be read again — by this, or by a person, or by a sidecar.
func _check_save_load_round_trip() -> void:
    var registry := {}
    for path: String in PanelScript.OPERATION_SCRIPTS:
        var probe: IWOperation = load(path).new()
        registry[probe.get_operation_id()] = load(path)

    var records := []
    for stage: IWStackOperation in _view.stages():
        records.append({
            "id": stage.get_operation_id(),
            "enabled": stage.enabled,
            "settings": stage.get_settings(),
        })
    if not _expect(not records.is_empty(), "nothing in the stack to round trip"):
        return

    var where := "user://stack_round_trip.json"
    var file := FileAccess.open(where, FileAccess.WRITE)
    if not _expect(file != null, "could not write the test file"):
        return
    file.store_string(SettingsIO.stack_to_text(records, "\t"))
    file.close()

    var read := FileAccess.open(where, FileAccess.READ)
    var text := read.get_as_text()
    read.close()
    DirAccess.remove_absolute(ProjectSettings.globalize_path(where))

    # Indented, because a saved stack is a thing somebody may open.
    _expect(text.contains("\n\t"), "the saved file is not laid out to be read")

    var back := SettingsIO.stack_from_text(text, registry)
    if not _expect(back.size() == records.size(),
            "a saved stack of %d came back as %d" % [records.size(), back.size()]):
        return
    for i in back.size():
        _expect(back[i]["id"] == records[i]["id"], "the order changed at %d" % i)


# --- Helpers ------------------------------------------------------------

## The tool row's buttons, in the order they sit in.
func _tool_row() -> Array:
    for child in _view.get_children():
        if not (child is HBoxContainer):
            continue
        var buttons := []
        for button in (child as HBoxContainer).get_children():
            if button is Button:
                buttons.append(button)
        if not buttons.is_empty():
            return buttons
    return []


func _selector() -> OptionButton:
    for child in _view.get_children():
        if child is OptionButton:
            return child
    return null


## The operation id the dropdown's item at [param index] stands for.
func _id_at(index: int) -> StringName:
    var path: String = String(_selector().get_item_metadata(index))
    var probe: IWOperation = load(path).new()
    return probe.get_operation_id()


## Every button label anywhere under [param node], at any depth.
func _buttons_under(node: Node) -> Array:
    var found := []
    for child in node.get_children():
        if child is Button and not (child is OptionButton) and not (child is CheckBox):
            found.append((child as Button).text)
        found.append_array(_buttons_under(child))
    return found


func _expect(condition: bool, message: String) -> bool:
    if not condition:
        printerr("FAIL: %s" % message)
        _failures += 1
    return condition
