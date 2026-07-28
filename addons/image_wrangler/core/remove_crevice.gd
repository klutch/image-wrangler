@tool
class_name RemoveCrevice
extends IWStackOperation

## Squeezes the background into nooks whose opening is too narrow for it to have
## flooded on its own.
##
## The opening of a nook between two walls of a subject is often not background at all
## but the antialiasing of the two walls meeting over it — no pixel there is within any
## key's tolerance, so the flood stops at the mouth and the nook stays opaque. This
## crosses that neck: it is Canny's double threshold applied to region growing rather
## than to edge linking, and the rule itself lives in
## [method IWPipelineContext.flood_key_for], shared with every other flood in the run.
##
## [b]It is a pass rather than a rule inside one flood[/b], which is the second time
## this has been tried. The objection last time was that a squeeze has to be measured
## against the tolerance of whichever colour is doing the squeezing, and only the flood
## knew which one that was. It is not the flood that knows: [member
## IWPipelineContext.key_of] has recorded the claiming key per pixel since the
## classification was built, so seeding from the background as it already stands gives
## every seed the key it was claimed by and every squeeze happens on that colour's own
## terms. A pass afterwards can do exactly what the rule inside the flood did.
##
## [b]Two of these in a row on the same settings are one of them at twice the reach.[/b]
## Each pass gets a budget of [member RemoveCreviceSettings.crevice_reach] per path,
## spent and never refunded, and the next seeds from where the last one stopped — see
## [member IWPipelineContext.strayed] — so the budgets simply add up. Measured across a
## 2-pixel neck, a 3-pixel neck, and two 1-pixel necks with a pocket between them, two
## passes at a reach of one entered every one of them to exactly the pixel a single
## pass at a reach of two did.
##
## What two of them do express is [i]where[/i] and [i]on what terms[/i]: a tight pass
## before an [IslandPickerOp] and a looser one after it are two different rules at two
## different points in the stack, which one stage cannot be. Stacking two identical
## ones is a slower way of writing a larger number.
##
## [b]It declares the rule for everything below it.[/b] The reach and the tolerance go
## onto the context, so an [IslandPickerOp] under this squeezes on the same terms. That
## is deliberate: an island getting into a gap the pass beside it could not would be
## arbitrary. A stack with none of these in it has no crevice rule anywhere.
##
## [b]Everything it claims goes to the matte, not to the cut.[/b] A pixel beside
## background and inside its tolerance would have been flooded already, so anything
## this stage reaches it reached by straying, and straying is not proof of background.
## Marking it edge hands it to the usual coverage maths, which decides it by colour:
## background beyond a neck still measures as background and comes out, and subject
## this should never have got to measures as fully covered and keeps its alpha. That is
## what makes setting the reach generously cost work rather than pixels.

var settings: RemoveCreviceSettings


func _init() -> void:
	settings = RemoveCreviceSettings.new()


func get_operation_name() -> String:
	return "Remove Crevice"


func get_operation_id() -> StringName:
	return &"remove_crevice"


func get_settings() -> Resource:
	return settings


func set_settings(new_settings: Resource) -> void:
	var typed := new_settings as RemoveCreviceSettings
	if typed == null:
		push_error("Image Wrangler: RemoveCrevice was handed settings of the wrong type.")
		return
	settings = typed


func make_settings() -> Resource:
	return RemoveCreviceSettings.new()


func get_settings_schema() -> Array[Dictionary]:
	return [
		{
			"property": &"crevice_reach",
			"label": "Crevice Reach",
			"type": SettingType.INT,
			"min": 0,
			"max": 32,
			"step": 1,
			"tooltip": "How many near-background pixels one path may cross in total, so it needs\nto be at least as long as the constriction it has to get through.\n\nA total rather than a count that solid background resets, so the flood\ncannot stray, land on a stray highlight, and use that to buy its way\nfurther in.\n\nBudgets add up across stages: two of these in a row on the same settings\nreach exactly as far as one of them set to twice this, and cost more. Use\ntwo when you want them at different points in the stack or on different\ntolerances, not to reach further.",
		},
		{
			"property": &"crevice_tolerance",
			"label": "Crevice Tolerance",
			"type": SettingType.FLOAT,
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"tooltip": "How much further than its own tolerance a color may stray to get through a\nsqueeze. Added to that tolerance rather than replacing it, so a color keyed\ntightly stays keyed tightly.\n\nOne number for every color in the Remove Background above, because this is\nnot a description of a background — it is how far a flood may leave one\nbehind to get somewhere.",
		},
	]


func stage_weight() -> float:
	return 0.35


## There has to be a background before there is anywhere to squeeze from.
func needs_keying() -> bool:
	return true


func prerequisite_note(ctx: IWPipelineContext) -> String:
	if ctx != null and ctx.has_classification():
		return ""
	return "Needs a Remove Background above it."


func process_context(ctx: IWPipelineContext) -> void:
	# Declared on the context before anything else, and assigned rather than widened:
	# this stage says what the rule is for everything below it, and a second one of
	# these further down says it again. Set even when the stage goes on to do nothing,
	# so switching the reach to zero switches the rule off for the floods below too.
	ctx.crevice_reach = settings.crevice_reach
	ctx.crevice_tolerance = settings.crevice_tolerance
	if settings.crevice_reach <= 0 or not ctx.has_classification():
		return
	if not report_progress(0.05):
		return

	var touched := _squeeze(ctx)
	if touched.is_empty():
		report_progress(1.0)
		return
	if not report_progress(0.70):
		return

	# The regions are re-applied because this moved pixels out of subject and a drawn
	# or picked one has the last word over any flood; then the map naming the nearest
	# subject pixel is stale, and the coverage that reads it with it.
	ctx.apply_regions_to_mask()
	ctx.rebuild_nearest()
	ctx.compute_coverage(ctx.dilate(touched, ctx.search_radius))
	report_progress(1.0)


## Crosses every neck the budget allows and returns every pixel it claimed.
func _squeeze(ctx: IWPipelineContext) -> PackedInt32Array:
	var width := ctx.width
	var height := ctx.height
	var pixel_count := ctx.pixel_count
	var background := IWPipelineContext.MASK_BACKGROUND
	var key_none := IWPipelineContext.KEY_NONE

	var mask := ctx.mask
	var key_of := ctx.key_of
	var strayed := ctx.strayed
	if strayed.size() != pixel_count:
		strayed.resize(pixel_count)

	var touched := PackedInt32Array()
	# Each pixel enters the queue at most once — a seed or a claim, never both, which
	# is what [code]queued[/code] is for — so it can be sized up front and used as a
	# plain FIFO with no wraparound.
	var queue := PackedInt32Array()
	queue.resize(pixel_count)
	var queued := PackedByteArray()
	queued.resize(pixel_count)
	# How many weak pixels the path to each pixel has crossed. Fresh per stage, which
	# is exactly what gives a second one of these a budget of its own.
	var weak_steps := PackedInt32Array()
	weak_steps.resize(pixel_count)
	var head := 0
	var tail := 0

	# Seeded from the background as it already stands, each seed carrying the key that
	# claimed it, so every squeeze is measured on that colour's own terms.
	#
	# Somewhere a previous one of these squeezed to is a seed as well, which is what
	# lets two in a row reach further than one. The rest of the edge band is not: it is
	# the antialiasing of a silhouette rather than somewhere background got to, and
	# seeding from it would walk this stage a pixel into the subject everywhere at
	# once, every time it ran.
	#
	# A pixel that arrived transparent has no key to squeeze on and is skipped, the way
	# it is skipped by the band pass for the same reason.
	for i in pixel_count:
		if key_of[i] < 0:
			continue
		if mask[i] != background and strayed[i] == 0:
			continue
		queued[i] = 1
		queue[tail] = i
		tail += 1

	# 4-connected on purpose: 8-connectivity leaks through diagonal hairlines in thin
	# subjects such as lettering or wire-frame art. Written out four times for the
	# reason given in [method RemoveBackground._classify].
	while head < tail:
		var index := queue[head]
		head += 1
		var claimed_by := key_of[index]
		if claimed_by < 0:
			continue
		var weak_here := weak_steps[index]
		var x := index % width
		@warning_ignore("integer_division")
		var y := index / width
		if x > 0:
			var left := index - 1
			if queued[left] == 0 and mask[left] != background:
				var took := ctx.flood_key_for(left, claimed_by, weak_here)
				if took != key_none:
					queued[left] = 1
					mask[left] = background
					key_of[left] = took
					weak_steps[left] = ctx.flood_weak
					touched.append(left)
					queue[tail] = left
					tail += 1
		if x < width - 1:
			var right := index + 1
			if queued[right] == 0 and mask[right] != background:
				var took := ctx.flood_key_for(right, claimed_by, weak_here)
				if took != key_none:
					queued[right] = 1
					mask[right] = background
					key_of[right] = took
					weak_steps[right] = ctx.flood_weak
					touched.append(right)
					queue[tail] = right
					tail += 1
		if y > 0:
			var up := index - width
			if queued[up] == 0 and mask[up] != background:
				var took := ctx.flood_key_for(up, claimed_by, weak_here)
				if took != key_none:
					queued[up] = 1
					mask[up] = background
					key_of[up] = took
					weak_steps[up] = ctx.flood_weak
					touched.append(up)
					queue[tail] = up
					tail += 1
		if y < height - 1:
			var down := index + width
			if queued[down] == 0 and mask[down] != background:
				var took := ctx.flood_key_for(down, claimed_by, weak_here)
				if took != key_none:
					queued[down] = 1
					mask[down] = background
					key_of[down] = took
					weak_steps[down] = ctx.flood_weak
					touched.append(down)
					queue[tail] = down
					tail += 1

	ctx.mask = mask
	ctx.key_of = key_of
	if touched.is_empty():
		return touched

	# Everything here was reached by straying — a pixel beside background and inside
	# its tolerance would have been flooded already — so all of it is handed to the
	# coverage maths rather than cut out, and remembered as somewhere a squeeze got to
	# so the next one of these can carry on from it.
	for i in touched:
		if weak_steps[i] > 0 and key_of[i] >= 0:
			mask[i] = IWPipelineContext.MASK_EDGE
			strayed[i] = 1
	ctx.mask = mask
	ctx.strayed = strayed

	# The band has to grow from what this opened, or a nook would have a hard rim where
	# every other edge in the image has a matte.
	touched.append_array(ctx.grow_edge_band(touched, ctx.edge_width))
	return touched
