@tool
class_name IWStackItem
extends IWOperation

## Anything the dock draws as a card in a reorderable column.
##
## Two stacks are built out of this. [IWStackOperation] is one stage of a run over an
## image; [IWNormalLayer] is one pass of the normal map generator. They have nothing in
## common about what they do — one works on an [IWPipelineContext], the other turns a
## packed sheet into a map — so the only thing here is what the card itself reads: a
## tick, a fold, a colour and a line of prose.
##
## [b]This exists so [IWStackView] and [IWStackEntry] can be one pair of files rather than
## two.[/b] Everything else about them is already generic: the settings form is built
## through a Callable the dock supplies, and the entries are keyed by a uid of their own
## rather than by anything the operation knows.

## Whether this item runs at all.
##
## Held here rather than as a setting, because it is a fact about the stack rather
## than about the operation — the dock draws it as a tick on the entry's header and
## saves it beside the settings rather than inside them. Switching one off
## keeps everything dialled into it, which deleting the entry would not.
var enabled := true

## Whether the dock draws this item's settings folded away.
##
## Held here beside [member enabled] for the same reason: it is a fact about the entry
## rather than about the operation, and it is saved beside the settings rather than
## inside them.
var folded := false


## The colour this item's card is tinted towards, and its marks are drawn in.
##
## Each subclass writes its own out as a [code]TINT[/code] constant, so an item is the same
## colour in every session and on every image. White here, which is what every mark used to
## be, for anything that has not named one.
func get_tint() -> Color:
    return Color.WHITE


## A line or two saying what this item does, for the card's title tooltip.
##
## Empty for anything whose name is the whole of it. Worth writing where a column of
## names alone would not be enough to pick between them.
func get_description() -> String:
    return ""
