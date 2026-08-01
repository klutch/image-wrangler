@tool
extends VBoxContainer

## The Exclude Tiles rows: a Pick button and one row per tile chosen.
##
## Modelled on [IWIslandPicker], and simpler in one way and stranger in another. Simpler
## because a pick carries nothing to tune — it is a point on a tile and that is all.
## Stranger because what it asks the preview to outline is not its own rows: it is every
## tile the last run found, chosen or not, since a tile that has been removed is no longer
## in the picture to be clicked and its outline is the only thing left to aim at.

## Raised when the Pick button is pressed, so the dock can arm the preview and put every
## other picker down.
signal pick_toggled(enabled: bool)

## Raised when the chosen tiles change, so the dock can run again and redraw.
signal tiles_changed

## Raised when the highlighted row changes.
signal selection_changed

const ToolButton := preload("res://addons/image_wrangler/ui/iw_tool_button.gd")
const EntryList := preload("res://addons/image_wrangler/ui/iw_entry_list.gd")

var _operation: IWOperation
var _property: StringName

## Whether the stack entry this sits in is switched on.
var _interactive := true

var _list: EntryList
var _pick_button: Button
var _clear_button: Button
var _hint: Label


func setup(operation: IWOperation, property: StringName) -> void:
    _operation = operation
    _property = property
    _build()
    _refresh()


func _build() -> void:
    var buttons := HBoxContainer.new()
    add_child(buttons)

    _pick_button = Button.new()
    _pick_button.text = "Pick"
    _pick_button.toggle_mode = true
    _pick_button.tooltip_text = "Click a tile on the preview to pick it, or drag a rectangle to pick every\ntile it touches. Clicking a tile that is already picked lets it go again.\n\nEvery tile is outlined, including the ones this has removed, so there is\nalways something to click.\n\nPress H over the dock to show or hide the outlines."
    _pick_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _pick_button.toggled.connect(func(pressed: bool) -> void: pick_toggled.emit(pressed))
    buttons.add_child(_pick_button)

    _clear_button = Button.new()
    _clear_button.text = "Clear"
    _clear_button.tooltip_text = "Let every picked tile go."
    _clear_button.pressed.connect(_on_clear_pressed)
    buttons.add_child(_clear_button)

    _list = EntryList.new()
    _list.configure(false)
    _list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _list.row_selected.connect(func(_index: int) -> void: selection_changed.emit())
    _list.enabled_toggled.connect(_on_enabled_toggled)
    _list.remove_requested.connect(_remove_pick)
    add_child(_list)

    _hint = Label.new()
    _hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _hint.modulate = Color(1, 1, 1, 0.6)
    _hint.visible = false
    add_child(_hint)


func _notification(what: int) -> void:
    if what == NOTIFICATION_THEME_CHANGED and _pick_button != null:
        ToolButton.apply_pick_icon(_pick_button)
        ToolButton.style_armed(_pick_button)


# --- What the preview draws ---------------------------------------------

## Every tile the last run found, chosen or not. See the class note for why.
func get_islands() -> Array[Rect2i]:
    var settings := _settings()
    return settings.found_bounds.duplicate() if settings != null else [] as Array[Rect2i]


## Which of those tiles survive, so the ones on their way out are faded. The same channel a
## switched-off island uses, saying the same sort of thing — this is not acting on the
## result any more.
func get_enabled_flags() -> PackedByteArray:
    var out := PackedByteArray()
    var settings := _settings()
    if settings == null:
        return out
    for tile in settings.found_bounds.size():
        out.append(1 if settings.survives(tile) else 0)
    return out


## All of them, so every tile draws dashed: these are what a run found rather than
## rectangles anybody drew.
func get_flooded_flags() -> PackedByteArray:
    var out := PackedByteArray()
    var settings := _settings()
    if settings == null:
        return out
    out.resize(settings.found_bounds.size())
    out.fill(1)
    return out


## Which tile is highlighted, as an index into the outlines rather than into the rows.
##
## The dock emphasises one marker and counts in markers, and the markers here are tiles.
## A row whose pick landed on nothing highlights nothing.
func selected_index() -> int:
    var settings := _settings()
    if settings == null:
        return -1
    var row := _list.selected_index()
    if row < 0 or row >= settings.picks.size():
        return -1
    var pick: TilePick = settings.picks[row]
    return pick.tile if pick != null else -1


# --- Picking ------------------------------------------------------------

## Takes or lets go of every tile [param region] touches, and says how many changed.
##
## A click arrives as a one by one rectangle, so picking one tile and sweeping several are
## the same gesture. Toggling rather than adding, because the outline of a tile already
## chosen is the only way back once it has been removed from the picture.
func toggle_tiles(region: Rect2i) -> int:
    var settings := _settings()
    if settings == null or region.size.x <= 0 or region.size.y <= 0:
        return 0
    if settings.found_bounds.is_empty():
        _set_hint("No tiles found yet. Let the preview finish, then pick.")
        return 0

    var changed := 0
    for tile in settings.found_bounds.size():
        var bounds: Rect2i = settings.found_bounds[tile]
        if bounds.size.x <= 0 or bounds.size.y <= 0 or not region.intersects(bounds):
            continue
        var existing := settings.pick_on(tile)
        if existing >= 0:
            settings.picks.remove_at(existing)
        else:
            var pick := TilePick.new()
            # The middle of the tile rather than where the click landed, so a row names
            # somewhere on the tile even when the sweep only clipped its corner.
            pick.point = bounds.position + bounds.size / 2
            pick.tile = tile
            pick.bounds = bounds
            settings.picks.append(pick)
        changed += 1

    if changed == 0:
        _set_hint("Nothing there. Click a tile's outline.")
        return 0
    _set_hint("")
    _refresh()
    tiles_changed.emit()
    return changed


# --- The rest of the dock's handle on this ------------------------------

func set_controls_enabled(value: bool) -> void:
    _interactive = value
    if _list != null:
        _list.set_interactive(value)
    _update_buttons()


func refresh() -> void:
    _set_hint("")
    _refresh()


## Lets the dock switch picking off without echoing back a [signal pick_toggled].
func set_pick_active(enabled: bool) -> void:
    _pick_button.set_pressed_no_signal(enabled)


# --- Internals ----------------------------------------------------------

## Resolved through the operation every time, so swapping the settings Resource for
## another image needs no re-pointing here.
func _settings() -> ExcludeTilesSettings:
    if _operation == null:
        return null
    return _operation.get_settings() as ExcludeTilesSettings


## Switches one pick on or off, which changes the result and so asks for a run.
func _on_enabled_toggled(index: int, on: bool) -> void:
    var settings := _settings()
    if settings == null or index < 0 or index >= settings.picks.size():
        return
    var pick: TilePick = settings.picks[index]
    if pick == null or pick.enabled == on:
        return
    pick.enabled = on
    _refresh()
    tiles_changed.emit()


func _remove_pick(index: int) -> void:
    var settings := _settings()
    if settings == null or index < 0 or index >= settings.picks.size():
        return
    settings.picks.remove_at(index)
    _refresh()
    tiles_changed.emit()


func _on_clear_pressed() -> void:
    var settings := _settings()
    if settings == null or settings.picks.is_empty():
        return
    settings.picks.clear()
    _refresh()
    tiles_changed.emit()


func _refresh() -> void:
    if _list == null:
        return
    var settings := _settings()
    var rows := []
    if settings != null:
        for i in settings.picks.size():
            rows.append(_row_data(i, settings.picks[i]))
    _list.set_rows(rows)
    _update_buttons()


func _row_data(index: int, pick: TilePick) -> Dictionary:
    var text := "%d.  —" % [index + 1]
    if pick != null:
        if pick.has_tile():
            text = "%d.  (%d, %d)   %d x %d" % [
                index + 1,
                pick.bounds.position.x,
                pick.bounds.position.y,
                pick.bounds.size.x,
                pick.bounds.size.y,
            ]
        else:
            # The pick is still the user's even when the run found nothing under it, so
            # the row stays and says so rather than disappearing.
            text = "%d.  (%d, %d)   not found" % [index + 1, pick.point.x, pick.point.y]
    # The tick is the pick's own switch. A pick that landed on nothing says so in its text.
    return {
        "color": Color(0.55, 0.75, 1.0),
        "text": text,
        "enabled": pick != null and pick.enabled,
    }


## Shows [param text] under the list, or gives the line back when it is empty.
func _set_hint(text: String) -> void:
    _hint.text = text
    _hint.visible = not text.is_empty()


func _update_buttons() -> void:
    var settings := _settings()
    var any := settings != null and not settings.picks.is_empty()
    if _clear_button != null:
        _clear_button.disabled = not (_interactive and any)
    if _pick_button != null:
        _pick_button.disabled = not _interactive
