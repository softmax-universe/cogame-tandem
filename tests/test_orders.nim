## Strict order parsing and rune-boundary truncation that keeps a
## replay parseable by a strict UTF-8 reader.

import std/[json, random, strutils, unicode]
import lib/helpers

proc parse(text: string): tuple[order: Order, usable: bool] =
  let payload = parseJson(text)
  parseOrder(payload, 3)

proc completeAction() =
  let got = parse("""{"note":"easing in","drive":[0.6,-0.8],"effort":0.4,
 "yield":0.3,"twist":-0.5,"brace":0.9,"say":"you lead"}""")
  doAssert got.usable
  doAssert got.order.effort == 102, "effort quantised to " & $got.order.effort
  doAssert got.order.yieldQ == 77
  doAssert got.order.twist == -128, "twist quantised to " & $got.order.twist
  doAssert got.order.brace == 230
  doAssert got.order.note == "easing in"
  doAssert got.order.say == "you lead"
  let magnitude = speedOf(got.order.driveX, got.order.driveY)
  doAssert abs(magnitude - 4096) <= 2,
    "drive was not quantised to a unit vector: " & $magnitude
  report "a complete player action parses"

proc zeroDrive() =
  var sim = carryingSim(testConfig())
  for effort in [0.0, 0.5]:
    for twist in [0.0, 1.0]:
      let got = parseOrder(%*{"drive": [0, 0], "effort": effort,
        "yield": 0, "brace": 0, "twist": twist}, 3)
      doAssert got.usable
      doAssert got.order.driveX == 0 and got.order.driveY == 0
      sim.activeOrder[ord(Cobalt)] = got.order
      doAssert (sim.seatForce(Cobalt).force == (0'i32, 0'i32)) == (twist == 0)
  report "zero drive adds no push and leaves twist available"

proc legacyShimsAreRejected() =
  ## Legacy representations (object drive, numeric strings, integer percentages)
  ## are rejected rather than silently repaired.
  for text in [
      """{"drive":{"x":1,"y":0},"effort":0.5,"yield":0.2,"twist":0,"brace":0}""",
      """{"drive":[1,0],"effort":"0.5","yield":0.2,"twist":0,"brace":0}""",
      """{"drive":[1,0],"effort":45,"yield":0.2,"twist":0,"brace":0}""",
      """{"drive":[1,0],"effort":0.5,"yield":80,"twist":0,"brace":0}""",
      """{"drive":[1,0],"effort":0.5,"yield":0.2,"twist":"-25","brace":0}"""]:
    let got = parse(text)
    doAssert not got.usable, "legacy shim was accepted: " & text
  report "legacy object drive, string numbers, and percentages are rejected"

proc missingAndInvalidAreRejected() =
  ## Missing, null, wrong-type, or out-of-range control fields are
  ## rejected rather than fabricated from previous turns or defaults.
  for text in [
      """{"note":"hm","drive":[1,0],"effort":null,"yield":0.2,"twist":0,"brace":0}""",
      """{"drive":[1,0],"effort":0.5}""",
      """{"drive":[null,1],"effort":0.5,"yield":0.2,"twist":0,"brace":0}""",
      """{"drive":"north","effort":0.5,"yield":0.2,"twist":0,"brace":0}""",
      """{"drive":[9,-9],"effort":0.5,"yield":0.2,"twist":0,"brace":0}""",
      """{"drive":[1,0],"effort":1.5,"yield":0.2,"twist":0,"brace":0}""",
      """{"drive":[1,0],"effort":0.5,"yield":-0.1,"twist":0,"brace":0}""",
      """{"drive":[1,0],"effort":0.5,"yield":0.2,"twist":1.5,"brace":0}""",
      """{"drive":[1,0],"effort":0.5,"yield":0.2,"twist":0,"brace":2}""",
      """{"weather":"fine"}"""]:
    let got = parse(text)
    doAssert not got.usable, "invalid order was accepted: " & text
  report "missing and out-of-range fields are rejected"

proc runeTruncation() =
  ## The 48th and 49th characters of `say` are a 4-byte emoji: the truncation
  ## must land on the RUNE boundary and the result must still round-trip
  ## through `%$` -> parseJson and decode as UTF-8.
  let padding = repeat("a", 47)
  let say = padding & "\u{1F6CB}\u{1F6CB}\u{1F6CB}"
  let note = repeat("n", 158) & "\u{1F6CB}\u{1F6CB}\u{1F6CB}"
  let body = $ %*{"note": note, "say": say, "drive": [1, 0], "effort": 0.5,
                  "yield": 0.2, "twist": 0.0, "brace": 0.0}
  let got = parse(body)
  doAssert got.usable
  doAssert got.order.say.runeLen <= MaxSayRunes,
    "say is " & $got.order.say.runeLen & " runes"
  doAssert got.order.note.runeLen <= MaxNoteRunes
  doAssert isValidUtf8(got.order.say), "say was cut mid-character"
  doAssert isValidUtf8(got.order.note), "note was cut mid-character"
  doAssert runeCount(got.order.say) == got.order.say.runeLen
  let record = capRecord($orderJson(carryingSim(testConfig()), Cobalt,
    got.order))
  doAssert isValidUtf8(record), "the order record is not valid UTF-8"
  let reparsed = parseJson(record)
  doAssert reparsed["k"].getStr() == "order"
  doAssert record.runeLen <= MaxOrderRecordRunes
  report "rune-boundary truncation survives a 4-byte emoji on the boundary"

proc fallbackDetailsAreRuneSafe() =
  ## Player transport errors can reach replay fallback.detail. Each cut must
  ## preserve complete runes, including near the cap's byte boundary.
  for pad in 0 .. 3:
    let detail = repeat("x", pad) & repeat("\u{1F600}", 400)
    let clipped = clipRunes(detail, MaxDetailRunes)
    doAssert isValidUtf8(clipped), "fallback.detail is not valid UTF-8"
    doAssert clipped.runeLen == MaxDetailRunes
  report "player fallback detail is cut on rune boundaries"

proc oversizeRecordStaysJson() =
  ## An over-long record is shrunk STRUCTURALLY, so it is always parseable —
  ## a blind clip would cut the object mid-key and silently drop the order.
  var order = emptyOrder()
  order.note = repeat("\"\\", 200)
  order.say = repeat("\"\\", 100)
  let record = capRecord($orderJson(carryingSim(testConfig()), Rust, order))
  doAssert record.runeLen <= MaxOrderRecordRunes,
    "the record is " & $record.runeLen & " runes"
  let node = parseJson(record)
  doAssert node["k"].getStr() == "order"
  doAssert node.hasKey("q") and node["q"].len == 6,
    "the quantised order did not survive the structural shrink"
  report "an over-long order record shrinks structurally and stays JSON"

proc recordRoundTrips() =
  ## `orderJson` -> `orderFromRecord` is the exact path playback takes.
  var rng = initRand(4242)
  var sim = carryingSim(testConfig())
  for _ in 0 ..< 200:
    let order = pseudoOrder(rng)
    let record = capRecord($orderJson(sim, Cobalt, order))
    let back = orderFromRecord(parseJson(record))
    doAssert back.ok
    doAssert back.order.driveX == order.driveX
    doAssert back.order.driveY == order.driveY
    doAssert back.order.effort == order.effort
    doAssert back.order.yieldQ == order.yieldQ
    doAssert back.order.twist == order.twist
    doAssert back.order.brace == order.brace
  report "every quantised field round-trips through the replay record"

proc extractRejectsProseAndMultipleFences() =
  let raw = """{"drive":[1,0],"effort":0.5,"yield":0.2,"twist":0,"brace":0}"""
  doAssert extractOrderObject(raw)["effort"].getFloat() == 0.5
  doAssert extractOrderObject("```json\n" & raw & "\n```")["effort"].getFloat() == 0.5
  for bad in [
      "Sure, here is my move: " & raw,
      raw & " extra",
      "```json\n" & raw & "\n```\n```json\n" & raw & "\n```",
      "```json\n" & raw]:
    var raised = false
    try:
      discard extractOrderObject(bad)
    except ValueError:
      raised = true
    doAssert raised, "prose or invalid fence was accepted: " & bad
  report "extractOrderObject accepts raw JSON or one fence and rejects brace scraping"

when isMainModule:
  completeAction()
  zeroDrive()
  legacyShimsAreRejected()
  missingAndInvalidAreRejected()
  extractRejectsProseAndMultipleFences()
  runeTruncation()
  fallbackDetailsAreRuneSafe()
  oversizeRecordStaysJson()
  recordRoundTrips()
  echo "test_orders: parsing is strict and truncation is rune-safe"
