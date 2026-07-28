@tool
extends VBoxContainer

## The operation stack: a dropdown to add with, and a draggable column of entries.
##
## Holds the live [IWStackOperation] instances and their order. The dock owns the
## settings behind them and the running of them; this owns what the stack [i]is[/i].
##
## Duplicates are allowed and mean what they look like — two Polygon Edits are two
## independent sets of shapes, and a second Remove Background adds its colours to the
## keys the first registered. So nothing here is keyed by operation id: entries carry
## a uid of their own, because the id is shared between duplicates and the position is
## exactly what a reorder changes.

const StackEntry := preload("res://addons/image_wrangler/ui/iw_stack_entry.gd")

## Room above and below the column of entries, and between one entry and the next.
##
## Vertical only. The entries take the full width of the column, which is narrow
## enough already — insetting them would cost the settings inside them room they need
## more than the card needs a gutter.
##
## The gap between them is what makes the drop indicator legible: a line drawn on the
## edge of an entry needs somewhere to be that is not already the next entry's edge.
const ENTRY_MARGIN := 4
const ENTRY_GAP := 4

## Emitted when the stack's contents or order changed, so the preview is stale.
signal stack_changed

## Emitted when a value inside one entry's form changed.
signal setting_changed

## Emitted after entries are rebuilt, so the dock can rewire what it cached about
## their controls.
signal entries_rebuilt

## Emitted when Copy Stack or Paste Stack is pressed.
##
## The dock does the work rather than this. The clipboard carries the sidecar's own
## format, and both the codec and the registry saying which ids name operations belong
## to the dock — the same reason the settings form is built through
## [member form_builder] instead of here.
signal copy_requested
signal paste_requested

## Emitted when Save or Load is pressed. The dock owns the file dialogs, as it does for
## every other file this addon touches.
signal save_requested
signal load_requested

## Emitted when Reset is pressed. Asks rather than does: the confirmation and what
## "default" means both belong to the dock.
signal reset_requested

## Scripts the dropdown offers, in the order it offers them.
var operation_scripts: Array = []

## Called as [code]build(operation, container, on_changed, fold_state, key)[/code] to
## fill one entry's form. Supplied by the dock so this does not have to know about the
## settings builder.
var form_builder := Callable()

## Which entries are folded, keyed by uid. Held by the dock so a fold outlives a
## rebuild.
var fold_state: Dictionary = {}

## Where a tool button keeps the icon it wants and the word to fall back on.
const META_ICON := &"iw_icon"
const META_LABEL := &"iw_label"

## Smallest a tool button is allowed to get, however narrow the dock is squeezed.
const TOOL_MIN_SIZE := 24

## The live stack, in order.
var _entries: Array = []
var _selector: OptionButton
var _list: VBoxContainer
var _tools: HBoxContainer
var _next_uid := 1


func _ready() -> void:
    if _list == null:
        _build()


## The editor's icons are not there until this is in a tree, and they change with the
## theme, so the row is dressed again whenever that happens rather than only once.
func _notification(what: int) -> void:
    if what != NOTIFICATION_THEME_CHANGED or _tools == null:
        return
    for child in _tools.get_children():
        if child is Button:
            _dress(child)


## One button on the tool row.
func _add_tool(icon: StringName, label: String, hint: String, on_press: Callable) -> void:
    var button := Button.new()
    button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    button.tooltip_text = hint
    # The icon grows to fill whatever width the button ends up with, and the height
    # follows in _square_up, so the buttons stay square however wide the dock is.
    button.expand_icon = true
    button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
    # Never focused: these sit between the dropdown and the entries, and tabbing through
    # the form should not stop at five of them on the way.
    button.focus_mode = Control.FOCUS_NONE
    button.set_meta(META_ICON, icon)
    button.set_meta(META_LABEL, label)
    button.pressed.connect(on_press)
    _tools.add_child(button)
    _dress(button)


## Gives the buttons a height to match the width they were given.
##
## The width is not known until the dock has laid out and changes whenever it is
## resized, so this runs from the row's own resized signal rather than being set once.
## The guard is what stops it looping: asking for a height makes the row lay out again,
## which asks again.
func _square_up() -> void:
    if _tools == null or _tools.get_child_count() == 0:
        return
    var gap := _tools.get_theme_constant(&"separation")
    var count := _tools.get_child_count()
    var each := (_tools.size.x - float(gap * (count - 1))) / float(count)
    var wanted := maxf(each, float(TOOL_MIN_SIZE))
    for child in _tools.get_children():
        if child is Button and absf((child as Button).custom_minimum_size.y - wanted) > 0.5:
            (child as Button).custom_minimum_size.y = wanted


## Puts the icon on a tool button, or its word if there is no icon to be had.
##
## Asked for rather than assumed, the same way the fold arrow is: outside the editor
## there is no [code]EditorIcons[/code] theme at all, and a row of buttons wearing their
## own names is better than a row of errors.
func _dress(button: Button) -> void:
    var icon: StringName = button.get_meta(META_ICON, &"")
    if not icon.is_empty() and has_theme_icon(icon, &"EditorIcons"):
        button.icon = get_theme_icon(icon, &"EditorIcons")
        button.text = ""
        return
    button.icon = null
    button.text = String(button.get_meta(META_LABEL, ""))


func _build() -> void:
    # Picking from the list is the whole gesture — there is no button beside it to press
    # afterwards, so the popup's own index_pressed is what this listens to rather than
    # item_selected. item_selected does not fire when the item picked is the one already
    # showing, and adding a second Polygon Edit is an ordinary thing to want.
    _selector = OptionButton.new()
    _selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _selector.tooltip_text = "Add an operation to the bottom of the stack.\nDrag its handle afterwards to move it.\n\nPicking the one already showing adds another of it, which is what duplicates are for."
    _selector.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
    _selector.get_popup().index_pressed.connect(_on_pick)
    add_child(_selector)

    # Its own row under the one that builds a stack by hand, because these are the other
    # ways of getting one. Icons rather than names: five of these across a dock this
    # narrow leaves no room for words, and what each one does is the sort of thing an
    # icon says faster than a label anyway. The tooltips carry the detail.
    #
    # In the order they are reached for — the two that go through a file, the two that go
    # through the clipboard, and then the one that throws everything away, which is last
    # because it is the only one that costs something.
    _tools = HBoxContainer.new()
    _tools.resized.connect(_square_up)
    add_child(_tools)

    _add_tool(&"Save", "Save", "Save this image's stack to a file.\n\nWrites the same JSON a sidecar holds, so a saved stack can be\nkept as a preset, edited by hand, or sent to somebody.",
            func() -> void: save_requested.emit())
    _add_tool(&"Load", "Load", "Replace this image's stack with the one in a saved stack file.\n\nWhat is in the stack now is thrown away. History keeps it, so a\nload can be rewound like any other change.",
            func() -> void: load_requested.emit())
    _add_tool(&"ActionCopy", "Copy", "Copy every operation in this image's stack to the clipboard,\nsettings and all.\n\nThe clipboard gets the same JSON a sidecar holds, so a copied\nstack can be pasted into a text file and kept.",
            func() -> void: copy_requested.emit())
    _add_tool(&"ActionPaste", "Paste", "Add every operation on the clipboard to the bottom of this\nimage's stack.\n\nAdds rather than replaces, so pasting onto a stack that already\nhas something in it keeps both. Remove the rows you don't want.",
            func() -> void: paste_requested.emit())
    _add_tool(&"Reload", "Reset", "Throw this image's stack away and start again from the default.\n\nAsks first, and takes the image's edit history with it — a reset\nis not something History can rewind past.",
            func() -> void: reset_requested.emit())

    # The entries are cards standing off the panel, so they need room above and below
    # to read as separate things rather than as one block with lines in it.
    var inset := MarginContainer.new()
    inset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    for side in ["margin_top", "margin_bottom"]:
        inset.add_theme_constant_override(side, ENTRY_MARGIN)
    add_child(inset)

    _list = VBoxContainer.new()
    _list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _list.add_theme_constant_override("separation", ENTRY_GAP)
    inset.add_child(_list)

    _refresh_selector()


## Fills the dropdown from [member operation_scripts].
##
## Every operation stays offered however many are already in the stack, because a
## second one of anything is a legitimate thing to want.
func _refresh_selector() -> void:
    if _selector == null:
        return
    _selector.clear()
    for path: String in operation_scripts:
        var script: Script = load(path)
        if script == null:
            continue
        var probe: IWOperation = script.new()
        _selector.add_item(probe.get_operation_name())
        _selector.set_item_metadata(_selector.item_count - 1, path)
    if _selector.item_count > 0:
        _selector.selected = 0


## Adds the operation at [param index]. Every pick arrives here, including a pick of the
## one already showing.
func _on_pick(index: int) -> void:
    if _selector == null or index < 0 or index >= _selector.item_count:
        return
    var path: Variant = _selector.get_item_metadata(index)
    if not (path is String):
        return
    var script: Script = load(path)
    if script == null:
        return
    add_stage(script.new())
    stack_changed.emit()


## Appends [param stage] to the stack and rebuilds.
func add_stage(stage: IWStackOperation) -> void:
    _entries.append({"uid": _take_uid(), "stage": stage, "entry": null})
    rebuild()


## Appends [param stages] to the stack in order, rebuilds once, and announces it.
##
## It announces and [method add_stage] does not, which looks inconsistent and is not:
## a pick from the dropdown appends and then emits from its own handler, so the append
## there is half an action. A paste is the whole of one, and there is no second half to
## do the telling.
##
## One rebuild for the lot rather than one apiece — every entry's form is thrown away
## and rebuilt each time, and pasting a six-stage stack would otherwise do that six
## times to arrive at the same place.
func add_stages(stages: Array) -> void:
    if stages.is_empty():
        return
    for stage: IWStackOperation in stages:
        _entries.append({"uid": _take_uid(), "stage": stage, "entry": null})
    rebuild()
    stack_changed.emit()


## Replaces the whole stack with [param stages], in order.
func set_stages(stages: Array) -> void:
    _entries.clear()
    for stage: IWStackOperation in stages:
        _entries.append({"uid": _take_uid(), "stage": stage, "entry": null})
    rebuild()


## The live operations, in stack order.
func stages() -> Array[IWStackOperation]:
    var out: Array[IWStackOperation] = []
    for record: Dictionary in _entries:
        out.append(record["stage"])
    return out


## The entry controls, in stack order.
func entries() -> Array:
    var out := []
    for record: Dictionary in _entries:
        if record["entry"] != null:
            out.append(record["entry"])
    return out


func is_empty() -> bool:
    return _entries.is_empty()


## Rebuilds every row from the stack.
##
## Wholesale rather than in place, which is safe because the operations and their
## settings live in [member _entries] rather than in the controls — a rebuilt form is
## repointed at the same objects it was showing before.
func rebuild() -> void:
    if _list == null:
        _build()
    for child in _list.get_children():
        _list.remove_child(child)
        child.queue_free()

    for record: Dictionary in _entries:
        var entry: Control = StackEntry.new()
        _list.add_child(entry)
        entry.setup(record["stage"], record["uid"], bool(fold_state.get(record["uid"], false)))
        entry.remove_requested.connect(_on_remove)
        entry.reorder_requested.connect(_on_reorder)
        entry.enabled_toggled.connect(func(_e: Control, _on: bool) -> void: stack_changed.emit())
        entry.setting_changed.connect(func(_e: Control) -> void: setting_changed.emit())
        record["entry"] = entry
        if form_builder.is_valid():
            form_builder.call(record["stage"], entry.settings_box(), entry, record["uid"])
        # After the form exists, not before: a switched-off entry has to hand its
        # controls over disabled, and there were none to disable until now.
        entry.refresh_enabled_state()

    entries_rebuilt.emit()


## Captures which entries are folded, so a rebuild does not open them all.
func capture_folds() -> void:
    for record: Dictionary in _entries:
        var entry: Control = record["entry"]
        if entry != null:
            fold_state[record["uid"]] = entry.is_folded()


func _on_remove(entry: Control) -> void:
    capture_folds()
    for i in _entries.size():
        if _entries[i]["entry"] == entry:
            fold_state.erase(_entries[i]["uid"])
            _entries.remove_at(i)
            break
    rebuild()
    stack_changed.emit()


## Moves the dragged entry to just above or below the one it was dropped on.
##
## The removal happens before the target is located again, so the insertion point is
## computed against the list the entry is no longer in — otherwise dragging downwards
## lands one place short of where the indicator was drawn.
func _on_reorder(from_uid: int, to_uid: int, above: bool) -> void:
    if from_uid == to_uid:
        return
    capture_folds()

    var moving: Variant = null
    for i in _entries.size():
        if _entries[i]["uid"] == from_uid:
            moving = _entries[i]
            _entries.remove_at(i)
            break
    if moving == null:
        return

    var target := _entries.size()
    for i in _entries.size():
        if _entries[i]["uid"] == to_uid:
            target = i if above else i + 1
            break
    _entries.insert(target, moving)

    rebuild()
    stack_changed.emit()


func _take_uid() -> int:
    var uid := _next_uid
    _next_uid += 1
    return uid
