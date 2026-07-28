extends SceneTree

## The stack entry's grab handle: what starts a drag and what does not.
##
## Worth a test of its own because the failure it guards against is not a crash but a
## gesture that works about one try in four, which is the kind of thing that gets lived
## with rather than reported.
##
## A drag is not offered until the pointer has travelled about ten pixels, so where the
## press began and where the pointer is by then are different places — and the handle is
## narrow enough that they are usually on opposite sides of its edge. Asking the live
## position turned most real drags down. These cases pin the press position as the one
## that decides.
##
## Runs over one real frame, because a handle has no rectangle until the containers have
## laid out and the whole question here is which rectangle a point falls in.
##
## [b]It prints "gui_is_dragging() is true" once per accepted case, and that is not a
## defect here.[/b] Offering a drag sets a preview, and setting one outside a drag the
## viewport actually started is a thing Godot complains about. Nothing is dragging
## because nothing is holding a mouse button — the calls are made directly. The exit
## code is what to read.
##
## Run it:
## [codeblock]
## godot --headless --path . --script res://tests/iw_stack_entry.gd
## [/codeblock]

const EntryScript := preload("res://addons/image_wrangler/ui/iw_stack_entry.gd")
const OP_REMOVE_LINES := "res://addons/image_wrangler/core/remove_lines.gd"

var _failures := 0
var _entry: Control
var _frames := 0


func _initialize() -> void:
    var stage: IWStackOperation = load(OP_REMOVE_LINES).new()
    _entry = EntryScript.new()
    # Sized and rooted before setup, so the header has somewhere to lay out into.
    _entry.set_size(Vector2(260, 0))
    get_root().add_child(_entry)
    _entry.setup(stage, 1, false)


## Two frames: one for the containers to sort, one to be sure they have.
func _process(_delta: float) -> bool:
    _frames += 1
    if _frames < 2:
        return false
    _check()
    quit(1 if _failures > 0 else 0)
    return true


func _check() -> void:
    var handle: Control = _entry._handle
    if not _expect(handle != null, "the entry built no handle"):
        return

    var rect := handle.get_global_rect()
    _expect(rect.size.x >= 20.0,
            "the handle is %.0f px wide, which is a small thing to aim at" % rect.size.x)
    _expect(rect.size.y > 0.0, "the handle has no height, so nothing laid out")

    # Where the press begins, in the entry's own coordinates — which is what Godot hands
    # _get_drag_data.
    var origin := _entry.get_global_position()
    var middle := rect.get_center() - origin

    var payload: Variant = _entry._get_drag_data(middle)
    if _expect(payload is Dictionary, "a press in the middle of the handle started no drag"):
        var data: Dictionary = payload
        _expect(String(data.get("type", "")) == "iw_stack_entry",
                "the drag payload is not a stack entry")
        _expect(int(data.get("uid", -1)) == 1, "the drag payload carries the wrong entry")

    # Every corner of the handle, a shade inside it. These are the presses the old code
    # turned down: from any of them, ten pixels of travel lands outside the handle.
    for corner: Vector2 in [
        rect.position + Vector2(1, 1),
        rect.position + Vector2(rect.size.x - 1, 1),
        rect.position + Vector2(1, rect.size.y - 1),
        rect.position + Vector2(rect.size.x - 1, rect.size.y - 1),
    ]:
        _expect(_entry._get_drag_data(corner - origin) is Dictionary,
                "a press at %s inside the handle started no drag" % str(corner - origin))

    # And the thing the restriction is for: a press on the form below must not start a
    # reorder, or every slider in the entry would drag the entry instead.
    for away: Vector2 in [
        middle + Vector2(rect.size.x, 0.0),
        middle + Vector2(0.0, rect.size.y + 4.0),
        Vector2(_entry.size.x - 4.0, middle.y),
    ]:
        _expect(_entry._get_drag_data(away) == null,
                "a press at %s outside the handle started a drag" % str(away))

    if _failures == 0:
        print("Stack entry OK — the handle drags from anywhere in it, and only from it.")


func _expect(condition: bool, message: String) -> bool:
    if not condition:
        printerr("FAIL: %s" % message)
        _failures += 1
    return condition
