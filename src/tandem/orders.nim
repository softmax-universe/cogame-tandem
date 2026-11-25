## Orders: the six-field carry object a seat plays for one 48-tick decision
## turn, its tolerant parser/repairer, its quantisation, its replay record, and
## the view-coordinate transform every policy sees the world through.
##
## Two hard rules live here and are pinned by tests/test_orders.nim:
##
## 1. **Every recorded string is truncated on RUNE boundaries, never bytes.**
##    A byte-truncated multi-byte character is exactly the bug that makes
##    replay bytes render in a browser but fail a strict parser.
## 2. **Parsing is strict on control fields.** Every carry order must provide
##    finite, in-range `drive`, `effort`, `yield`, `twist`, and `brace` values
##    in the documented JSON schema; missing, malformed, or out-of-range fields
##    are rejected rather than repaired or substituted.
##
## Floats are legal here: this module is OUTSIDE the float-free grep guard,
## because the quantised integers it produces — and only those — are what the
## sim hashes. The `q` array in the replay record carries exactly those
## integers so playback re-installs them bit for bit.

import
  std/[json, math, strutils, unicode],
  sim

# --------------------------------------------------------------------------
# View coordinates: metres from the world centre, y UP. The ONLY coordinates a
# policy ever sees or sends.
# --------------------------------------------------------------------------

const
  ViewHalfW* = 22.2
  ViewHalfH* = 12.6

proc viewX*(x: int32): float {.inline.} =
  float(int(x) - int(WorldW div 2)) / 1_000_000.0

proc viewY*(y: int32): float {.inline.} =
  float(int(WorldH div 2) - int(y)) / 1_000_000.0

proc viewLen*(v: int32): float {.inline.} =
  float(v) / 1_000_000.0

proc viewSpeed*(v: int32): float {.inline.} =
  ## micrometres per tick -> metres per second.
  float(v) * float(TargetFps) / 1_000_000.0

proc round2*(value: float): float {.inline.} =
  ## Two decimals, the precision every number in the seat view carries.
  round(value * 100.0) / 100.0

proc round6*(value: float): float {.inline.} =
  round(value * 1_000_000.0) / 1_000_000.0

proc degOfQ*(headingQ: int32): float {.inline.} =
  ## A headingQ angle as degrees counter-clockwise from +X, rounded to 1.
  round(float(((headingQ mod HeadingQTurn) + HeadingQTurn) mod HeadingQTurn) *
    360.0 / 4096.0)

proc degOfVectorView*(dx, dy: int32): float {.inline.} =
  ## The bearing of a WORLD vector, reported to policies as degrees ccw from
  ## +X in view coordinates.
  round(float(bradsOfVectorI(dx, dy)) * 360.0 / 256.0)

proc spinDegPerSecond*(spin: int32): float {.inline.} =
  round(float(spin) / float(SpinFine) * 360.0 / 4096.0 * float(TargetFps) *
    10.0) / 10.0

# --------------------------------------------------------------------------
# Rune-boundary truncation
# --------------------------------------------------------------------------

proc clipRunes*(text: string, maxRunes: int): string =
  ## Truncates on a RUNE boundary (babel's `cleanNotes`, ported). Slicing a
  ## `string` by byte index on any path to the replay is forbidden.
  result = text.strip()
  var clean = newStringOfCap(result.len)
  for rune in result.runes:
    # Control characters would corrupt a replay chat record and a JSON line.
    if int32(rune) >= 32 or int32(rune) == 9:
      clean.add($rune)
  result = clean
  if maxRunes <= 0:
    return ""
  if result.runeLen <= maxRunes:
    return
  result = result.runeSubStr(0, maxRunes - 1) & "\u2026"

# --------------------------------------------------------------------------
# Quantisation
# --------------------------------------------------------------------------

proc quantUnit*(x, y: float): tuple[x, y: int32] =
  ## A finite pair clamped to [-1, 1] and quantised to a Q12 unit vector in
  ## VIEW coordinates. A zero vector stays zero, which the caller repairs.
  let
    cx = clamp(x, -1.0, 1.0)
    cy = clamp(y, -1.0, 1.0)
    ix = int32(round(cx * 4096.0))
    iy = int32(round(cy * 4096.0))
  if ix == 0 and iy == 0:
    return (0'i32, 0'i32)
  let u = unitQ12(ix, iy)
  (u.x, u.y)

proc quantUnitFromWorld*(dx, dy: int32): tuple[x, y: int32] =
  ## A WORLD delta as a VIEW-frame Q12 unit vector (the y axis flips).
  if dx == 0 and dy == 0:
    return (0'i32, 0'i32)
  let u = unitQ12(dx, -dy)
  (u.x, u.y)

proc quantUnsigned*(value: float): int32 {.inline.} =
  int32(clamp(round(clamp(value, 0.0, 1.0) * 255.0), 0.0, 255.0))

proc quantSigned*(value: float): int32 {.inline.} =
  int32(clamp(round(clamp(value, -1.0, 1.0) * 255.0), -255.0, 255.0))

proc unitFloat(value: int32): float {.inline.} =
  round2(float(value) / 255.0)

# --------------------------------------------------------------------------
# Construction and serialization
# --------------------------------------------------------------------------

proc emptyOrder*(): Order =
  Order(turn: -1, source: osScripted, driveX: 4096, driveY: 0,
    effort: 0, yieldQ: 64, twist: 0, brace: 0)

proc orderReplyJson*(order: Order): JsonNode =
  ## The complete player reply represented by one quantised game order.
  %*{
    "note": order.note,
    "drive": [float(order.driveX) / 4096.0,
              float(order.driveY) / 4096.0],
    "effort": float(order.effort) / 255.0,
    "yield": float(order.yieldQ) / 255.0,
    "twist": float(order.twist) / 255.0,
    "brace": float(order.brace) / 255.0,
    "say": order.say
  }

proc actionJson*(order: Order): JsonNode =
  ## Exact parser output, including quantised execution values; no transport metadata.
  %*{"note": order.note, "say": order.say,
    "q": [order.driveX, order.driveY, order.effort, order.yieldQ, order.twist, order.brace]}

proc orderJson*(sim: SimServer, seat: Seat, order: Order): JsonNode =
  ## The `order` replay chat record — the action log. `q` carries the EXACT
  ## quantised integers the sim hashed, so playback re-installs them bit for
  ## bit; the float fields beside it are for the feed, `replay_summary.py` and
  ## human eyes.
  discard sim
  %*{
    "k": "order",
    "turn": order.turn,
    "seat": ord(seat),
    "alias": seatAlias(seat),
    "source": sourceText(order.source),
    "latency_ms": order.latencyMs,
    "note": order.note,
    "drive": [round2(float(order.driveX) / 4096.0),
              round2(float(order.driveY) / 4096.0)],
    "effort": unitFloat(order.effort),
    "yield": unitFloat(order.yieldQ),
    "twist": round2(float(order.twist) / 255.0),
    "brace": unitFloat(order.brace),
    "say": order.say,
    "q": [order.driveX, order.driveY, order.effort, order.yieldQ,
          order.twist, order.brace]
  }

proc orderFromRecord*(node: JsonNode): tuple[order: Order, ok: bool] =
  ## The inverse of `orderJson`, reading ONLY the exact `q` integers. This is
  ## the single path an order takes back into hashed state at playback.
  let q = node{"q"}
  if q.isNil or q.kind != JArray or q.len < 6:
    return
  for item in q:
    if item.kind != JInt:
      return
  var order = emptyOrder()
  order.turn = int32(node{"turn"}.getInt(-1))
  order.driveX = clamp(int32(q[0].getInt()), -4096'i32, 4096'i32)
  order.driveY = clamp(int32(q[1].getInt()), -4096'i32, 4096'i32)
  order.effort = clamp(int32(q[2].getInt()), 0'i32, 255'i32)
  order.yieldQ = clamp(int32(q[3].getInt()), 0'i32, 255'i32)
  order.twist = clamp(int32(q[4].getInt()), -255'i32, 255'i32)
  order.brace = clamp(int32(q[5].getInt()), 0'i32, 255'i32)
  order.note = node{"note"}.getStr()
  order.say = node{"say"}.getStr()
  order.source =
    case node{"source"}.getStr()
    of "llm": osLlm
    of "fallback": osFallback
    of "external": osExternal
    else: osScripted
  (order, true)

proc clipJsonStrings(node: JsonNode, budget: int): JsonNode =
  ## A copy of `node` with every STRING VALUE clipped to `budget` runes. Keys
  ## are untouched, so the shape a reader matches on survives.
  case node.kind
  of JString:
    result = %clipRunes(node.getStr(), budget)
  of JArray:
    result = newJArray()
    for item in node:
      result.add(clipJsonStrings(item, budget))
  of JObject:
    result = newJObject()
    for key, value in node:
      result[key] = clipJsonStrings(value, budget)
  else:
    result = node

proc capRecord*(text: string): string =
  ## Every replay chat record is capped at MaxOrderRecordRunes runes, on a rune
  ## boundary.
  ##
  ## The cap is on the SERIALIZED record, and JSON escaping is what makes that
  ## non-obvious: a `"` or a `\` inside a note or a say costs two runes on the
  ## wire. Blindly clipping the serialized text at 900 would cut the object
  ## mid-key — still valid UTF-8 on a rune boundary, but no longer JSON —
  ## and `broadcast.applyRecord` would then silently drop the order, which is
  ## exactly what phase 60 counts. So an over-long record is shrunk
  ## STRUCTURALLY: parse it, clip its string values to a halving budget until
  ## the serialization fits, and only fall back to the blind rune clip when the
  ## text is not a JSON object at all. A record already inside the cap is
  ## returned byte for byte.
  if text.runeLen <= MaxOrderRecordRunes:
    return clipRunes(text, MaxOrderRecordRunes)
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    return clipRunes(text, MaxOrderRecordRunes)
  if node.kind != JObject:
    return clipRunes(text, MaxOrderRecordRunes)
  var budget = MaxNoteRunes
  while budget > 0:
    budget = budget div 2
    let shrunk = $clipJsonStrings(node, budget)
    if shrunk.runeLen <= MaxOrderRecordRunes:
      return shrunk
  clipRunes(text, MaxOrderRecordRunes)

# --------------------------------------------------------------------------
# The tolerant parser
# --------------------------------------------------------------------------

proc extractOrderObject*(text: string): JsonNode =
  ## Match the ordinary player: accept response framing, never skip a malformed
  ## first object or repair its JSON. Quantisation remains in parseOrder.
  try:
    result = parseJson(text)
  except JsonParsingError:
    let start = text.find('{')
    if start < 0:
      raise newException(ValueError, "Tandem response contains no JSON object")
    var
      depth = 0
      inString = false
      escaped = false
    for i in start ..< text.len:
      let ch = text[i]
      if inString:
        if escaped: escaped = false
        elif ch == '\\': escaped = true
        elif ch == '"': inString = false
      else:
        case ch
        of '"': inString = true
        of '{': inc depth
        of '}':
          dec depth
          if depth == 0:
            result = parseJson(text[start .. i])
            break
        else: discard
    if result.isNil:
      raise newException(ValueError, "Tandem response has an unterminated JSON object")
  if result.kind != JObject:
    raise newException(ValueError, "Tandem response must be a JSON object")

proc strictNumber(node: JsonNode, ok: var bool): float =
  ## Accepts a finite JSON number only. Strings, nulls, booleans, and non-finite
  ## floats are rejected.
  ok = false
  if node.isNil:
    return 0.0
  case node.kind
  of JInt:
    ok = true
    return float(node.getInt())
  of JFloat:
    let value = node.getFloat()
    if value != value or value == Inf or value == NegInf:
      return 0.0
    ok = true
    return value
  else:
    return 0.0

proc parseOrder*(
  payload: JsonNode,
  turn: int
): tuple[order: Order, usable: bool] =
  ## Strictly validates and quantises one carry order. Every control field
  ## (`drive`, `effort`, `yield`, `twist`, `brace`) is required and must be a
  ## finite JSON number within its legal range; `note` and `say` are optional
  ## strings clipped on rune boundaries. Never repairs or substitutes missing
  ## or invalid fields.
  var order = emptyOrder()
  order.turn = int32(turn)
  order.source = osExternal
  if payload.isNil or payload.kind != JObject:
    return (order, false)

  let noteNode = payload{"note"}
  if not noteNode.isNil:
    if noteNode.kind != JString:
      return (order, false)
    order.note = clipRunes(noteNode.getStr(), MaxNoteRunes)

  let sayNode = payload{"say"}
  if not sayNode.isNil:
    if sayNode.kind != JString:
      return (order, false)
    order.say = clipRunes(sayNode.getStr(), MaxSayRunes)

  # drive: required 2-element array of finite numbers, non-zero.
  let drive = payload{"drive"}
  if drive.isNil or drive.kind != JArray or drive.len != 2:
    return (order, false)
  var
    okX = false
    okY = false
  let
    dx = strictNumber(drive[0], okX)
    dy = strictNumber(drive[1], okY)
  if not okX or not okY or dx < -1.0 or dx > 1.0 or dy < -1.0 or dy > 1.0:
    return (order, false)
  let quantised = quantUnit(dx, dy)
  if quantised.x == 0 and quantised.y == 0:
    return (order, false)
  order.driveX = quantised.x
  order.driveY = quantised.y

  var ok = false
  let effort = strictNumber(payload{"effort"}, ok)
  if not ok or effort < 0.0 or effort > 1.0:
    return (order, false)
  order.effort = quantUnsigned(effort)

  ok = false
  let yielded = strictNumber(payload{"yield"}, ok)
  if not ok or yielded < 0.0 or yielded > 1.0:
    return (order, false)
  order.yieldQ = quantUnsigned(yielded)

  ok = false
  let twist = strictNumber(payload{"twist"}, ok)
  if not ok or twist < -1.0 or twist > 1.0:
    return (order, false)
  order.twist = quantSigned(twist)

  ok = false
  let brace = strictNumber(payload{"brace"}, ok)
  if not ok or brace < 0.0 or brace > 1.0:
    return (order, false)
  order.brace = quantUnsigned(brace)

  (order, true)
