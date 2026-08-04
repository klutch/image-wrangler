@tool
class_name IWPromptSwatch
extends Resource

## One saved prompt pair, worn as a coloured square under the Prompt group's boxes.

## What the two boxes held when it was saved.
@export var positive: String = ""
@export var negative: String = ""

## The colour the square is drawn with. Drawn at random when the swatch is made; it is
## only a face for telling swatches apart and means nothing.
@export var color: Color = Color.WHITE
