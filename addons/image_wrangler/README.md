# Image Wrangler

An in-editor toolbox for manipulating images. Enable it under
**Project → Project Settings → Plugins**, then pick **Image Wrangler** from the
main screen tabs at the top, alongside **2D**, **3D** and **Script**.

## Using it

1. Add images with the **Add** button, or drag them in from the FileSystem dock.
2. Build a stack of operations and tune them. The preview updates as you drag.
3. **Process Current Only** saves the selected image, asking where to put it.
   **Process All** processes the whole list into a folder you pick, naming each
   output after its source plus the **Suffix**. Results are always PNG, and you
   are asked before anything existing is replaced.

The preview sits on a checkerboard and is drawn unfiltered, so you can see
exactly what happened to the edge pixels.

## The operation stack

The right-hand column has two tabs. **Operations** is a **stack**: a list of
operations run top to bottom, each working on what the ones above it left. Pick one
from the dropdown and press **Create** to add it to the bottom; grab the **≡**
handle on the left of any entry to drag it somewhere else; press the **✕** on the
right to remove it.

Every entry also has a tick. Unticking it stops that operation running while
keeping everything dialled into it, which removing the entry would not.

A fresh image starts with the five that between them do what the old single
operation did:

| Operation | What it does |
| --- | --- |
| **Polygon Edit** | Shapes drawn by hand, forced transparent or opaque |
| **Remove Background** | Keys out flat background colours and mattes the edge |
| **Island Picker** | Regions picked off the preview, removed or protected |
| **Refine Edges** | Tidies the alpha, then clips its extremes |
| **Edge Cleanup** | Restores hard edges and draws an outline |

**Order matters, and duplicates are allowed.** Two Polygon Edits are two
independent sets of shapes. A second Remove Background adds its colours to the
keys the first registered rather than starting again. Refine Edges above Edge
Cleanup smooths before the outline is measured; below it, after.

Each one leaves a complete result for the next. Where an operation genuinely cannot
do its job from what it has been handed — there is no coverage to refine until
something has keyed — its entry says so on its own face rather than failing, so a
half-built stack is a normal state to be in.

Rename is deliberately **not** in the stack. It does not touch pixels, and its
settings describe the whole batch rather than any one image, so it has a
**Rename** tab of its own beside **Operations** instead.

### Preview and zoom

| Control | What it does |
| --- | --- |
| `-` / `+` | Steps to the next zoom stop. |
| Zoom dropdown | The stops: **10, 20, 30, 40, 50, 75, 100, 125, 150, 175, 200, 300 … 1000**. The buttons, the wheel and this list all walk the same array, so they cannot disagree. **Right-click it to type an exact value** — Enter accepts, Escape cancels. **Fit** can also land between stops, and such a value gets a row of its own until you leave it, so the control always says what the zoom actually is. |
| **Fit** | Zooms so the image fills the frame, magnifying a small one rather than leaving it at its true size. Whichever axis runs out of room first decides, so the whole image stays on screen. |
| Mouse wheel | Steps the same stops, **towards the pixel under the cursor**, so you can drive into a corner of the silhouette without chasing it with the scrollbars. |
| Drag to pan | Left-drag pans whenever no tool is active. With one active — **Pick**, say — the left button belongs to the tool, and middle-drag or Ctrl+left-drag pans instead. Both are claimed before the tool sees them, so panning never drops an island by accident. |
| Pan range | The image follows the cursor, as if you had grabbed it, and can be dragged clear of the frame edges — zoomed in or out, fitting or not — stopping only once a sliver of it is left on screen, so an edge you are inspecting can be pulled into the middle. **Fit** re-centres. |

The image is never stretched. Below the frame size it sits centred with
transparent margins; above it, scrollbars appear and it is drawn at exactly the
requested zoom with nearest sampling, so at 800% you are looking at real pixel
boundaries rather than a smoothed guess.

Opening an image fits it, so it arrives filling the frame rather than as a
corner crop or a speck. Zoom and scroll then survive everything else — re-running
the operation, moving the **Original** slider — so you can sit at 400% on an edge
and watch a setting change it.

The **Original** slider fades the untouched source back in over the result: 0
shows the result, 100 the source, and anything between shows both at once. That
middle is the useful part. The question at 400% on an edge is almost never "which
of these two am I looking at" but "how much of the edge did I just eat", and that
is a question about the difference between them — which a slider puts in one
place, where a toggle makes you hold one image in your head while looking at the
other.

The preview follows settings changes on its own. Above four megapixels it stops
doing so, and **Refresh** runs it on demand instead. There is no switch for this:
the only reason to want automatic preview off is that it has become too slow, and
the dock can see that for itself.

**Processing runs on a worker thread**, so the editor stays usable while it
works — you can keep panning, zooming and dragging sliders. A spinner and two
progress bars sit over the preview while a run is in flight, dimming the image
rather than covering it, since what you are looking at is one revision out of date
rather than gone.

The upper bar is the whole stack; the thin one under it is the operation currently
running, named in the caption above them. That second bar resets every time the run
moves on to the next operation, and the reset is most of what it is telling you —
without it, a stack that spends four seconds inside one operation looks the same as
one that has stopped.

The bars and the spinner answer different questions. A bar says how far along the work is, and
advances unevenly on purpose — the passes report where they have actually got to,
and they are nothing like equally expensive. The spinner says the work is still
happening, which a bar cannot: one that has not moved for four seconds looks
exactly like one that has hung, and a single pass can easily take that long. It
turns at a wobbling rate rather than a constant one, so it reads as something
working at a thing rather than a wheel freewheeling.

The spinner, caption and bar sit together in a rounded translucent panel, over a
light scrim across the rest of the view. The spinner is drawn rather than loaded
from a file: at that size a couple of arcs do everything artwork would, and
drawing it means it is crisp at any editor scale, picks up the theme's accent
colour, and cannot go missing. It shrinks only when the preview column runs out
of room, and stays square when it does.

Only one run happens at a time. Changing a setting mid-run **tells that run to
stop** and queues a replacement: the answer it was working towards is one nobody
will look at, so finishing it would only hold up the one that matters. It gives up
at its next stage boundary — between them a pass runs to its end once started, so
how quickly a cancel takes hold is however long the current pass has left. The bar
resets when the replacement starts; the spinner does not, since work never
actually stopped happening.

The result of a run whose image was swapped out underneath it is thrown away
rather than shown. The worker gets its own copy of the settings, so nothing you
touch while it runs can change the answer it is halfway through computing.

**Process All is still synchronous** and will lock the editor for the length of
the batch.

The three columns are split by draggable dividers.

## Remove Background

Keys out a flat background colour while rebuilding the antialiased silhouette.

Set the colours in the **Remove Colors** list, which starts with one white entry
and takes as many as the image needs. The maths is colour-agnostic, so a green
screen or a flat blue plate works exactly as well as white.

The problem with deleting background-coloured pixels is that the pixels along the
edge are not background *or* subject — they are a blend of both, produced by the
antialiasing that drew the image in the first place. Delete them and the cutout
goes jagged; keep them and you get a fringe that only shows up later, once the
image is composited over something else.

So instead of asking "is this pixel background?", it asks "how much of this
pixel is subject?" and writes the answer to the alpha channel. It then un-blends
the background back out of the RGB, because a half-transparent pixel that is
still half background will read as a halo no matter how correct its alpha is.
Finally it bleeds subject colour outwards into the fully transparent pixels,
since bilinear filtering and mipmaps sample RGB even where alpha is zero.

The full derivation is in the header comment of
`core/remove_background.gd`.

### Settings

Each operation's own settings sit under its entry in the stack, and fold away by
clicking its title. Folds are remembered for as long as the editor is open — they
are not saved to a sidecar, being about what you are working on rather than about
the image — and two entries of the same operation fold independently.

**Remove Background**

| Setting | Default | What it does |
| --- | --- | --- |
| Remove Colors | one white entry at 0.02 | The background colours to key out, each with a tolerance of its own. Only takes where the colour reaches the image border. See below. |
| Edge Width | 2 | How many pixels of antialiasing to rebuild. 2 suits ordinary antialiasing; raise it for soft edges, glows and drop shadows; 0 gives a hard cutout. The crevice rule and Island Picker matte what they open to this same depth, so every edge in the image agrees. |
| Crevice Reach | 0 (off) | Lets the flood squeeze into nooks whose opening is nothing but the antialiasing of the two walls meeting. This is how many such pixels it may cross in a row. See below. |
| Crevice Tolerance | 0.5 | How far from the background colour those squeezed-through pixels may be. Only applies while Crevice Reach is above zero. |
| Only Outer Background | on | Flood fills from the image border, so background-coloured regions enclosed by the subject — eyes, highlights, the holes in an "o" — stay opaque. Also what confines **Remove Colors** to the border. |
| Remove Color Fringe | on | Un-blends the background out of partially transparent pixels. This is the setting that actually kills the halo. |
| Color Bleed | 16 | How far subject colour is pushed into transparent pixels, guarding against filtering dragging the background back in. |

**Refine Edges**

| Setting | Default | What it does |
| --- | --- | --- |
| Refine Radius | 2 | Window radius for the guided filter: roughly how far a ragged patch of alpha may sit from a real edge and still be pulled onto it. **0 switches the filter off and leaves the two clips below**, which is worth having on its own. |
| Alpha Floor | 0.0 | Alpha at or below this is forced fully clear. Applied after the filter, so it also clears what the filter leaves behind. See below. |
| Alpha Ceiling | 1.0 | Alpha at or above this is forced fully solid, with the range between stretched across the two. |

**Island Picker** and **Polygon Edit** hold one list each and nothing else — regions
picked off the preview, and shapes drawn over it. Both are coordinates, so both are
held per image. See below.

**Edge Cleanup**

| Setting | Default | What it does |
| --- | --- | --- |
| Inner Stroke Width | 0.5 | Width of the stroke drawn inside the silhouette, in pixels. Colour only. See below. |
| Outer Stroke Width | 0.5 | Width of the stroke drawn outside it. Adds alpha, so the subject grows. See below. |
| Stroke Softness | 0.75 | How soft the stroke's inner edge is. 0 is a hard step, 0.5 a one-pixel falloff, 1 the softest. |
| Auto Stroke Color | off | Takes the stroke colour from the image instead of picking one. Hides the picker. See below. |
| Stroke Color | opaque black | Colour of the stroke. Its alpha is blend strength, not result transparency. |

The antialiasing restoration has no settings and never will: it only touches a solid
pixel sitting straight against a clear one, so a properly matted edge is invisible to
it. Having the operation in the stack at all is what switches it on — which is what
the old **Edge Cleanup → Enabled** tick did.

### Remove Colors

A list rather than a single swatch, because one background colour is an
assumption rather than a fact. A sprite sheet exported over a white plate and
later padded with grey has two; a scan has the paper and the shadow under it.

Hit **Pick** and click the preview to sample a colour off the image, or **Add**
for an entry to set by hand with the swatch. **Remove** and **Clear** take
entries back out.

**An entry takes where it is reachable from the image border**, while **Only
Outer Background** is on. This is the one thing to know about the list.

Reachable means a path exists to it through colours the list already covers — not
that the colour touches the border itself. The flood spreads through the
background as a whole: a pixel one entry refuses is offered to the rest of the
list, and takes whichever entry claims it. So a white plate around a green stem
needs *both* white and green listed, and then the flood crosses the white to reach
the green and carries on at green's tolerance. It also passes through anything
already transparent (see below). What stops it is opaque subject that no entry
claims.

The consequence worth remembering: **removing an entry can strand the others.**
Take white off that list and the flood has no way in from the border any more, so
green stops working too — not because green is wrong, but because nothing gets it
there. If a colour that looks right clears nothing at all, this is usually why.

So a grey panel walled off by *opaque subject* is not removed by adding grey to
the list, however exactly you match it — there is no path to it. That region is
what the **Island Picker** is for: click it and it floods from there, keying out
against its own colour. The rule of thumb is that the list describes background
the flood can walk to, and the picker describes background it cannot.

Turning **Only Outer Background** off removes every listed colour wherever it
appears, enclosed regions included — which is also why it takes the eye
highlights with it.

**Transparency does not count as a wall.** A pixel that arrives fully transparent
is already removed, so the flood crosses it freely and picks up whatever it finds
on the far side. That is what makes a second pass work: process a plant on white,
then swap white for the green of its stem, and the flood reaches the stem through
the transparent background rather than stopping at the frame. Crossing a hole also
re-offers the far side to the whole list, since transparency carries no colour to
inherit.

This matters more than it sounds, because of **Color Bleed**. Where this operation
makes a pixel transparent it fills the RGB underneath with the nearest subject
colour — invisible at alpha zero, but there to stop filtering dragging the
background back in later. So the transparent border of an already-processed image
holds plant green, not white. Matching that against your list would be reading a
value put there for a completely different purpose, so alpha is checked first and
the colour ignored.

A partly transparent pixel is *not* treated this way. It is a real antialiased
edge carrying real coverage, and only exactly zero counts as empty.

**Each entry carries its own tolerance**, and that is the point of the list. One
global number has to be tuned for the worst background in the image: loose enough
to swallow a speckled JPEG plate, it eats into the subject beside a clean flat
one. Separate entries let the speckled one sit at 0.08 while the flat one stays
at 0.02. The tolerance travels with the flood, so a region seeded by a tight
entry stays tight even where it runs alongside a loose one — and coverage,
decontamination and the edge band are all measured against the key that claimed
each pixel.

Where two entries could both claim a pixel, the higher one wins. That makes the
list read top to bottom as the ordered set of rules it is, rather than depending
on which entry happens to fit more tightly.

**An empty list is a real state**, not a broken one: nothing is keyed out from
the border, and an image whose only backgrounds are enclosed regions is described
by islands alone. With no colours *and* no islands the image comes back untouched.

### Nooks and crannies

Background sometimes survives in a tight concave corner. The usual cause is not
the edge handling but **reachability**: where two walls nearly meet, their
antialiasing overlaps and no pixel in the gap is close enough to the background
colour to pass the flood's test. The flood stops at the mouth, and everything
behind it stays opaque.

**Crevice Reach** is the remedy — Canny's double-threshold trick applied to
region growing instead of edge linking. A pixel within its own key's tolerance is
solid background and resets the count; one merely within **Crevice Tolerance**
may still be crossed, but only this many in a row before solid background is
needed again. That squeezes through a constriction while stopping the flood
wandering off across a pale subject, which an unbounded loose threshold would do.

It is part of the flood rather than an operation of its own, and has to be: the
rule is applied against the tolerance of whichever entry the flood is carrying at
that moment, so it runs once per colour in the list and each one squeezes on its
own terms. A gap off a tightly toleranced colour does not open up on a loosely
toleranced one's. Pulled out into a pass over the finished result it could only
work against one tolerance for the whole image, which is the wrong answer for any
list longer than one.

Set it to at least the length of the constriction it has to get through — a
narrow slot 8px long needs roughly that much reach. It is off by default because
it is a remedy rather than something every image wants.

Being generous with it is safer than it sounds. Anywhere the flood reaches only
by straying is reclassified as **edge**, not background, so it is matted by the
ordinary coverage maths rather than cut out — and genuine subject measures as
fully covered there, so it keeps its alpha. Measured across near-white, light
grey and mid grey subjects at every reach from 1 to 32, not one interior pixel
was eroded, and a normal antialiased edge came out bit-identical to reach 0.

### Refining the edge

**Refine Edges** runs the finished alpha through a guided filter (He, Sun & Tang,
ECCV 2010 — the paper's "guided feathering" application). Within each window the
alpha is fitted as a linear function of a guide signal and the fits are averaged.
Where the guide is flat the alpha is smoothed; where the guide has an edge the
fit follows it, so the alpha snaps to that edge instead of blurring across it.

The guide is distance-from-the-key-colour rather than luminance. It is already
computed, and its edges are exactly the background/subject boundary whatever the
hue — so it separates a green screen from an equally bright subject, which
luminance cannot.

It is not only a tidying pass; it is more accurate. Against known coverage it
cut mean edge error by 2.6–3.6×:

| Subject | Edge error, off | On (radius 2) |
| --- | --- | --- |
| Dark colour ramp | 0.0090 | 0.0028 |
| Pure black | 0.0083 | 0.0032 |
| Mid grey | 0.0152 | 0.0043 |
| Near-white (0.88, 0.90, 0.82) | 0.0495 | 0.0193 |

The cost is a few extra passes over the image, which is why it is off by default.
A solid interior loses at most two 8-bit levels of alpha and no halo appears.

**One thing it does not do is remove.** Smoothing pulls a leftover speck of
background *towards* its transparent neighbours, so a solid speck becomes a faint
ghost rather than disappearing. **Alpha Floor** is the answer: set it above where
those ghosts land — around 0.5 — and they go. This is the clip-black/clip-white
pair from keying, applied after refinement so nothing smooths it back into a
haze.

It is not free. Genuinely faint edge pixels are below the floor too and go with
the ghosts, so the silhouette hardens. Measured on a soft antialiased edge:

| Floor / ceiling | Mean edge error | Alpha levels left on the edge |
| --- | --- | --- |
| off | 0.0028 | smooth |
| 0.1 / 1.0 | 0.046 | 15 |
| 0.2 / 0.8 | 0.097 | 11 |
| 0.5 / 0.6 | 0.183 | 5 |
| 0.55 / 0.55 | 0.246 | 2 (a hard cutoff) |

So start low. A floor around 0.1–0.2 with the ceiling left at 1.0 clears haze
while keeping most of the gradient; 0.5 / 0.6 is decisive but close to a binary
cutout. Setting the ceiling at or below the floor is a hard cutoff at that value,
and is honoured rather than rejected.

### Edge Cleanup

Two finishing jobs the keyer cannot do while it is still deciding what is
background. **Enabled** switches both on, and is on by default; leaving both
stroke widths at 0 leaves the restoration running on its own.

They sit together because a stroke depends on the restoration. A stroke places
its edges from the alpha's own sub-pixel contour, which a hard silhouette does
not have — and giving a hard silhouette one is exactly what the restoration does.

**Restoring antialiasing.** Everything else here builds the matte *while*
cutting, which only helps where this operation is the one doing the cutting — it
cannot help an edge that arrived aliased (a sprite someone already cut out badly,
a screenshot, art drawn with a hard brush) or one that a low **Alpha Ceiling**
flattened on the way past. Those come out with a solid pixel sitting straight
against a transparent one and nothing between.

It works from the same relation as everything else. An edge pixel is
`C = a * F + (1 - a) * K`, so its distance from the background is `a` times the
subject's distance from the background, and dividing one by the other gives back
`a` with the unknown `F` cancelled out. The subject colour is read a step or two
into the shape rather than from the pixel itself — the pixel being fixed is part
background, so asking it how much of a blend it is would answer "all of it".

**It has no settings of its own, and that is deliberate.** A pixel only qualifies
when the opposite extreme is *directly* beside it. A properly matted edge has
half-covered pixels in between, so neither side can see the other and the pass
never touches it. There is nothing to tune down, because it cannot undo good work
in the first place. Polygon Edit regions are skipped on both sides — those edges
are hard on purpose.

**There are two strokes**, either or both. The **inner** one is drawn inside the
silhouette of everything visible: it never extends the shape, follows the holes in
a subject as well as its outer contour, and leaves the alpha channel exactly as it
found it. Only colour changes.

The **outer** one is its mirror, and differs in one way that matters: outside the
shape there is nothing to colour, so it has to **add alpha**. The subject comes out
that many pixels larger than it went in. It is composited *underneath* the
subject rather than over it, so the shape's own soft edge stays on top and the
stroke shows through it — which is what an outer stroke looks like, and what stops
it eating the antialiasing it is there to sit behind.

Both measure from the same contour and share the colour and the softness.

**It is antialiased, and that is the fiddly part.** What matters is the contour
where alpha crosses a half, and that sits *between* pixels rather than on them. A
pixel's own alpha says where: coverage on a real antialiased edge falls off over
about one pixel, so a pixel of alpha `a` is `a - 0.5` from the contour, signed,
inside positive. That holds for a hard edge too, where the two sides read +0.5 and
-0.5 and put the contour exactly halfway between them.

Measuring from that sub-pixel contour rather than from the nearest transparent
pixel is what makes the stroke smooth. Whole-pixel distances quantise, and on a
shallow diagonal — where the nearest empty pixel stays directly below for a long
run — they quantise into a staircase, which is the one artefact a stroke must not
have. Fractional widths are therefore worth having: both edges of the stroke fall
between pixels.

**Stroke Softness** sets how wide that falloff is. 0 is a hard step with no
antialiasing at all, 0.5 falls off over one pixel — the width a real antialiased
edge has, and what the stroke did before this was adjustable — and 1 is the
softest, at two pixels. The middle of the slider is the natural look, which leaves
the top half for softer than natural, which is mostly what it is wanted for.

It feathers the **inner** edge only. The outer edge is the silhouette, and its
softness is already in the image's own alpha; feathering that too would let the
stroke bleed past the shape, which is the one thing an inside stroke must not do.
The falloff is centred on the width you asked for, so softening blurs the edge in
place rather than walking the stroke inwards — though a wide feather on a narrow
stroke will spread it past its own width, since half the falloff sits outside.

**Stroke Color**'s alpha is blend strength, not result transparency. At half
alpha the stroke tints the art beneath it; it does not make the silhouette
half-transparent. It is applied last of all, on the colour only, after the
un-blending and the colour bleed have finished working out what the subject's own
colour was — the stroke is paint going on top of that answer, not part of the
image to be recovered.

**Auto Stroke Color** takes the colour from the image instead, per pixel, and
hides the picker. A green stem gets a dark green outline and a red petal a deep
red one, rather than one flat colour fighting everything it runs alongside.

Two things make it work, and neither is optional:

- **The blur is weighted by alpha.** Each channel is blurred premultiplied by
  alpha and divided by a blur of the alpha itself, so only real subject pixels
  count. An unweighted blur would average in the empty space just outside the
  edge — which is exactly where every stroke pixel sits, so every stroke would
  drift towards whatever the colour bleed left out there.
- **The sample is darkened before use.** Painting a colour over itself shows
  nothing. What reads as a line is a darker, more saturated relative of the fill
  it borders, which is how one is picked by hand.

The darkening is proportional, with no threshold anywhere. A rule that switched
from darkening to lightening below some luminance would flip the outline mid-
stroke wherever a subject crossed that line, which is worse than an outline that
is merely subtle on something already dark.

The blur radius is four times the stroke width, and at least six pixels. Wide on
purpose: the question is "what colour is the subject around here", and a tight
blur answers "what colour is this pixel" — noise on any texture, and a stroke
that changed colour along its own length.

An automatic stroke is drawn at full strength, since its picker is hidden and
there would be no way to have set anything else. For a stroke that only tints,
turn this off and pick a colour with some transparency.

Where a subject runs off the edge of the canvas, **the frame counts as outside**
and the stroke follows it. The stroke also follows Polygon Edit cuts, since it is
measured from the silhouette that actually comes out rather than the one the
keyer alone would have given.

### Picking islands

**Only Outer Background** is deliberately conservative — it keeps every enclosed
region, because it cannot tell an eye highlight from a gap you wanted gone.
The **Island Picker** is the manual override.

Hit **Pick** in the settings panel, then click any enclosed region in the
preview. It's added to the list as `(x, y)`, marked with a ring on the preview,
and removed on the next pass. Highlight a row to see which marker it is;
**Remove** and **Clear** take entries back out.

**Each island keys out its own colour** — the colour of the pixel you clicked,
shown as the swatch on its row. So an island need not match anything in **Remove
Colors**: a white plate with a red panel inside the subject takes one entry and
one pick. The colour is sampled from the image at process time rather than
stored, so a swatch can never disagree with what it will actually remove.

**Each island has its own tolerance**, on the slider under the list, applying to
whichever row is highlighted. How clean one region is says nothing about the one
beside it — a speckled patch wants a loose tolerance where the flat panel next to
it would be eaten by the same number.

It starts at **0.2**, much looser than a **Remove Colors** entry's 0.02, because the
two are aimed at different things. A Remove Color is a colour you chose and can see,
so it starts tight and takes only what you asked for. An island is a spot you pointed
at, and what you meant was the region under the pointer — so it has to swallow that
region's own variation without being told what it is. Starting tight would make every
island a handful of pixels you then had to widen by hand, which is the wrong default
for a control whose whole point is one click.

Loosening a **Remove Colors** entry does not loosen the islands, and never did:
the entries there describe colours an island by definition is not, or the border
flood would have reached it already.

**A new island starts where the last one left off**, taking the previous row's
tolerance and its Subtract/Add mode. Picking islands is repetitive — several
spots in one image, wanted the same way — and setting the same two controls after
every click is exactly the sort of thing the list should remember. The same goes
for a new **Polygon Edit** region and its mode.

One consequence: clicking the subject by mistake keys out *that* colour and eats
part of the subject. The preview shows it at once, and removing the row undoes
it.

Press **H** with the pointer over the dock to hide and show the markers — they
sit right on top of the edges you are trying to judge. The shortcut is scoped to
the dock, so H stays free everywhere else in the editor and never steals a
keystroke from a text field.

**The list belongs to the image**, like every other setting: changing selection
swaps it to whatever that image has, so you can work through a batch picking each
image's islands and then process the lot in one go. Islands are saved with the
rest of that image's settings — see [Per-image settings](#per-image-settings) —
so they survive an editor restart.

A picked island is not a hole punch — it starts the same flood fill the image
border does, so the region's rim gets the identical antialiasing treatment as
the outer silhouette. On a test island of a different colour to the main
background, the worst fringe after compositing over black was 0.013, against
0.691 for a hard-edged cut.

Entries are irrelevant while **Only Outer Background** is off, since every
background-coloured pixel already qualifies then. Click the middle of a region
rather than its edge: an antialiased pixel is a blend, so keying off one keys off
the blend rather than the region's true colour.

### Polygon Edit

Everything else here removes background by **colour** — even a picked island,
which floods from a point and stops wherever the colour changes. That leaves no
way to say "this region goes, whatever is in it": a watermark, a scan edge, a
stray element in a corner. Those have no colour in common with themselves, so no
colour-based tool can describe them. A polygon can.

Hit **Draw** and click the preview to place corners. Close the shape three ways —
**right-click**, **Escape**, or **clicking the first corner** again — and
**Backspace** takes back the last corner while you are still placing them. A
region with fewer than three corners is discarded rather than stored, and the
hint line says so, since a shape vanishing on close otherwise looks like a bug.

While you draw, the edge you would add follows the pointer and the closing edge
is drawn faintly, so the shape can be judged before you commit to it. Each region
gets a random swatch colour, used both on its row and for its outline, so a
crowded image stays readable. Select a row and its corners become **draggable
handles**; grabbing one beats starting a pan, and Ctrl+drag still pans as usual.
The image only reprocesses when you let go, not on every mouse motion.

**Shapes may be concave**, which is the whole point — the regions people actually
want gone are rarely convex. Filling uses a scanline under the even-odd rule, so
a C or an L fills correctly and a self-intersecting shape gets a sensible hole.
Naive polygon drawing fans triangles from the first corner and gets both wrong.

**The cut is hard.** No antialiasing is rebuilt along a polygon edge, because
there is no background there that the subject blended with — the edge is your
line, not something recovered from the image. Regions are folded into the
classification as background before any alpha is worked out, so colour bleed
still fills the RGB underneath them exactly as it does for keyed-out background.

Polygon Edit works with no **Remove Colors** entries at all. Clear the list and the
polygons are still cut; nothing else happens.

Press **H** to hide the regions and the island markers together while judging an
edge.

### Accuracy

Measured against analytically antialiased test shapes, where the true coverage of
every pixel is known. Error is the mean per-channel difference from ground truth
after compositing the result over black — the arrangement that makes any fringe
obvious.

Against a white background, by subject colour:

| Subject | Naive threshold cutout | This operation |
| --- | --- | --- |
| Dark colour ramp | 0.420 | 0.009 |
| Pure black | 0.419 | 0.000 |
| Mid grey | 0.417 | 0.014 |
| Near-white (0.88, 0.90, 0.82) | 0.364 | 0.050 |

Across background colours, mean alpha error on the soft edge:

| Background | Alpha error | Fringe |
| --- | --- | --- |
| White | 0.009 | 0.009 |
| Blue (0.15, 0.35, 0.85) | 0.010 | 0.009 |
| Green screen (0, 1, 0) | 0.010 | 0.010 |
| Mid grey | 0.017 | 0.007 |
| Black | 0.008 | 0.009 |

Fully opaque interiors stay at alpha 255 and background stays at alpha 0 in
every case; the error above is entirely in the soft edge.

### Known limits

- A subject the same colour as the background where the two meet cannot be
  separated from it. That is missing information, not a tuning problem.
- A feature only one pixel wide is ambiguous — a 50%-covered black line and a
  fully opaque grey line are the same pixels. Such features are kept opaque
  rather than half-erased.
- An edge softer than **Edge Width** keeps part of its halo. Raise the setting;
  overshooting it costs nothing, as the coverage estimate self-corrects.

## Per-image settings

The whole stack belongs to the image on screen — which operations it holds, in what
order, switched on or off, and every value in them. Selecting an image loads its
stack; changing anything saves it again a moment later.

It lives in a **JSON file beside the image**, named by replacing the extension:
`flower_0002.png` → `flower_0002.json`. It is plain text and safe to hand-edit or
commit alongside the art.

```json
{
	"format": "image_wrangler",
	"version": 2,
	"stack": [
		{ "id": "remove_background", "enabled": true, "settings": { "edge_width": 2 } },
		{ "id": "polygon_edit", "enabled": true, "settings": { "polygons": { "regions": [] } } },
		{ "id": "polygon_edit", "enabled": false, "settings": { "polygons": { "regions": [] } } }
	]
}
```

An ordered list rather than a block per operation, because the order is part of the
answer and the same operation may appear more than once — neither of which a
dictionary keyed by name can say.

**Version 1 files still open.** One of those held a single fused operation with
thirteen tunables; it is translated into the equivalent stack on the way in, and an
operation whose settings say it was doing nothing is left out rather than added
switched off. Nothing is written back until you edit something, so opening an old
file and closing it again leaves it exactly as it was. The first edit writes version
2 and drops the old block.

**An image with no file gets the defaults.** Nothing is inherited from the image
you were looking at before it — select one with no `.json` and every control
snaps back, so what the form shows is always this image's own settings and never
a leftover. The form and the processing therefore agree for every image, whether
or not it was ever selected.

Selecting an image never writes anything. Only editing does.

Three things worth knowing:

- **Files appear beside your art without being asked for.** Everything else this
  addon writes is behind an explicit Process, with a confirmation before
  overwriting. This is not.
- **A batch has to be tuned image by image.** Dialling in a tolerance and hitting
  **Process All** applies it only to the images you actually selected and edited;
  every other image is processed at its defaults. This is the price of the rule
  above — a value that arrived by inheritance is indistinguishable on screen from
  one you chose, and it would be autosaved into a sidecar either way.
- **A `.json` already there and written by something else is left alone.**
  `sprite.json` beside `sprite.png` is exactly what Aseprite names its atlas
  descriptor. The addon reads such a file, sees it is not one of its own, refuses
  to touch it, and says so — so that image simply has no saved settings. Two
  images differing only by extension (`sprite.png`, `sprite.jpg`) also share one
  file name; only one of them can have settings.

Values outside the range their slider allows — from a hand edit, or a file
written by a later version — are pulled back inside it on load, so the form and
the processing can never silently disagree.

### Switching entries off, and Add vs Subtract

Every row in **Remove Colors**, **Island Picker** and **Polygon Edit** carries a
**tick box** on the right. Unticking leaves the entry in the list but out of the
result — a colour keeps its tolerance, an island keeps its spot, a region keeps
its shape — so something can be tried and untried without being set up again. A
switched-off island still shows its marker, drawn hollow; a switched-off region
still shows its outline, drawn without its fill. Clicking a highlighted row again
clears the selection.

**Island Picker** and **Polygon Edit** rows also carry a **Subtract / Add** dropdown.
Subtract is the default and is what both tools have always done: the affected
area becomes transparent. Add reverses it — the same area is forced **opaque**,
whatever the keying decided. An Add island floods exactly as a Subtract one does,
outwards from the pixel you clicked through anything close to its colour, so
clicking a region a loose tolerance ate brings it back bounded by the same edges
that would have bounded its removal.

**Add wins wherever the two overlap**, whatever order the rows are in. Protection
is an override rather than another layer of paint, which is what lets the list
stay a set of rules with nothing to reorder. The practical shape of that: a
Subtract region over a corner with an Add island on a logo inside it keeps the
logo and cuts the rest. The reverse — a Subtract hole inside an Add region — is
not expressible.

Remove Colors has no dropdown. A colour describes what background *is*, where add
and subtract describe what to do with an area, and there is nothing for a colour
to add.

## Rename

Writes each source out under a new name, leaving its pixels alone. It is the odd
one out — every other operation answers "what should this image look like", and
this one answers "what should this file be called" — but the two questions get
asked at the same moment, and the answer goes through the same Process buttons.

**Nothing is renamed in place.** Processing writes copies under the new names,
wherever the Process buttons ask for; the sources are untouched. A rename tool
that moved the originals would be a far less forgiving thing to point at a folder
of art.

**Its settings are not per-image**, unlike every other operation's. A rename
scheme describes the batch rather than any one file — a counter that restarted
for each image would mean nothing — so one set is held for as long as the dock is
open, and nothing is written to a sidecar.

Because it does not touch pixels, the file is **copied byte-for-byte** rather
than re-encoded, so a renamed JPEG stays a JPEG instead of becoming a PNG wearing
a `.jpg` name.

**A matching `.json` travels with the image.** Rename `flower.png` to
`tile_003.png` and `flower.json` is copied to `tile_003.json`, so the new file
arrives with the settings the old one had rather than falling back to defaults
the next time the dock is opened. Whatever sits at that name goes, ours or not —
`sprite.json` beside `sprite.png` is as likely to be an Aseprite atlas
descriptor, and that belongs with the image just as much. Two exceptions: a JSON
already at the new name that this addon did not write is **never replaced**, and
a sidecar another image in the list still shares — `flower.png` and `flower.jpg`
resolve to the same `flower.json` — is copied but never removed. Either way the
status bar names what stayed put, and the image itself is still reported as
written, because it was.

| Setting | What it does |
| --- | --- |
| Base Name | Replaces every file's name. Leave it empty and each keeps its own — which is what makes Find and numbering useful across a mixed batch. |
| Find / Replace With | Substring replacement. An empty **Find** switches it off, so an empty **Replace With** cannot quietly strip something. |
| Prefix | Goes in front, ahead of any number. |
| Start At / Step / Digits | Every file is numbered by its position in the Images list, so **Process All** and **Process Current Only** agree on what any one file is called. These set the counter's start, increment and zero padding — pad so the names sort correctly in a file browser. |
| Separator / Number At | The text between name and counter, and which end it goes on. |
| Letter Case | Unchanged, lowercase, UPPERCASE or Title Case. Never applied to the extension. |
| Lowercase Extension | So a folder of mixed `.PNG` and `.png` comes out consistent. |
| Remove Old Files | Off by default. Deletes each source — and its `.json`, if it has one — once the copy has been written. See below. |

The name is composed in a fixed order, so the result does not depend on which
fields happen to be filled in:

```
base name (or the file's own)
  -> find/replace
  -> prefix, and the Output suffix
  -> number, at whichever end
  -> letter case
  -> extension
```

The preview cannot show a rename — the pixels are unchanged — so the status bar
shows the result instead: `flower_0002.png → tile_003.png`.

### Removing the originals

With **Remove Old Files** ticked, the run finishes normally and *then* asks:
*"Are you sure you want to remove N file(s)?"*, naming them. Only if you confirm
does anything get deleted, and four things stand between the confirmation and the
deletion:

- **Every copy is checked against its source by SHA-256.** A file that was not
  written, has gone missing, or does not match is a failure.
- **It is all or nothing.** One mismatch anywhere and *nothing* is deleted, not
  even the files that did verify. A half-deleted batch after a half-passed
  verification is the worst outcome available here.
- **Shared output names abort the whole thing.** Two sources renamed to the same
  file means the second overwrote the first, so that first source is now the only
  copy of itself in existence — and it would pass a checksum test against the
  survivor's content. This is easy to trigger by accident: set **Base Name** with
  numbering off and every file lands on one name.
- **Originals go to the system trash**, not straight out, so the judgement that
  you no longer want them stays reversible.

A source that failed to copy is never a candidate, and neither is one whose
destination is itself.

Sidecars go into the same pass rather than a pass of their own, so
`flower.json` is named in the confirmation alongside `flower.png`, checksummed
like it, and caught by the same all-or-nothing rule — a sidecar that did not
verify stops the images being deleted too.

Once the originals are gone, the **Images** list re-points at the files that
replaced them — keeping its order, its selection, and each image's settings — so
the rows are not left aiming at files in the trash. Only entries whose original
actually moved are touched; a rename that left its sources alone changes nothing,
because nothing went stale. Each image's settings follow it in memory, and its
`.json` sidecar has already been copied to the new name during the run, so
reopening the dock later finds them still there.

## Adding an operation

There are two kinds, and which one you are writing decides what you subclass.

**A stack operation** — something that changes the pixels. Subclass
`IWStackOperation`, implement `process_context(ctx)`, and add the script's path to
`OPERATION_SCRIPTS` in `ui/iw_panel.gd`. That is the whole of the plumbing: the
dock builds its form from `get_settings_schema()`, the sidecar codec saves its
settings by reflection, and the stack view offers it in the Create dropdown.

It is handed an `IWPipelineContext` rather than an `Image`. That holds the source
pixels, the classification, the keys and the alpha the operations above it produced,
and the pixels are written out once at the end by `IWCompose` — so an operation
never sees a half-finished image, only the original colours plus what has been
decided about them. Anything measuring against a background should return `true`
from `needs_keying()` and a line from `prerequisite_note()`, so an entry with
nothing above it says so instead of failing.

Three things worth knowing about the context:

- **`ctx.data` is immutable.** Everything an operation decides goes into
  `ctx.coverage`, `ctx.mask` or `ctx.key_of`.
- **Invalidate what you disturb.** Moving a pixel out of subject makes
  `ctx.nearest` stale; call `ctx.rebuild_nearest()` and then
  `ctx.compute_coverage(...)` over what could have changed.
- **Bind before you loop.** Reaching through `ctx.` inside a per-pixel loop is an
  object property lookup a few million times over. Copy what you need into locals
  at the top, the way the existing operations do.

**A file operation** — something that changes where the pixels go, not what they
are. Subclass `IWOperation` directly, return `false` from `transforms_pixels()`,
and expect to be wired into the dock by hand: `Rename` is the only one, and it sits
under its own tab rather than in the stack, because its
settings describe the batch rather than any one image.

