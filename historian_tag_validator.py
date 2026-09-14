#!/usr/bin/env python3
"""Compare Wonderware and Canary historian tag exports.

Expected input workbook layout:
  Wonderware: tag in column C, description in column F
  Canary:     tag in column A, description in column B

Install dependencies:
  py -m pip install pandas openpyxl

Example:
  py historian_tag_validator.py "historian tags.xlsx"
  py historian_tag_validator.py "historian tags.xlsx" -o "validation.xlsx"
"""

from __future__ import annotations

import argparse
import re
from collections import Counter, defaultdict
from difflib import SequenceMatcher
from pathlib import Path

import pandas as pd
from openpyxl import Workbook
from openpyxl.formatting.rule import FormulaRule
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter


OLD_PREFIX_TO_TAM = {
    **{letter: number for letter, number in zip("ABCDEFGHIJ", range(1, 11))},
    "K": 15, "L": 16, "M": 17, "N": 18, "O": 19, "S": 20,
}
LATER_TAMS = set(range(21, 34))
GENERIC_WORDS = {
    "TAM", "LINE", "HMI", "PLC", "AS", "CALC", "DATA", "DATAPLC",
    "INT", "REAL", "BOOL", "DINT", "TAG", "VALUE", "VAL",
}


def text(value) -> str:
    return "" if pd.isna(value) else str(value).strip()


def normalized(value) -> str:
    return re.sub(r"[^A-Z0-9]+", "", text(value).upper())


def useful_tokens(value) -> set[str]:
    value = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", text(value))
    words = re.split(r"[^A-Za-z0-9]+", value.upper())
    return {w for w in words if len(w) >= 4 and w not in GENERIC_WORDS and not w.isdigit()}


def wonderware_line_and_body(tag: str):
    """Return expected TAM, tag body, and the applied prefix rule."""
    upper = text(tag).upper()

    # L21-L33 must be recognized before the older single-letter L prefix.
    match = re.match(r"^L(\d{2})(?:_|\b)", upper)
    if match and int(match.group(1)) in LATER_TAMS:
        line = int(match.group(1))
        body = re.sub(r"^L\d{2}_?", "", upper, count=1)
        return line, body, f"L{line:02d}→TAM{line:02d}"

    # Plain L_ is the older TAM16 convention. Other L-number prefixes remain
    # unknown so tags such as L51 are not incorrectly forced onto TAM16.
    if upper.startswith("L_"):
        return 16, upper[2:], "L→TAM16"
    if upper.startswith("L"):
        return None, upper, "Unmapped L-prefix (not L21–L33)"

    if upper and upper[0] in OLD_PREFIX_TO_TAM:
        line = OLD_PREFIX_TO_TAM[upper[0]]
        return line, upper[1:].lstrip("_-"), f"{upper[0]}→TAM{line:02d}"

    return None, upper, "No mapped line prefix"


def canary_line(tag: str):
    upper = text(tag).upper()
    match = re.search(r"(?:^|[._])TAM0?(\d{1,2})(?=[._]|$)", upper)
    if not match:
        match = re.search(r"(?:^|[._])T0?(\d{1,2})(?=[._]|$)", upper)
    return int(match.group(1)) if match else None


def canary_tag_body(tag: str, line):
    leaf = text(tag).split(".")[-1].upper()
    if line:
        leaf = re.sub(fr"^(?:TAM|T|L)0?{line}(?:_|\.)?", "", leaf)
    return re.sub(
        r"^(?:HMI|AS|CALC|DATAPLC|PLC|INT|REAL|BOOL|DINT)(?:\d+)?_",
        "", leaf,
    )


def choose(candidate_ids, match_type, score, note=""):
    ids = sorted(set(candidate_ids))
    if not ids:
        return None
    if len(ids) > 1:
        return {
            "idx": ids[0], "type": f"Ambiguous: {match_type}",
            "score": min(score, 79), "count": len(ids),
            "note": note or "Multiple Canary tags satisfy the same rule; review required.",
        }
    return {"idx": ids[0], "type": match_type, "score": score, "count": 1, "note": note}


def compare_tags(input_path: Path):
    ww = pd.read_excel(input_path, sheet_name="Wonderware", usecols="C,F", dtype=str).fillna("")
    canary = pd.read_excel(input_path, sheet_name="Canary", usecols="A,B", dtype=str).fillna("")
    ww.columns = ["tag", "description"]
    canary.columns = ["tag", "description"]

    rows = []
    full_idx = defaultdict(list)
    leaf_idx = defaultdict(list)
    global_leaf_idx = defaultdict(list)
    body_idx = defaultdict(list)
    description_idx = defaultdict(list)
    global_description_idx = defaultdict(list)
    token_idx = defaultdict(set)

    print(f"Indexing {len(canary):,} Canary tags...")
    for i, record in canary.iterrows():
        tag, description = text(record.tag), text(record.description)
        line = canary_line(tag)
        leaf = tag.split(".")[-1]
        body = canary_tag_body(tag, line)
        item = {
            "tag": tag, "description": description, "line": line,
            "leaf_key": normalized(leaf), "body_key": normalized(body),
            "description_key": normalized(description),
            "tokens": useful_tokens(body + " " + description),
        }
        rows.append(item)
        full_idx[normalized(tag)].append(i)
        leaf_idx[(line, item["leaf_key"])].append(i)
        global_leaf_idx[item["leaf_key"]].append(i)
        body_idx[(line, item["body_key"])].append(i)
        description_idx[(line, item["description_key"])].append(i)
        global_description_idx[item["description_key"]].append(i)
        for token in item["tokens"]:
            token_idx[(line, token)].add(i)

    output = []
    matched_canary = set()
    print(f"Comparing {len(ww):,} Wonderware tags...")
    for row_number, record in enumerate(ww.itertuples(index=False), 1):
        tag, description = text(record.tag), text(record.description)
        line, body, prefix_rule = wonderware_line_and_body(tag)
        body_key, description_key = normalized(body), normalized(description)
        selected = None

        if line is not None:
            selected = choose(leaf_idx.get((line, normalized(tag)), []), "Exact Canary leaf", 100)
            if not selected:
                selected = choose(body_idx.get((line, body_key), []), "Translated line + exact tag body", 99)
            if not selected and description_key:
                selected = choose(description_idx.get((line, description_key), []), "Translated line + exact description", 96)
        else:
            selected = choose(full_idx.get(normalized(tag), []), "Exact full tag", 100)
            if not selected:
                selected = choose(global_leaf_idx.get(normalized(tag), []), "Exact Canary leaf (line unknown)", 93)
            if not selected and description_key:
                selected = choose(global_description_idx.get(description_key, []), "Exact description (line unknown)", 86)

        # Only five same-line token candidates receive the slower fuzzy score.
        if not selected:
            source_tokens = useful_tokens(body + " " + description)
            candidates = set()
            for token in source_tokens:
                candidates |= token_idx.get((line, token), set())
            if len(candidates) <= 600:
                ranked = []
                for i in candidates:
                    overlap = len(source_tokens & rows[i]["tokens"])
                    length_gap = abs(len(body_key) - len(rows[i]["body_key"]))
                    ranked.append((overlap, -length_gap, i))
                best = []
                for _, _, i in sorted(ranked, reverse=True)[:5]:
                    candidate = rows[i]
                    tag_score = SequenceMatcher(None, body_key, candidate["body_key"]).ratio() if body_key else 0
                    desc_score = SequenceMatcher(None, description_key, candidate["description_key"]).ratio() if description_key else 0
                    score = round(100 * (0.68 * tag_score + 0.32 * desc_score))
                    if score >= 78:
                        best.append((score, i))
                best.sort(reverse=True)
                if best:
                    top_score, top_idx = best[0]
                    close_count = sum(score >= top_score - 2 for score, _ in best)
                    if top_score >= 90 and close_count == 1:
                        selected = {"idx": top_idx, "type": "Strong normalized similarity", "score": top_score, "count": 1, "note": "Same line; tag body and description jointly agree."}
                    else:
                        selected = {"idx": top_idx, "type": "Possible fuzzy match", "score": min(top_score, 84), "count": close_count, "note": "Review before accepting; close candidates or weaker normalized similarity."}

        if selected:
            candidate = rows[selected["idx"]]
            matched_canary.add(selected["idx"])
            if selected["score"] >= 95 and selected["count"] == 1:
                status = "Validated"
            elif selected["score"] >= 85 and selected["count"] == 1:
                status = "Probable"
            else:
                status = "Review"
            output.append([
                tag, description, line or "", prefix_rule,
                candidate["tag"], candidate["description"], selected["type"],
                selected["score"], status, selected["count"], selected["note"],
            ])
        else:
            note = "No Canary candidate found within the mapped TAM line." if line else "No reliable candidate found; line identity could not be inferred."
            output.append([tag, description, line or "", prefix_rule, "", "", "No reliable match", 0, "Missing / Unresolved", 0, note])

        if row_number % 10000 == 0:
            print(f"  Processed {row_number:,}/{len(ww):,}")

    unmatched_by_line = Counter()
    for i, candidate in enumerate(rows):
        if i not in matched_canary:
            unmatched_by_line[str(candidate["line"] or "Unknown")] += 1

    headers = [
        "Wonderware Tag", "Wonderware Description", "Expected TAM", "Prefix Rule",
        "Canary Tag", "Canary Description", "Match Method", "Confidence", "Status",
        "Candidate Count", "Review Note",
    ]
    return output, headers, len(ww), len(canary), len(matched_canary), unmatched_by_line


def style_header(cells):
    fill = PatternFill("solid", fgColor="17365D")
    for cell in cells:
        cell.fill = fill
        cell.font = Font(color="FFFFFF", bold=True)
        cell.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)


def write_report(output_path: Path, results, headers, ww_count, canary_count, matched_count, unmatched_by_line):
    workbook = Workbook(write_only=False)
    summary = workbook.active
    summary.title = "Validation Summary"
    detail = workbook.create_sheet("Tag Validation")
    reverse = workbook.create_sheet("Canary Reverse Summary")
    method = workbook.create_sheet("Methodology")

    navy, green, blue, amber, red = "17365D", "E2F0D9", "D9EAF7", "FFF2CC", "FCE4D6"
    thin = Side(style="thin", color="BFBFBF")
    statuses = Counter(row[8] for row in results)
    line_stats = defaultdict(Counter)
    for row in results:
        line_stats[str(row[2] or "Unknown")][row[8]] += 1

    summary["A2"] = "Historian Tag Migration Validation"
    summary["A2"].font = Font(size=16, bold=True, color=navy)
    summary.append([])
    for item in [
        ("Source workbook", "Generated by historian_tag_validator.py"),
        ("Wonderware tags", ww_count), ("Canary tags", canary_count),
        ("Validated", statuses["Validated"]), ("Probable", statuses["Probable"]),
        ("Review", statuses["Review"]), ("Missing / Unresolved", statuses["Missing / Unresolved"]),
    ]:
        summary.append(item)
    summary.append([])
    summary.append(["Expected TAM", "Validated", "Probable", "Review", "Missing / Unresolved"])
    style_header(summary[12])
    line_keys = sorted(line_stats, key=lambda x: (x == "Unknown", int(x) if x.isdigit() else 999))
    for key in line_keys:
        counts = line_stats[key]
        summary.append([key, counts["Validated"], counts["Probable"], counts["Review"], counts["Missing / Unresolved"]])
    for width, column in [(24,"A"),(16,"B"),(14,"C"),(16,"D"),(24,"E")]:
        summary.column_dimensions[column].width = width
    summary.freeze_panes = "A13"

    detail.append(headers)
    style_header(detail[1])
    for row in results:
        detail.append(row)
    detail.freeze_panes = "C2"
    detail.auto_filter.ref = f"A1:K{detail.max_row}"
    widths = [35,35,12,25,75,45,40,12,22,16,60]
    for i, width in enumerate(widths, 1):
        detail.column_dimensions[get_column_letter(i)].width = width
    fills = {
        "Validated": (green,"375623"), "Probable": (blue,navy),
        "Review": (amber,"7F6000"), "Missing / Unresolved": (red,"9C0006"),
    }
    for status, (fill, font_color) in fills.items():
        detail.conditional_formatting.add(
            f"I2:I{detail.max_row}",
            FormulaRule(formula=[f'$I2="{status}"'], fill=PatternFill("solid", fgColor=fill), font=Font(color=font_color, bold=True)),
        )

    reverse["A2"] = "Canary Tags Not Selected by a Wonderware Match"
    reverse["A2"].font = Font(size=16, bold=True, color=navy)
    reverse.append([])
    reverse.append(["Canary tags", canary_count])
    reverse.append(["Selected by at least one match", matched_count])
    reverse.append(["Not selected", canary_count - matched_count])
    reverse.append(["Interpretation", "Unselected tags may be new Canary-only content, duplicate structures, or unmatched migration records."])
    reverse.append([]); reverse.append([])
    reverse.append(["Detected TAM", "Unselected Canary Tags"])
    style_header(reverse[10])
    reverse_keys = sorted(unmatched_by_line, key=lambda x: (x == "Unknown", int(x) if x.isdigit() else 999))
    for key in reverse_keys:
        reverse.append([key, unmatched_by_line[key]])
    reverse.column_dimensions["A"].width = 32
    reverse.column_dimensions["B"].width = 95

    methodology = [
        ("1. Determine line", "Translate older letter prefixes and L21–L33 before comparing tags."),
        ("2. Enforce same TAM", "Mapped Wonderware lines are compared only with Canary tags detected for that TAM."),
        ("3. Exact checks", "Compare Canary leaf and normalized tag body after removing hierarchy/controller prefixes."),
        ("4. Description", "Use normalized descriptions as supporting evidence; duplicates remain ambiguous."),
        ("5. Fuzzy check", "Consider only bounded same-line candidates sharing meaningful tokens."),
        ("6. Reverse check", "Count Canary tags not selected by any Wonderware match."),
    ]
    method["A2"] = "Matching Methodology"
    method["A2"].font = Font(size=16, bold=True, color=navy)
    method.append([]); method.append(["Rule", "How it is used"])
    style_header(method[4])
    for row in methodology:
        method.append(row)
    method.column_dimensions["A"].width = 32
    method.column_dimensions["B"].width = 110

    for sheet in workbook.worksheets:
        sheet.sheet_view.showGridLines = False
        for cell in sheet[1]:
            cell.border = Border(bottom=thin)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    workbook.save(output_path)


def main():
    parser = argparse.ArgumentParser(description="Validate Wonderware tags against a Canary migration export.")
    parser.add_argument("input", type=Path, help="Workbook containing Wonderware and Canary sheets")
    parser.add_argument("-o", "--output", type=Path, help="Output report path")
    args = parser.parse_args()
    if not args.input.exists():
        parser.error(f"Input file does not exist: {args.input}")
    output_path = args.output or args.input.with_name(args.input.stem + "_validation.xlsx")
    results = compare_tags(args.input)
    print(f"Writing {output_path}...")
    write_report(output_path, *results)
    print(f"Done: {output_path.resolve()}")


if __name__ == "__main__":
    main()
