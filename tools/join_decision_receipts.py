"""Join a private ordinary-player ACK to the recorded order for the same seat and turn."""

import argparse
import hashlib
import json
import re
import zipfile
from pathlib import Path

from replay_summary import decompress, parse


def check_identity(label, actual, expected):
    if actual is None:
        return False
    if type(actual) is not type(expected) or actual != expected:
        raise ValueError(f"{label} differs from expected {expected!r}")
    return True


def index_turns(rows, label):
    indexed = {}
    unkeyed = 0
    for row in rows:
        turn = row.get("turn")
        if turn is None:
            unkeyed += 1
            continue
        if type(turn) is not int or turn < 0:
            raise ValueError(f"invalid {label} turn {turn!r}")
        if turn in indexed:
            raise ValueError(f"duplicate {label} turn {turn}")
        indexed[turn] = row
    return indexed, unkeyed


def exact_order(row):
    if row is None or any(row.get(k) is None for k in ("q", "note", "say")):
        return None
    q = row["q"]
    if not (
        isinstance(q, list)
        and len(q) == 6
        and all(type(x) is int for x in q)
        and isinstance(row["note"], str)
        and isinstance(row["say"], str)
    ):
        raise ValueError("invalid quantized order")
    return q, row["note"], row["say"]


def join_turn(turn, seat, ack, order, bound):
    accepted = ack.get("accepted")
    selected = ack.get("selected_attempt_id")
    if accepted is not None and type(accepted) is not bool:
        raise ValueError(f"invalid acceptance at turn {turn}")
    attempts = {}
    for attempt in ack.get("attempts") or []:
        ident = attempt.get("attempt_id")
        if ident is None:
            continue
        if not re.fullmatch(rf"{turn}-{seat}-[1-9][0-9]*", ident) or ident in attempts:
            raise ValueError(f"invalid or duplicate attempt identity at turn {turn}")
        attempts[ident] = attempt
    if selected is not None and (
        accepted is False or not re.fullmatch(rf"{turn}-{seat}-[1-9][0-9]*", selected)
    ):
        raise ValueError(f"inconsistent selected attempt at turn {turn}")
    source = order.get("source")
    status = "unknown"
    if bound:
        acknowledged, executed = (
            exact_order(ack.get("executed_action")),
            exact_order(order),
        )
        if acknowledged is not None and executed is not None and acknowledged != executed:
            raise ValueError(f"executed order differs at turn {turn}")
        if source is not None and accepted is not None and accepted != (source == "external"):
            raise ValueError(f"replay source contradicts ACK at turn {turn}")
        if (
            accepted is not None
            and source is not None
            and acknowledged is not None
            and executed is not None
        ):
            if accepted and selected in attempts:
                status = "verified_accepted"
            elif (
                not accepted and source == "fallback" and "selected_attempt_id" in ack and selected is None
            ):
                status = "verified_fallback"
    return {
        "turn": turn,
        "ack_accepted": accepted,
        "selected_attempt_id": selected,
        "platform_call_id": attempts.get(selected, {}).get("platform_call_id"),
        "attempt_source": attempts.get(selected, {}).get("source"),
        "replay_source": source,
        "join": status,
    }


def audit(seed, seat, replay_path=None, artifact_path=None):
    receipt = {}
    if artifact_path:
        with zipfile.ZipFile(artifact_path) as archive:
            if archive.namelist().count("decision_results.json") > 1:
                raise ValueError("duplicate decision_results.json")
            if "decision_results.json" in archive.namelist():
                receipt = json.loads(archive.read("decision_results.json"))
                check_identity("receipt version", receipt.get("schema_version"), 1)
    replay, digest = {}, None
    if replay_path:
        raw = decompress(replay_path.read_bytes())
        replay = parse(raw)
        digest = hashlib.sha256(raw).hexdigest()
        if replay["utf8Repairs"]:
            raise ValueError("replay required UTF-8 repairs")

    game_ok = check_identity("receipt game", receipt.get("game"), "tandem")
    seed_ok = check_identity("receipt seed", receipt.get("seed"), seed)
    seat_ok = check_identity("receipt seat", receipt.get("slot"), seat)
    replay_game = check_identity("replay game", replay.get("gameName"), "tandem")
    replay_seed = check_identity("replay seed", replay.get("seed"), seed)
    hash_ok = digest is not None and check_identity(
        "receipt replay digest", receipt.get("replay_sha256"), digest
    )
    bound = (
        receipt.get("schema_version") == 1
        and game_ok
        and seed_ok
        and seat_ok
        and replay_game
        and replay_seed
        and hash_ok
    )

    receipt_rows = receipt.get("results") or []
    acks, unkeyed_acks = index_turns(receipt_rows if seat_ok else [], "ACK")
    seat_orders = []
    missing_seat = 0
    for order in replay.get("orders", []):
        if order["seat"] is None:
            missing_seat += 1
            continue
        if type(order["seat"]) is not int or order["seat"] not in (0, 1):
            raise ValueError("invalid replay order seat")
        if order["seat"] == seat:
            seat_orders.append(order)
    orders, unkeyed_orders = index_turns(seat_orders, "replay order")
    # Dict insertion order preserves the sequence in decision_results.json.
    highest_turn = -1
    out_of_order = []
    for turn in acks:
        if turn < highest_turn:
            out_of_order.append(turn)
        else:
            highest_turn = turn
    turns = [
        {**join_turn(t, seat, acks.get(t, {}), orders.get(t, {}), bound), "ack_present": t in acks}
        for t in sorted(acks.keys() | orders.keys())
    ]
    return {
        "game": "tandem",
        "seed": seed,
        "seat": seat,
        "replay_sha256": digest,
        "receipt_bound_to_replay": bound,
        "keyed_receipts": len(acks),
        "keyed_orders": len(orders),
        "out_of_order_ack_turns": out_of_order,
        "unkeyed_receipts": unkeyed_acks if seat_ok else len(receipt_rows),
        "unkeyed_orders": unkeyed_orders + missing_seat,
        "turns": turns,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, required=True)
    parser.add_argument("--seat", type=int, choices=(0, 1), required=True)
    parser.add_argument("--replay", type=Path)
    parser.add_argument("--receipt", type=Path, help="private player artifact ZIP")
    args = parser.parse_args()
    if not (args.replay or args.receipt):
        parser.error("supply a replay or a receipt")
    try:
        report = audit(args.seed, args.seat, args.replay, args.receipt)
    except (OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile) as error:
        parser.exit(1, f"join failed: {error}\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
