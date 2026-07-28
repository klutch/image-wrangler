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
    _check_clipboard_row()

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


## The row that replaces a stack wholesale, which sits under the dropdown.
func _check_clipboard_row() -> void:
    var row := []
    for child in _view.get_children():
        if not (child is HBoxContainer):
            continue
        var labels := []
        for button in (child as HBoxContainer).get_children():
            if button is Button:
                labels.append((button as Button).text)
        if labels.has("Reset"):
            row = labels
    _expect(row == ["Copy Stack", "Paste Stack", "Reset"],
            "the clipboard row reads %s" % str(row))


# --- Helpers ------------------------------------------------------------

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
