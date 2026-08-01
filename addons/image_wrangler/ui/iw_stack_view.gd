@tool
extends VBoxContainer

## A stack: a dropdown to add with, and a draggable column of entries.
##
## Holds the live [IWStackItem] instances and their order. The dock owns the
## settings behind them and the running of them; this owns what the stack [i]is[/i].
##
## Two stacks are built out of this — the operations on an image, and the normal map
## generators on the Export tab. Nothing here knows which: what the dropdown offers, what
## a card's form looks like and what any of the tool buttons mean all arrive from the dock.
##
## Duplicates are allowed and mean what they look like — two Polygon Edits are two
## independent sets of shapes, and a second Remove Background adds its colours to the
## keys the first registered. So nothing here is keyed by operation id: entries carry
## a uid of their own, because the id is shared between duplicates and the position is
## exactly what a reorder changes.

const StackEntry := preload("res://addons/image_wrangler/ui/iw_stack_entry.gd")
const ToolButton := preload("res://addons/image_wrangler/ui/iw_tool_button.gd")

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

## Emitted when an entry is folded or unfolded, which is worth saving but changes nothing
## about the picture.
signal fold_changed

## Emitted when the stack is pointed at a different entry.
signal selection_changed

## Emitted after entries are rebuilt, so the dock can rewire what it cached about
## their controls.
signal entries_rebuilt

## Emitted when Copy or Paste is pressed.
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

## Emitted on a right-click over the stack. [param index] is the entry under the pointer,
## or -1 for the empty space below them; [param at] is where a paste would land.
##
## The dock builds the menu, because what it can offer depends on what is on the
## clipboard and only the dock can read that.
signal menu_requested(index: int, at: int)

## What the dropdown offers, in the order it offers them.
##
## One Dictionary per group of [code]{"name": String, "entries": Array}[/code], each entry
## [code]{"script": String, "icon": StringName}[/code]. Built by the dock; see
## Every operation the dropdown offers, in order. See [code]IWPanel.OPERATIONS[/code].
var operations: Array = []

## Called as [code]build(operation, container, on_changed, fold_state, key)[/code] to
## fill one entry's form. Supplied by the dock so this does not have to know about the
## settings builder.
var form_builder := Callable()

## What the dropdown always shows, and what a pick of it means: nothing.
##
## The row the control displays is the row it thinks is chosen, so without a standing entry
## the dropdown would sit there naming whichever item was added last, as though that one
## were somehow current. This is a button wearing a list's clothes.
##
## Set before the view enters the tree, alongside [member operations].
var add_prompt := "Add New Operation"

## What the dropdown says when it is hovered.
var add_tooltip := "Add an operation to the bottom of the stack.\nDrag its header afterwards to move it.\n\nPicking the same one twice adds a second of it, which is what duplicates are for.\nDisabled while no image is open."

## Where a tool button keeps the icon it wants and the word to fall back on.
const META_ICON := &"iw_icon"
const META_LABEL := &"iw_label"

## Smallest a tool button is allowed to get, however narrow the dock is squeezed.
const TOOL_MIN_SIZE := 24

## How near an edge the pointer has to be for a drag to scroll the list, and how fast
## the list runs right at that edge, in pixels a second.
const AUTO_SCROLL_EDGE := 16.0
const AUTO_SCROLL_SPEED := 480.0

## The live stack, in order.
var _entries: Array = []
var _selector: OptionButton
var _list: VBoxContainer
var _tools: HBoxContainer
var _extras: VBoxContainer
var _scroll: ScrollContainer
var _next_uid := 1

## Which entry the stack is pointed at, or 0 for none.
##
## Kept as the row's own number rather than its position, so it survives a reorder and a
## rebuild — the position is exactly what those change.
var _selected_uid := 0

## The part of a pixel this frame's scroll did not add up to.
##
## Carried rather than rounded away, because the scroll position is a whole number and a
## slow scroll would otherwise round down to nothing every frame and never move at all.
var _scroll_carry := 0.0


func _ready() -> void:
    if _list == null:
        _build()


## The editor's icons are not there until this is in a tree, and they change with the
## theme, so the row is dressed again whenever that happens rather than only once.
##
## The dropdown's icons come out of the same theme and go stale the same way, so it is
## rebuilt here too. Rebuilt rather than re-iconed: the rows are made from a list that has
## not changed, so making them again is the same answer for less code than reaching into
## each one.
func _notification(what: int) -> void:
    # A drag anywhere in the editor raises these, so only ours starts the list moving —
    # a file dragged in from the FileSystem dock is not a reorder, and scrolling the
    # stack under it would be a mystery.
    if what == NOTIFICATION_DRAG_BEGIN:
        _scroll_carry = 0.0
        var payload: Variant = get_viewport().gui_get_drag_data()
        set_process(payload is Dictionary
                and String((payload as Dictionary).get("type", "")) == "iw_stack_entry")
        return
    # Always arrives, including when a drag is abandoned, so this cannot be left running.
    if what == NOTIFICATION_DRAG_END:
        set_process(false)
        return
    if what != NOTIFICATION_THEME_CHANGED:
        return
    if _tools != null:
        for child in _tools.get_children():
            if child is Button:
                _dress(child)
    if _selector != null:
        _refresh_selector()


## Runs the list up or down while an entry is dragged near an edge.
##
## On only between the two drag notifications above, and it allocates nothing — a stack
## being dragged is the one moment the dock is doing per-frame work.
func _process(delta: float) -> void:
    if _scroll == null:
        return
    var at := _scroll.get_local_mouse_position()
    # Sideways out of the column is not a request to scroll it.
    if at.x < 0.0 or at.x > _scroll.size.x:
        return

    var speed := 0.0
    if at.y < AUTO_SCROLL_EDGE:
        speed = -_edge_speed(AUTO_SCROLL_EDGE - at.y)
    elif at.y > _scroll.size.y - AUTO_SCROLL_EDGE:
        speed = _edge_speed(at.y - (_scroll.size.y - AUTO_SCROLL_EDGE))
    if is_zero_approx(speed):
        _scroll_carry = 0.0
        return

    _scroll_carry += speed * delta
    var whole := int(_scroll_carry)
    if whole == 0:
        return
    _scroll_carry -= float(whole)
    _scroll.scroll_vertical += whole


## How fast the list runs, given how far past the edge the pointer has reached.
##
## Squared rather than straight, so brushing the edge nudges the list where pushing right
## up against it runs at full speed. Clamped, so holding the pointer outside the dock does
## not keep getting faster.
func _edge_speed(depth: float) -> float:
    var reach := clampf(depth / AUTO_SCROLL_EDGE, 0.0, 1.0)
    return AUTO_SCROLL_SPEED * reach * reach


## One button on the tool row.
##
## The label is the tooltip as well as the word the button falls back on. These do what
## they are called and nothing more, so a sentence explaining one would only be the same
## word again with padding.
func _add_tool(icon: StringName, label: String, on_press: Callable) -> void:
    var button := Button.new()
    button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    button.tooltip_text = label
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
## Three ways down, each a fallback for the one above. The drawn one is what these
## buttons want, since they are square and grow with the dock and the theme's own copy is
## a flat sixteen pixels. The theme's copy still stands behind it in case the artwork is
## ever missing, and the button's own name stands behind that — outside the editor there
## is no icon of either kind to be had, and a row of buttons wearing their names is
## better than a row of errors.
func _dress(button: Button) -> void:
    var icon: StringName = button.get_meta(META_ICON, &"")
    if not icon.is_empty():
        var tint := Color(0.88, 0.88, 0.88)
        if button.has_theme_color(&"font_color", &"Button"):
            tint = button.get_theme_color(&"font_color", &"Button")
        var drawn := ToolButton.build_svg_icon(icon, tint)
        if drawn != null:
            button.icon = drawn
            button.text = ""
            return
        if has_theme_icon(icon, &"EditorIcons"):
            button.icon = get_theme_icon(icon, &"EditorIcons")
            button.text = ""
            return
    button.icon = null
    button.text = String(button.get_meta(META_LABEL, ""))


func _build() -> void:
    # First, because these are the ways a whole stack arrives at once, and the dropdown
    # under them is for adding to whatever they left. Icons rather than names: five of
    # these across a dock this narrow leaves no room for words, and what each one does is
    # the sort of thing an icon says faster than a label anyway.
    #
    # In the order they are reached for — the two that go through a file, the two that go
    # through the clipboard, and then the one that throws everything away, which is last
    # because it is the only one with nothing to bring back what it took.
    _tools = HBoxContainer.new()
    _tools.resized.connect(_square_up)
    add_child(_tools)

    _add_tool(&"Save", "Save", func() -> void: save_requested.emit())
    _add_tool(&"Load", "Load", func() -> void: load_requested.emit())
    _add_tool(&"ActionCopy", "Copy", func() -> void: copy_requested.emit())
    _add_tool(&"ActionPaste", "Paste", func() -> void: paste_requested.emit())
    _add_tool(&"Reload", "Reset", func() -> void: reset_requested.emit())

    # Picking from the list is the whole gesture — there is no button beside it to press
    # afterwards, so the popup's own index_pressed is what this listens to rather than
    # item_selected. item_selected does not fire when the item picked is the one already
    # showing, and adding a second Polygon Edit is an ordinary thing to want.
    _selector = OptionButton.new()
    _selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _selector.tooltip_text = add_tooltip
    _selector.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
    _selector.get_popup().index_pressed.connect(_on_pick)
    add_child(_selector)

    # Empty unless the dock puts something here. See [method extras_box].
    _extras = VBoxContainer.new()
    _extras.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _extras.visible = false
    _extras.child_order_changed.connect(_settle_extras)
    add_child(_extras)

    # [b]The scroll starts here, under the tools and the dropdown rather than above
    # them.[/b] It used to wrap the whole of this view, which meant a stack long enough to
    # scroll took its own Add dropdown off the top of the screen — so adding a second
    # operation meant scrolling back up, picking, and scrolling down again to reach what
    # you had just added. The two things that are always worth reaching are the two that
    # now never move.
    _scroll = ScrollContainer.new()
    var scroll := _scroll
    scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    # The dock column is narrow and the forms inside give rather than overflow, so a
    # sideways bar would only ever be a second thing to nudge past the vertical one.
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    add_child(scroll)

    # The entries are cards standing off the panel, so they need room above and below
    # to read as separate things rather than as one block with lines in it.
    #
    # Both containers are see-through to the mouse. Neither has anything to do with a
    # click, and leaving them solid would swallow every right-click that missed an entry
    # — which is exactly the one that means "paste at the end".
    var inset := MarginContainer.new()
    inset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    inset.mouse_filter = Control.MOUSE_FILTER_IGNORE
    for side in ["margin_top", "margin_bottom"]:
        inset.add_theme_constant_override(side, ENTRY_MARGIN)
    scroll.add_child(inset)

    _list = VBoxContainer.new()
    _list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _list.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _list.add_theme_constant_override("separation", ENTRY_GAP)
    inset.add_child(_list)

    # Off until a drag of ours starts. See _notification.
    set_process(false)
    _refresh_selector()


## Room for controls that belong above the stack but below the dropdown.
##
## Anything put here sits with the tools and the dropdown on the part of the view that never
## scrolls, which is where a control belongs when it is about the whole stack rather than
## about any one card. Hidden while it holds nothing, so a stack that wants none pays no gap
## for it.
func extras_box() -> VBoxContainer:
    if _extras == null:
        _build()
    return _extras


func _settle_extras() -> void:
    if _extras != null:
        _extras.visible = _extras.get_child_count() > 0


## Fills the dropdown from [member operations].
##
## Every item stays offered however many are already in the stack, because a second
## one of anything is a legitimate thing to want.
func _refresh_selector() -> void:
    if _selector == null:
        return
    _selector.clear()
    _selector.add_item(add_prompt)
    for entry: Dictionary in operations:
        var path := String(entry.get("script", ""))
        var script: Script = load(path)
        if script == null:
            continue
        var probe: IWOperation = script.new()
        var icon := ToolButton.theme_icon(_selector, entry.get("icon", &""))
        if icon != null:
            _selector.add_icon_item(icon, probe.get_operation_name())
        else:
            # Outside the editor there is no icon theme to borrow from, and a row with a
            # name on it is still a row that works.
            _selector.add_item(probe.get_operation_name())
        _selector.set_item_metadata(_selector.item_count - 1, path)
    _selector.selected = 0


## Adds the operation at [param index], and goes back to showing the prompt.
func _on_pick(index: int) -> void:
    if _selector == null or index <= 0 or index >= _selector.item_count:
        return
    # Back before the work, so the dropdown is right again even if loading the script
    # fails.
    _selector.selected = 0
    var path: Variant = _selector.get_item_metadata(index)
    if not (path is String):
        return
    var script: Script = load(path)
    if script == null:
        return
    add_stage(script.new())
    stack_changed.emit()


## Appends [param stage] to the stack and rebuilds.
func add_stage(stage: IWStackItem) -> void:
    _entries.append(_record(stage))
    rebuild()


## One row's bookkeeping.
func _record(stage: IWStackItem) -> Dictionary:
    return {"uid": _take_uid(), "stage": stage, "entry": null}


## Puts [param stage] into the stack at [param at], pushing whatever was there down.
func insert_stage(stage: IWStackItem, at: int) -> void:
    _entries.insert(clampi(at, 0, _entries.size()), _record(stage))
    rebuild()
    stack_changed.emit()


## Right-clicks that reached the empty space under the entries, which mean the end of the
## stack. The tools and the dropdown take their own clicks, so this only ever hears the
## column itself.
func _gui_input(event: InputEvent) -> void:
    var button := event as InputEventMouseButton
    if button == null or not button.pressed or button.button_index != MOUSE_BUTTON_RIGHT:
        return
    accept_event()
    menu_requested.emit(-1, _entries.size())


## A right-click on one entry, turned into where a paste would land.
func _on_entry_menu(entry: Control, above: bool) -> void:
    for i in _entries.size():
        if _entries[i]["entry"] == entry:
            menu_requested.emit(i, i if above else i + 1)
            return


## Replaces the whole stack with [param stages], in order.
func set_stages(stages: Array) -> void:
    _entries.clear()
    for stage: IWStackItem in stages:
        _entries.append(_record(stage))
    rebuild()


## The live items, in stack order.
##
## Untyped, because the two stacks built out of this hold different subclasses and a typed
## Array of the base cannot be handed to anything expecting a typed Array of one of them.
func stages() -> Array:
    var out := []
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
    # Before the rows go, since the fold lives on the row until it does. Every rebuild,
    # not only the ones a remove or a reorder started: a fold followed by anything else
    # would otherwise be thrown away.
    capture_folds()
    for child in _list.get_children():
        _list.remove_child(child)
        child.queue_free()

    for record: Dictionary in _entries:
        var entry: Control = StackEntry.new()
        _list.add_child(entry)
        entry.setup(record["stage"], record["uid"], (record["stage"] as IWStackItem).folded)
        entry.remove_requested.connect(_on_remove)
        entry.reorder_requested.connect(_on_reorder)
        entry.enabled_toggled.connect(func(_e: Control, _on: bool) -> void: stack_changed.emit())
        entry.setting_changed.connect(func(_e: Control) -> void: setting_changed.emit())
        entry.fold_changed.connect(func(_e: Control) -> void: fold_changed.emit())
        entry.menu_requested.connect(_on_entry_menu)
        record["entry"] = entry
        if form_builder.is_valid():
            form_builder.call(record["stage"], entry.settings_box(), entry, record["uid"])
        # After the form exists, not before: a switched-off entry has to hand its
        # controls over disabled, and there were none to disable until now.
        entry.refresh_enabled_state()

    _settle_selection()
    entries_rebuilt.emit()


## A press anywhere inside an entry points the stack at it, whatever it landed on.
##
## Read here rather than on the entries, because a press on a slider, a list row or a
## button never reaches the entry holding it — the control takes it, and every one of them
## would have to be wired up again on every rebuild. This sees the press before any of them
## do and only reads where it was, so nothing is taken away from whatever the click was
## actually for.
func _input(event: InputEvent) -> void:
    var button := event as InputEventMouseButton
    if button == null or not button.pressed or button.button_index != MOUSE_BUTTON_LEFT:
        return
    for record: Dictionary in _entries:
        var entry: Control = record["entry"]
        if entry == null or not is_instance_valid(entry) or not entry.is_visible_in_tree():
            continue
        # Asked of the entry itself, so the position and the rectangle are in the same
        # space however the dock is nested.
        if entry.get_global_rect().has_point(entry.get_global_mouse_position()):
            select_uid(record["uid"])
            return


## Whether operations may be added at all.
##
## Off when no image is open: an operation with nothing to act on is a row belonging to
## nobody, and the stack is emptied at the same moment.
func set_can_add(value: bool) -> void:
    if _selector != null:
        _selector.disabled = not value


## Which item the stack is pointed at, or null when it holds none.
func selected_stage() -> IWStackItem:
    for record: Dictionary in _entries:
        if record["uid"] == _selected_uid:
            return record["stage"]
    return null


## Points the stack at the entry numbered [param uid].
func select_uid(uid: int) -> void:
    if _selected_uid == uid:
        return
    _selected_uid = uid
    _paint_selection()
    selection_changed.emit()


## Keeps something selected whenever there is anything to select.
##
## The first entry when the one that was selected has gone, and nothing at all when the
## stack is empty. Called after every rebuild, since that is when entries appear and
## disappear.
func _settle_selection() -> void:
    var wanted := 0
    for record: Dictionary in _entries:
        if record["uid"] == _selected_uid:
            wanted = _selected_uid
            break
    if wanted == 0 and not _entries.is_empty():
        wanted = _entries[0]["uid"]
    var moved := wanted != _selected_uid
    _selected_uid = wanted
    _paint_selection()
    if moved:
        selection_changed.emit()


func _paint_selection() -> void:
    for record: Dictionary in _entries:
        var entry: Control = record["entry"]
        if entry != null and is_instance_valid(entry):
            entry.set_selected(record["uid"] == _selected_uid)


## Copies each row's fold back onto its operation, so a rebuild does not open them all.
##
## The operation is where the fold is kept, so this also puts it somewhere the sidecar
## will save it.
func capture_folds() -> void:
    for record: Dictionary in _entries:
        var entry: Control = record["entry"]
        if entry != null and is_instance_valid(entry):
            (record["stage"] as IWStackItem).folded = entry.is_folded()


func _on_remove(entry: Control) -> void:
    capture_folds()
    for i in _entries.size():
        if _entries[i]["entry"] == entry:
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
