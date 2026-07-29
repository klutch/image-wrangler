extends SceneTree

## The rows every list control in the dock is built out of.
##
## Worth a file of its own because it is the one piece of interface shared by all five of
## them: the island picker, the colour list, the polygons, the HSV regions and the brush
## all hand it row data and get back indices, so a mistake here is a mistake in five
## places at once. It is also the only one of them that can be built headless — the others
## are made of [EditorSpinSlider], which needs the real editor.
##
## Run it:
## [codeblock]
## godot --headless --path . --script res://tests/iw_entry_list.gd
## [/codeblock]

const EntryList := preload("res://addons/image_wrangler/ui/iw_entry_list.gd")

var _failures := 0


func _initialize() -> void:
    await _check_remove_cross()
    await _check_selection()

    if _failures == 0:
        print("Entry List OK — the cross removes the row it sits on and nothing else.")
    quit(1 if _failures > 0 else 0)


# --- The remove cross --------------------------------------------------

func _check_remove_cross() -> void:
    var list: Control = _build()
    var removed := []
    var selected := []
    var toggled := []
    list.remove_requested.connect(func(i: int) -> void: removed.append(i))
    list.row_selected.connect(func(i: int) -> void: selected.append(i))
    list.enabled_toggled.connect(func(i: int, on: bool) -> void: toggled.append([i, on]))
    await process_frame

    var cross: Button = _cross_of(list, 1)
    if not _expect(cross != null, "the middle row has no remove cross"):
        list.queue_free()
        return

    _expect(cross.text == EntryList.REMOVE_GLYPH,
            "the cross is drawn as '%s' rather than the glyph" % cross.text)
    _expect(cross.flat, "the cross is not flat — a list of eight would read as eight buttons")
    # Grey at rest, white under the pointer. Read back off the button rather than compared
    # to the constants twice, so a colour set on the wrong override shows up here.
    _expect(cross.get_theme_color(&"font_color") == EntryList.REMOVE_COLOR,
            "the cross is not grey at rest")
    _expect(cross.get_theme_color(&"font_hover_color") == EntryList.REMOVE_HOVER_COLOR,
            "the cross does not turn white under the pointer")

    cross.pressed.emit()
    _expect(removed == [1], "the cross reported %s rather than its own row" % [removed])
    # The cross sits inside the row, and the row is the hit target for selecting. A Button
    # stops the click reaching it, and this is what says so.
    _expect(selected.is_empty(), "clicking the cross also changed the selection")
    _expect(toggled.is_empty(), "clicking the cross also toggled the row")

    # It goes dead with the rest of the row when the stack entry is switched off, and comes
    # back with it — the failure that once left a disabled entry with a working Remove.
    list.set_interactive(false)
    _expect(cross.disabled, "the cross stayed live on a switched-off entry")
    cross.pressed.emit()
    _expect(removed.size() == 1, "a disabled cross still reported")

    list.set_interactive(true)
    cross.pressed.emit()
    _expect(removed.size() == 2, "the cross did not come back when the entry did")

    list.queue_free()


# --- Selection still behaves -------------------------------------------

## The cross is a new control inside a row that was already the hit target for selecting,
## so the thing most likely to break is the thing it sits in.
func _check_selection() -> void:
    var list: Control = _build()
    var selected := []
    list.row_selected.connect(func(i: int) -> void: selected.append(i))
    await process_frame

    var row: Control = list._rows[2]
    row.gui_input.emit(_click())
    _expect(selected == [2], "clicking a row selected %s" % [selected])
    _expect(list.selected_index() == 2, "the list does not agree about what is selected")

    # Clicking the highlighted row clears it, which is the only way back to nothing
    # selected without reaching elsewhere.
    row.gui_input.emit(_click())
    _expect(selected == [2, -1], "clicking the selected row did not clear it (%s)" % [selected])

    list.queue_free()


# --- Fixtures ----------------------------------------------------------

func _build() -> Control:
    var list: Control = EntryList.new()
    list.configure(true)
    root.add_child(list)
    list.set_rows([
        {"color": Color.RED, "text": "one", "enabled": true, "mode": 0},
        {"color": Color.GREEN, "text": "two", "enabled": true, "mode": 1},
        {"color": Color.BLUE, "text": "three", "enabled": false, "mode": 0},
    ])
    return list


## Reaches past the private names, the way the other tests here reach into a context's
## buffers. Exposing an accessor that exists only to be tested would be the worse trade.
func _cross_of(list: Control, index: int) -> Button:
    var rows: Array = list._rows
    if index < 0 or index >= rows.size():
        return null
    return rows[index].get_meta(&"remove") as Button


func _click() -> InputEventMouseButton:
    var event := InputEventMouseButton.new()
    event.button_index = MOUSE_BUTTON_LEFT
    event.pressed = true
    return event


# --- Reporting ---------------------------------------------------------

func _expect(condition: bool, message: String) -> bool:
    if not condition:
        printerr("FAIL: %s" % message)
        _failures += 1
    return condition
