@tool
class_name IWCompose
extends RefCounted

## Writes an [IWPipelineContext] out as an image, once, after every stage has had
## its say.
##
## Deferred to the end rather than done by whichever stage happens to be last,
## because un-blending and colour bleed both need to read the source colours a
## stage may have decided are only partly there. Doing it early would hand the next
## stage a result to work on instead of the original, and the stack would stop
## being reorderable.
##
## Alpha comes from [member IWPipelineContext.coverage] times the alpha the source
## arrived with. Colour is the source's, un-blended back out of the background
## where the fringe removal asks for it, replaced by the nearest subject colour
## where the bleed does, and painted over by the stroke last of all.
##
## Never instantiated — [code]IWCompose.compose(ctx)[/code] is the whole interface.

## Below this coverage the un-blend divides by such a small number that it
## amplifies source noise into confetti, so its result is faded into the nearest
## known subject colour instead.
const _DECONTAMINATE_FADE := 0.25


## The finished image.
##
## Every buffer but [member IWPipelineContext.data] is optional. A context nothing
## keyed still composes: coverage falls back to fully opaque, the fringe removal
## and the bleed both stand down for want of a key to measure against, and what
## comes out is the source with whatever the drawn regions and the stroke did to
## it.
static func compose(ctx: IWPipelineContext) -> Image:
	ctx.ensure_coverage()
	# A safety net, not the usual route. Whichever stage draws the stroke folds these
	# in first, because the stroke has to follow the silhouette they produce — but a
	# stack with nothing stroking it would otherwise leave a drawn shape undone. The
	# call is idempotent, so doing it twice costs a pass and changes nothing.
	ctx.apply_regions_to_coverage()

	var data := ctx.data
	var coverage := ctx.coverage
	var key_of := ctx.key_of
	var nearest := ctx.nearest
	var inner := ctx.stroke_inner
	var outer := ctx.stroke_outer
	var stroke_colors := ctx.stroke_colors
	var force_opaque := ctx.force_opaque

	var bleed_radius := ctx.bleed_radius
	var stroke_color := ctx.stroke_color
	var has_inner := not inner.is_empty()
	var has_outer := not outer.is_empty()
	var auto_colors := not stroke_colors.is_empty()
	var has_keys := not ctx.keys.is_empty()
	var has_key_of := not key_of.is_empty()
	var has_nearest := not nearest.is_empty()
	var has_force := not force_opaque.is_empty()
	# Nothing to un-blend against without a key. The setting stays on; it simply
	# describes work that cannot be done here, the same way it describes no work
	# for a pixel that came out fully covered.
	var decontaminate := ctx.decontaminate and has_keys
	# Stand-in for a pixel no flood ever claimed. Only reachable once refinement
	# or the alpha clip has pulled a subject pixel below full coverage, since
	# nothing else leaves an unclaimed pixel needing to be un-blended.
	var fallback_key := ctx.keys[0] if has_keys else Color.BLACK

	var pixel_count := ctx.pixel_count
	var out := PackedByteArray()
	out.resize(pixel_count * 4)
	var to_unit := 1.0 / 255.0

	for i in pixel_count:
		var offset := i * 4
		var r := data[offset] * to_unit
		var g := data[offset + 1] * to_unit
		var b := data[offset + 2] * to_unit
		var source_alpha := data[offset + 3] * to_unit
		var neighbour := nearest[i] if has_nearest else -1
		var alpha := coverage[i]
		# Whichever background claimed this pixel is the one to un-blend.
		var k := key_of[i] if has_key_of else IWPipelineContext.KEY_NONE
		var pixel_key: Color = ctx.keys[k] if k >= 0 else fallback_key

		if alpha <= 0.0:
			alpha = 0.0
			if bleed_radius > 0 and neighbour >= 0:
				var bleed_offset := neighbour * 4
				r = data[bleed_offset] * to_unit
				g = data[bleed_offset + 1] * to_unit
				b = data[bleed_offset + 2] * to_unit
		elif alpha < 1.0 and decontaminate:
			var inverse := 1.0 / alpha
			var rest := 1.0 - alpha
			var pure_r := clampf((r - rest * pixel_key.r) * inverse, 0.0, 1.0)
			var pure_g := clampf((g - rest * pixel_key.g) * inverse, 0.0, 1.0)
			var pure_b := clampf((b - rest * pixel_key.b) * inverse, 0.0, 1.0)
			if alpha < _DECONTAMINATE_FADE and neighbour >= 0:
				var weight := alpha / _DECONTAMINATE_FADE
				var bleed_offset := neighbour * 4
				r = lerpf(data[bleed_offset] * to_unit, pure_r, weight)
				g = lerpf(data[bleed_offset + 1] * to_unit, pure_g, weight)
				b = lerpf(data[bleed_offset + 2] * to_unit, pure_b, weight)
			else:
				r = pure_r
				g = pure_g
				b = pure_b

		# Last, and on the colour only. Everything above is still working out what
		# the subject's own colour was; the stroke is paint going on top of the
		# answer, and it must not be un-blended or bled as if it were part of the
		# image. Alpha is untouched — an inside stroke draws on the silhouette
		# rather than adding to it.
		var paint := stroke_color
		if auto_colors:
			var slot := i * 3
			paint = Color(stroke_colors[slot], stroke_colors[slot + 1], stroke_colors[slot + 2])

		if has_inner:
			var over := inner[i]
			if over > 0.0:
				r = lerpf(r, paint.r, over)
				g = lerpf(g, paint.g, over)
				b = lerpf(b, paint.b, over)

		var out_alpha := 1.0 if has_force and force_opaque[i] != 0 \
				else clampf(source_alpha * alpha, 0.0, 1.0)

		# The outer stroke goes *under* what is already here, which is what keeps it
		# from eating the soft edge it is meant to sit behind. Standard over-
		# compositing with the subject on top, so where the subject is solid the
		# stroke contributes nothing and where there is nothing it contributes all.
		if has_outer:
			var behind := outer[i]
			if behind > 0.0:
				var combined := out_alpha + behind * (1.0 - out_alpha)
				if combined > IWPipelineContext.EPSILON:
					var share := behind * (1.0 - out_alpha)
					r = (r * out_alpha + paint.r * share) / combined
					g = (g * out_alpha + paint.g * share) / combined
					b = (b * out_alpha + paint.b * share) / combined
				out_alpha = combined

		out[offset] = roundi(clampf(r, 0.0, 1.0) * 255.0)
		out[offset + 1] = roundi(clampf(g, 0.0, 1.0) * 255.0)
		out[offset + 2] = roundi(clampf(b, 0.0, 1.0) * 255.0)
		out[offset + 3] = roundi(clampf(out_alpha, 0.0, 1.0) * 255.0)

	return Image.create_from_data(ctx.width, ctx.height, false, Image.FORMAT_RGBA8, out)
