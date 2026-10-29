#!/usr/bin/env python3
"""Analyze P2 raw Polar output and make dependency-free SVG charts."""

from __future__ import annotations

import argparse
import csv
import html
import json
import math
import shutil
import statistics
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

PROJECT_ROOT = Path(__file__).resolve().parents[1]
KNOTS_PER_MPS = 1.9438444924406
STATUSES = ["STABLE", "NO_FORWARD_PROGRESS", "HEADING_FAILED", "UNSTABLE", "TIMEOUT", "INVALID", "INTERRUPTED"]
STATUS_COLORS = {
    "STABLE": "#2f9e72",
    "NO_FORWARD_PROGRESS": "#e3a33a",
    "HEADING_FAILED": "#d25b53",
    "UNSTABLE": "#9b72bd",
    "TIMEOUT": "#657b91",
    "INVALID": "#262f38",
    "INTERRUPTED": "#aab2b9",
}
PALETTE = ["#1769aa", "#d1495b", "#2a9d8f", "#8a5fbf", "#e08e0b", "#4f6d7a", "#b56576"]


def f(row: dict[str, Any], key: str, default: float = math.nan) -> float:
    value = row.get(key)
    try:
        return float(value) if value not in (None, "") else default
    except (TypeError, ValueError):
        return default


def valid(value: float) -> bool:
    return math.isfinite(value)


def read_input(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or not isinstance(data.get("results"), list):
        raise ValueError("Runner JSON must contain a results array")
    return data


def status_counts(rows: list[dict[str, Any]]) -> dict[str, int]:
    counts = Counter(str(row.get("status", "INVALID")) for row in rows)
    return {status: counts.get(status, 0) for status in STATUSES if counts.get(status, 0)}


def quality_gate(data: dict[str, Any]) -> dict[str, Any]:
    metadata = data.get("metadata", {})
    cases = data.get("cases", [])
    rows = data.get("results", [])
    errors: list[str] = []
    warnings: list[str] = []
    expected_ids = [str(c.get("case_id", "")) for c in cases if isinstance(c, dict)]
    row_ids = [str(r.get("case_id", "")) for r in rows if isinstance(r, dict)]
    duplicates = sorted(k for k, count in Counter(row_ids).items() if count > 1)
    missing = sorted(set(expected_ids) - set(row_ids))
    unexpected = sorted(set(row_ids) - set(expected_ids))
    if len(rows) != len(cases) or missing or unexpected or duplicates:
        errors.append(f"case coverage mismatch: expected={len(cases)}, results={len(rows)}, missing={len(missing)}, unexpected={len(unexpected)}, duplicates={len(duplicates)}")
    if duplicates:
        errors.append("duplicate case IDs: " + ", ".join(duplicates[:8]))
    if missing:
        warnings.append("missing cases: " + ", ".join(missing[:8]))
    if unexpected:
        errors.append("unexpected case IDs: " + ", ".join(unexpected[:8]))

    expected_tws = sorted({round(float(c.get("target_tws_kn", 0.0)), 3) for c in cases if isinstance(c, dict)})
    expected_dt = f(metadata, "physics_step_seconds")
    engine_hz = f(metadata, "godot_physics_ticks_per_second_setting", f(metadata, "engine_physics_ticks_per_second", f(metadata, "physics_ticks_per_second")))
    time_scale = f(metadata, "godot_time_scale", f(metadata, "time_scale", 1.0))
    predicted_dt = time_scale / engine_hz if engine_hz > 0 else math.nan
    timing = {
        "engine_physics_ticks_per_second_setting": engine_hz,
        "time_scale": time_scale,
        "expected_simulated_step_seconds": expected_dt,
        "time_scale_divided_by_engine_ticks_seconds": predicted_dt,
        "effective_simulated_steps_per_second": 1.0 / expected_dt if expected_dt > 0 else None,
        "accelerated_execution_preserves_step": valid(predicted_dt) and valid(expected_dt) and abs(predicted_dt - expected_dt) <= 0.0005,
    }
    if not timing["accelerated_execution_preserves_step"]:
        errors.append("Engine time_scale / physics_ticks_per_second does not produce the configured simulated step")

    config_hashes = {str(r.get("boat_config_hash", "")) for r in rows}
    if len(config_hashes) > 1 or (config_hashes and str(metadata.get("boat_config_hash", "")) not in config_hashes):
        errors.append("results contain inconsistent boat configuration fingerprints")
    bad_rows: list[str] = []
    wrong_tws: list[str] = []
    wrong_auto: list[str] = []
    engine_on: list[str] = []
    wrong_wave: list[str] = []
    for row in rows:
        case_id = str(row.get("case_id", ""))
        observed_dt = f(row, "observed_physics_step_seconds")
        max_error = f(row, "maximum_physics_step_error_seconds")
        if not valid(observed_dt) or not valid(expected_dt) or abs(observed_dt - expected_dt) > 0.0005 or not valid(max_error) or max_error > 0.0005:
            bad_rows.append(case_id)
        if abs(f(row, "mean_tws_kn", math.inf) - f(row, "target_tws_kn", math.nan)) > 0.03:
            wrong_tws.append(case_id)
        if str(row.get("auto_trim_state", "")) != "AUTO":
            wrong_auto.append(case_id)
        if str(row.get("engine_state", "")) not in {"OFF", "关闭"}:
            engine_on.append(case_id)
        if not str(row.get("wave_mode", "")).startswith("static_zero_amplitude_sampler_enabled"):
            wrong_wave.append(case_id)
    for bad, text in [
        (bad_rows, "physics step mismatch"), (wrong_tws, "actual TWS mismatch"),
        (wrong_auto, "AUTO Trim disabled"), (engine_on, "engine not OFF"),
        (wrong_wave, "not using static zero-amplitude WaveSampler"),
    ]:
        if bad:
            errors.append(f"{text}: {len(bad)} row(s), e.g. {', '.join(bad[:5])}")
    unknown_status = sorted({str(row.get("status", "")) for row in rows} - set(STATUSES))
    if unknown_status:
        errors.append("unknown status values: " + ", ".join(unknown_status))
    invalid_count = sum(str(row.get("status", "")) == "INVALID" for row in rows)
    if invalid_count:
        errors.append(f"{invalid_count} INVALID result(s); inspect failure_reason before accepting data")
    if any(str(row.get("status", "")) in {"INTERRUPTED"} for row in rows):
        warnings.append("one or more cases are interrupted; resume the same checkpoint before finalizing")
    if any(str(row.get("status", "")) in {"TIMEOUT", "UNSTABLE", "HEADING_FAILED", "NO_FORWARD_PROGRESS"} for row in rows):
        warnings.append("physical/control failures are retained as measured statuses; they are not converted to zero-speed Polar points")

    status = status_counts(rows)
    complete = len(rows) == len(cases) and not missing and not unexpected and not duplicates and not status.get("INTERRUPTED", 0)
    return {
        "passed": not errors and complete,
        "complete": complete,
        "expected_case_count": len(cases),
        "result_count": len(rows),
        "expected_tws_kn": expected_tws,
        "status_counts": status,
        "timing": timing,
        "errors": errors,
        "warnings": warnings,
    }


def vmg_components(row: dict[str, Any]) -> tuple[float, float]:
    east = f(row, "mean_velocity_world_x_mps")
    south = f(row, "mean_velocity_world_z_mps")
    wind_from = f(row, "wind_from_deg")
    if not all(map(valid, (east, south, wind_from))):
        return math.nan, math.nan
    radians = math.radians(wind_from)
    upwind_east, upwind_south = math.sin(radians), -math.cos(radians)
    downwind_east, downwind_south = -upwind_east, -upwind_south
    upwind = (east * upwind_east + south * upwind_south) * KNOTS_PER_MPS
    downwind = (east * downwind_east + south * downwind_south) * KNOTS_PER_MPS
    return upwind, downwind


def grouped(rows: list[dict[str, Any]]) -> dict[tuple[float, float], list[dict[str, Any]]]:
    output: dict[tuple[float, float], list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        output[(round(f(row, "target_tws_kn", 0), 3), round(abs(f(row, "target_twa_deg", 0)), 3))].append(row)
    return output


def analyze_rows(rows: list[dict[str, Any]]) -> dict[str, Any]:
    statuses = status_counts(rows)
    stable = [row for row in rows if row.get("status") == "STABLE"]
    speeds_by_tws: dict[str, Any] = {}
    vmg_candidates: dict[str, dict[str, Any]] = {}
    for tws in sorted({round(f(row, "target_tws_kn"), 3) for row in rows}):
        same_wind = [row for row in stable if round(f(row, "target_tws_kn"), 3) == tws]
        fastest = max(same_wind, key=lambda r: f(r, "mean_sog_kn", -math.inf), default=None)
        cross = [r for r in same_wind if abs(abs(f(r, "target_twa_deg")) - 90.0) < 0.01]
        upwind: list[dict[str, Any]] = []
        downwind: list[dict[str, Any]] = []
        for row in same_wind:
            twa = abs(f(row, "target_twa_deg"))
            up_vmg, down_vmg = vmg_components(row)
            if twa <= 90.0 and valid(up_vmg):
                upwind.append({"vmg_kn": up_vmg, "twa_deg": f(row, "target_twa_deg"), "case_id": row.get("case_id"), "tack": row.get("tack")})
            if twa >= 90.0 and valid(down_vmg):
                downwind.append({"vmg_kn": down_vmg, "twa_deg": f(row, "target_twa_deg"), "case_id": row.get("case_id"), "tack": row.get("tack")})
        best_up = max(upwind, key=lambda r: r["vmg_kn"], default=None)
        best_down = max(downwind, key=lambda r: r["vmg_kn"], default=None)
        speeds_by_tws[f"{tws:g}"] = {
            "stable_point_count": len(same_wind),
            "maximum_stable_sog_kn": f(fastest, "mean_sog_kn") if fastest else None,
            "maximum_speed_twa_deg_signed": f(fastest, "target_twa_deg") if fastest else None,
            "crosswind_stable_sog_kn": statistics.fmean(f(r, "mean_sog_kn") for r in cross) if cross else None,
            "best_upwind_vmg_kn": best_up["vmg_kn"] if best_up else None,
            "best_upwind_twa_deg_signed": best_up["twa_deg"] if best_up else None,
            "best_downwind_vmg_kn": best_down["vmg_kn"] if best_down else None,
            "best_downwind_twa_deg_signed": best_down["twa_deg"] if best_down else None,
        }
        vmg_candidates[f"{tws:g}"] = {"upwind": upwind, "downwind": downwind}

    pair_rows = []
    for (tws, angle), pair in sorted(grouped(rows).items()):
        port = next((r for r in pair if r.get("tack") == "PORT"), None)
        starboard = next((r for r in pair if r.get("tack") == "STARBOARD"), None)
        if port is None or starboard is None:
            continue
        port_speed, starboard_speed = f(port, "mean_sog_kn"), f(starboard, "mean_sog_kn")
        diff = abs(port_speed - starboard_speed) if valid(port_speed) and valid(starboard_speed) else None
        mean_speed = (port_speed + starboard_speed) / 2.0 if valid(port_speed) and valid(starboard_speed) else math.nan
        port_heel, stbd_heel = f(port, "mean_heel_deg"), f(starboard, "mean_heel_deg")
        port_vmg, stbd_vmg = f(port, "mean_vmg_kn"), f(starboard, "mean_vmg_kn")
        port_leeway, stbd_leeway = f(port, "mean_leeway_deg"), f(starboard, "mean_leeway_deg")
        port_rudder, stbd_rudder = f(port, "mean_rudder_deg"), f(starboard, "mean_rudder_deg")
        pair_rows.append({
            "tws_kn": tws, "absolute_twa_deg": angle,
            "port_status": port.get("status"), "starboard_status": starboard.get("status"),
            "port_sog_kn": port_speed if valid(port_speed) else None,
            "starboard_sog_kn": starboard_speed if valid(starboard_speed) else None,
            "absolute_sog_difference_kn": diff,
            "relative_sog_difference": diff / mean_speed if diff is not None and mean_speed >= 0.5 else None,
            "relative_difference_applicable": bool(mean_speed >= 0.5),
            "port_vmg_kn": port_vmg if valid(port_vmg) else None,
            "starboard_vmg_kn": stbd_vmg if valid(stbd_vmg) else None,
            "absolute_vmg_difference_kn": abs(port_vmg - stbd_vmg) if valid(port_vmg) and valid(stbd_vmg) else None,
            "port_heel_deg": port_heel if valid(port_heel) else None,
            "starboard_heel_deg": stbd_heel if valid(stbd_heel) else None,
            "heel_mirror_residual_deg": abs(port_heel + stbd_heel) if valid(port_heel) and valid(stbd_heel) else None,
            "port_leeway_deg": port_leeway if valid(port_leeway) else None,
            "starboard_leeway_deg": stbd_leeway if valid(stbd_leeway) else None,
            "leeway_mirror_residual_deg": abs(port_leeway + stbd_leeway) if valid(port_leeway) and valid(stbd_leeway) else None,
            "port_rudder_deg": port_rudder if valid(port_rudder) else None,
            "starboard_rudder_deg": stbd_rudder if valid(stbd_rudder) else None,
            "rudder_mirror_residual_deg": abs(port_rudder + stbd_rudder) if valid(port_rudder) and valid(stbd_rudder) else None,
            "rudder_absolute_difference_deg": abs(abs(port_rudder) - abs(stbd_rudder)) if valid(port_rudder) and valid(stbd_rudder) else None,
            "status_match": port.get("status") == starboard.get("status"),
        })

    stable_time = [f(row, "stability_first_qualified_simulation_seconds") for row in stable if valid(f(row, "stability_first_qualified_simulation_seconds"))]
    completion_time = [f(row, "elapsed_simulation_seconds") for row in stable if valid(f(row, "elapsed_simulation_seconds"))]
    body_mean = [f(row, "mean_body_calculation_usec") for row in rows if valid(f(row, "mean_body_calculation_usec"))]
    body_p95 = [f(row, "p95_body_calculation_usec") for row in rows if valid(f(row, "p95_body_calculation_usec"))]
    return {
        "status_counts": statuses,
        "stable_count": len(stable),
        "valid_stable_fraction_of_results": len(stable) / len(rows) if rows else 0.0,
        "stable_mean_sog_kn": statistics.fmean(f(row, "mean_sog_kn") for row in stable) if stable else None,
        "stable_time_mean_sim_s": statistics.fmean(stable_time) if stable_time else None,
        "case_completion_time_mean_sim_s": statistics.fmean(completion_time) if completion_time else None,
        "mean_body_calculation_usec_across_cases": statistics.fmean(body_mean) if body_mean else None,
        "maximum_case_body_calculation_p95_usec": max(body_p95) if body_p95 else None,
        "by_tws_kn": speeds_by_tws,
        "wind_axis_vmg_candidates": vmg_candidates,
        "port_starboard_comparison": pair_rows,
    }


def anomalies(rows: list[dict[str, Any]]) -> list[str]:
    notes: list[str] = []
    grouped_rows = grouped(rows)
    for (tws, twa), pair in sorted(grouped_rows.items()):
        stable = [r for r in pair if r.get("status") == "STABLE"]
        if len(stable) == 1 and len(pair) == 2:
            notes.append(f"{tws:g} kn / |TWA| {twa:g}° has stable data on one tack only; retain opposite tack status and inspect its cause.")
    stable_by_wind_angle: dict[tuple[float, float], list[float]] = defaultdict(list)
    for row in rows:
        if row.get("status") == "STABLE":
            stable_by_wind_angle[(round(f(row, "target_tws_kn"), 3), round(abs(f(row, "target_twa_deg")), 3))].append(f(row, "mean_sog_kn"))
    for (tws, angle), values in stable_by_wind_angle.items():
        if values and max(values) - min(values) > 1.5:
            notes.append(f"{tws:g} kn / |TWA| {angle:g}° has >1.5 kn spread between stable observations; compare tack and force balance before smoothing.")
    nonstable_count = sum(str(row.get("status", "")) != "STABLE" for row in rows)
    if nonstable_count:
        notes.append(f"{nonstable_count} case(s) are not STABLE; they remain categorized and are omitted from valid speed curves.")
    if not notes:
        notes.append("No heuristic discontinuity flag was raised; this is not a claim that the model matches a measured real vessel.")
    return notes


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(json_safe(value), indent=2, ensure_ascii=False, allow_nan=False) + "\n", encoding="utf-8")


def json_safe(value: Any) -> Any:
    if isinstance(value, float):
        return value if math.isfinite(value) else None
    if isinstance(value, dict):
        return {str(key): json_safe(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_safe(item) for item in value]
    return value


def esc(text: Any) -> str:
    return html.escape(str(text), quote=True)


def svg_text(x: float, y: float, text: str, size: int = 13, color: str = "#233342", anchor: str = "middle") -> str:
    return f'<text x="{x:.1f}" y="{y:.1f}" text-anchor="{anchor}" font-family="Arial,sans-serif" font-size="{size}" fill="{color}">{esc(text)}</text>'


def svg_header(width: int, height: int, title: str, subtitle: str) -> list[str]:
    return [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        '<rect width="100%" height="100%" fill="#ffffff"/>',
        svg_text(24, 30, title, 20, "#14283a", "start"),
        svg_text(24, 52, subtitle, 12, "#586a79", "start"),
    ]


def stable_pair_speed(rows: list[dict[str, Any]]) -> dict[tuple[float, float], float]:
    result: dict[tuple[float, float], float] = {}
    for key, pair in grouped(rows).items():
        stable = [r for r in pair if r.get("status") == "STABLE"]
        if stable:
            result[key] = statistics.fmean(f(r, "mean_sog_kn") for r in stable if valid(f(r, "mean_sog_kn")))
    return result


def chart_polar(rows: list[dict[str, Any]], output: Path, prefix: str) -> None:
    width, height = 820, 740
    parts = svg_header(width, height, "Nordic 28 · Polar diagram", "Only STABLE physical samples are connected; outer status symbols are classifications, not zero-speed data.")
    cx, cy, radius = 390.0, 365.0, 260.0
    speeds = sorted({round(f(r, "target_tws_kn"), 3) for r in rows})
    max_speed = max((f(r, "mean_sog_kn") for r in rows if r.get("status") == "STABLE" and valid(f(r, "mean_sog_kn"))), default=2.0)
    radial_max = max(2.0, math.ceil(max_speed / 2.0) * 2.0)
    for tick in range(0, int(radial_max) + 1, max(1, int(radial_max / 4))):
        r = radius * tick / radial_max
        parts.append(f'<circle cx="{cx}" cy="{cy}" r="{r:.1f}" fill="none" stroke="#d4dde4" stroke-width="1"/>')
        if tick:
            parts.append(svg_text(cx + 7, cy - r - 3, f"{tick} kn", 10, "#657685", "start"))
    for angle in range(0, 181, 30):
        rad = math.radians(angle)
        x, y = cx + radius * math.sin(rad), cy - radius * math.cos(rad)
        parts.append(f'<line x1="{cx}" y1="{cy}" x2="{x:.1f}" y2="{y:.1f}" stroke="#e2e8ed"/>')
        parts.append(svg_text(cx + (radius + 20) * math.sin(rad), cy - (radius + 20) * math.cos(rad) + 4, f"{angle}°", 11, "#425567"))
    absolute_angles = sorted({round(abs(f(row, "target_twa_deg")), 3) for row in rows})
    angle_steps = [b - a for a, b in zip(absolute_angles, absolute_angles[1:]) if b > a]
    expected_gap = min(angle_steps) if angle_steps else 0.0
    for tws_index, tws in enumerate(speeds):
        color = PALETTE[tws_index % len(PALETTE)]
        for tack, side_sign, dash in [("PORT", -1.0, ' stroke-dasharray="7 4"'), ("STARBOARD", 1.0, "")]:
            by_angle: dict[float, dict[str, Any]] = {}
            for row in rows:
                if round(f(row, "target_tws_kn"), 3) != tws or row.get("status") != "STABLE":
                    continue
                angle = round(abs(f(row, "target_twa_deg")), 3)
                row_tack = str(row.get("tack", ""))
                if (angle in (0.0, 180.0) and row_tack == "SYMMETRIC") or row_tack == tack:
                    by_angle[angle] = row
            ordered_angles = sorted(by_angle)
            previous: tuple[float, float, float] | None = None
            for angle in ordered_angles:
                row = by_angle[angle]
                speed = f(row, "mean_sog_kn")
                if not valid(speed):
                    previous = None
                    continue
                rad = math.radians(angle)
                r = radius * speed / radial_max
                x = cx + side_sign * r * math.sin(rad)
                y = cy - r * math.cos(rad)
                if previous is not None and (expected_gap <= 0.0 or abs(angle - previous[0] - expected_gap) <= 0.01):
                    parts.append(f'<line x1="{previous[1]:.1f}" y1="{previous[2]:.1f}" x2="{x:.1f}" y2="{y:.1f}" stroke="{color}" stroke-width="2.5"{dash}/>')
                parts.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="4" fill="{color}"/>')
                previous = (angle, x, y)
    legend_y = 95
    for i, tws in enumerate(speeds):
        color = PALETTE[i % len(PALETTE)]
        x = 620 + (i % 2) * 95
        y = legend_y + (i // 2) * 22
        parts.append(f'<line x1="{x}" y1="{y}" x2="{x + 18}" y2="{y}" stroke="{color}" stroke-width="3"/>')
        parts.append(svg_text(x + 23, y + 4, f"{tws:g} kn", 11, "#233342", "start"))
    parts.append('<line x1="620" y1="162" x2="638" y2="162" stroke="#526474" stroke-width="2" stroke-dasharray="7 4"/>')
    parts.append(svg_text(644, 166, "Port", 10, "#425567", "start"))
    parts.append('<line x1="700" y1="162" x2="718" y2="162" stroke="#526474" stroke-width="2"/>')
    parts.append(svg_text(724, 166, "Starboard", 10, "#425567", "start"))
    parts.append(svg_text(610, 185, "NO_FORWARD_PROGRESS / other failures:", 12, "#425567", "start"))
    parts.append(svg_text(610, 205, "listed in result tables; not plotted at zero", 11, "#657685", "start"))
    # Plot one status glyph outside the radius to signal the status lane; its radius is not a boat speed.
    failures = [r for r in rows if r.get("status") != "STABLE"]
    for index, row in enumerate(failures[:50]):
        angle = abs(f(row, "target_twa_deg", 0.0))
        rad = math.radians(angle)
        r = radius + 11 + (index % 3) * 5
        tack = str(row.get("tack", ""))
        side_sign = -1.0 if tack == "PORT" else 1.0
        x, y = cx + side_sign * r * math.sin(rad), cy - r * math.cos(rad)
        color = STATUS_COLORS.get(str(row.get("status")), "#444")
        parts.append(f'<path d="M{x-3:.1f},{y-3:.1f} L{x+3:.1f},{y+3:.1f} M{x-3:.1f},{y+3:.1f} L{x+3:.1f},{y-3:.1f}" stroke="{color}" stroke-width="1.5"/>')
    parts.append('</svg>')
    output.write_text("\n".join(parts), encoding="utf-8")


def line_chart(output: Path, title: str, subtitle: str, x_label: str, y_label: str,
               series: list[tuple[str, str, list[tuple[float, float]]]], xmin: float, xmax: float,
               ymin: float, ymax: float, width: int = 900, height: int = 560,
               expected_x_step: float | None = None) -> None:
    parts = svg_header(width, height, title, subtitle)
    left, top, plot_w, plot_h = 80.0, 90.0, width - 120.0, height - 170.0
    if xmax <= xmin:
        xmax = xmin + 1.0
    if ymax <= ymin:
        ymax = ymin + 1.0
    def sx(x: float) -> float:
        return left + (x - xmin) / (xmax - xmin) * plot_w
    def sy(y: float) -> float:
        return top + plot_h - (y - ymin) / (ymax - ymin) * plot_h
    for i in range(6):
        x = xmin + (xmax - xmin) * i / 5
        y = ymin + (ymax - ymin) * i / 5
        parts.append(f'<line x1="{sx(x):.1f}" y1="{top}" x2="{sx(x):.1f}" y2="{top+plot_h}" stroke="#e7ecef"/>')
        parts.append(f'<line x1="{left}" y1="{sy(y):.1f}" x2="{left+plot_w}" y2="{sy(y):.1f}" stroke="#e7ecef"/>')
        parts.append(svg_text(sx(x), top + plot_h + 20, f"{x:.0f}", 10, "#526474"))
        parts.append(svg_text(left - 12, sy(y) + 4, f"{y:.1f}", 10, "#526474", "end"))
    parts.append(f'<line x1="{left}" y1="{top+plot_h}" x2="{left+plot_w}" y2="{top+plot_h}" stroke="#364c5c"/>')
    parts.append(f'<line x1="{left}" y1="{top}" x2="{left}" y2="{top+plot_h}" stroke="#364c5c"/>')
    parts.append(svg_text(left + plot_w / 2, height - 24, x_label, 12, "#283d4d"))
    parts.append(f'<text transform="translate(20 {top+plot_h/2:.1f}) rotate(-90)" text-anchor="middle" font-family="Arial,sans-serif" font-size="12" fill="#283d4d">{esc(y_label)}</text>')
    for s_index, (label, color, points) in enumerate(series):
        finite_points = sorted((x, y) for x, y in points if valid(x) and valid(y))
        step = expected_x_step
        if step is None:
            observed_steps = [b[0] - a[0] for a, b in zip(finite_points, finite_points[1:]) if b[0] > a[0]]
            step = min(observed_steps) if observed_steps else 0.0
        dash = ' stroke-dasharray="6 4"' if "PORT" in label or "Upwind" in label else ""
        segments: list[list[tuple[float, float]]] = []
        active_segment: list[tuple[float, float]] = []
        for point in finite_points:
            if active_segment and step > 0.0 and point[0] - active_segment[-1][0] > step + 0.01:
                segments.append(active_segment)
                active_segment = []
            active_segment.append(point)
        if active_segment:
            segments.append(active_segment)
        for segment in segments:
            if len(segment) > 1:
                coords = " ".join(f"{sx(x):.1f},{sy(y):.1f}" for x, y in segment)
                parts.append(f'<polyline points="{coords}" fill="none" stroke="{color}" stroke-width="2"{dash}/>')
        for x, y in finite_points:
            if "PORT" in label:
                parts.append(f'<path d="M{sx(x):.1f},{sy(y)-4:.1f} l4,8 h-8 z" fill="{color}"/>')
            else:
                parts.append(f'<circle cx="{sx(x):.1f}" cy="{sy(y):.1f}" r="3.6" fill="{color}"/>')
        lx = left + 8 + (s_index % 5) * (plot_w / 5)
        ly = 72 + (s_index // 5) * 16
        parts.append(f'<line x1="{lx:.1f}" y1="{ly:.1f}" x2="{lx+15:.1f}" y2="{ly:.1f}" stroke="{color}" stroke-width="2"/>')
        parts.append(svg_text(lx + 19, ly + 4, label, 9, "#354b5b", "start"))
    parts.append('</svg>')
    output.write_text("\n".join(parts), encoding="utf-8")


def chart_vmg(rows: list[dict[str, Any]], output: Path) -> None:
    speeds = sorted({round(f(r, "target_tws_kn"), 3) for r in rows})
    angles = sorted({round(abs(f(r, "target_twa_deg")), 3) for r in rows})
    angle_steps = [b - a for a, b in zip(angles, angles[1:]) if b > a]
    expected_step = min(angle_steps) if angle_steps else None
    series = []
    all_values = []
    for index, tws in enumerate(speeds):
        grouped_points: dict[tuple[float, str], list[float]] = defaultdict(list)
        for row in rows:
            if row.get("status") != "STABLE" or round(f(row, "target_tws_kn"), 3) != tws:
                continue
            up, down = vmg_components(row)
            angle = abs(f(row, "target_twa_deg"))
            if angle <= 90 and valid(up):
                grouped_points[(angle, "UP")].append(up)
            if angle >= 90 and valid(down):
                grouped_points[(angle, "DOWN")].append(down)
        for direction, label_prefix in [("UP", "Upwind"), ("DOWN", "Downwind")]:
            pts = [(angle, statistics.fmean(vals)) for (angle, d), vals in sorted(grouped_points.items()) if d == direction]
            all_values.extend(y for _, y in pts)
            series.append((f"{tws:g} kn {label_prefix}", PALETTE[index % len(PALETTE)], pts))
    low = min([0.0] + all_values)
    high = max([1.0] + all_values)
    margin = max(0.25, (high - low) * 0.08)
    line_chart(output, "Nordic 28 · Wind-axis VMG", "VMG is projected from mean world velocity onto the true wind-from (upwind) and wind-to (downwind) axes. Gaps remain where no stable result exists.", "Absolute target TWA (degrees)", "VMG (kn)", series, 0, 180, low - margin, high + margin, expected_x_step=expected_step)


def chart_symmetry(rows: list[dict[str, Any]], output: Path) -> None:
    speeds = sorted({round(f(r, "target_tws_kn"), 3) for r in rows})
    angles = sorted({round(abs(f(r, "target_twa_deg")), 3) for r in rows})
    angle_steps = [b - a for a, b in zip(angles, angles[1:]) if b > a]
    expected_step = min(angle_steps) if angle_steps else None
    series = []
    vals = []
    pairs = grouped(rows)
    for index, tws in enumerate(speeds):
        pts = []
        for (case_tws, angle), group in sorted(pairs.items()):
            if case_tws != tws:
                continue
            port = next((r for r in group if r.get("tack") == "PORT" and r.get("status") == "STABLE"), None)
            stbd = next((r for r in group if r.get("tack") == "STARBOARD" and r.get("status") == "STABLE"), None)
            if port and stbd:
                delta = abs(f(port, "mean_sog_kn") - f(stbd, "mean_sog_kn"))
                pts.append((angle, delta))
                vals.append(delta)
        series.append((f"{tws:g} kn", PALETTE[index % len(PALETTE)], pts))
    high = max([0.5] + vals)
    line_chart(output, "Nordic 28 · Tack speed mirror", "Absolute SOG difference for pairs where both tacks are STABLE. Low-speed pairs use absolute kn difference; gaps are not interpolated.", "Absolute TWA (degrees)", "|Port − Starboard| SOG (kn)", series, 0, 180, 0, high * 1.15, expected_x_step=expected_step)


def chart_heel(rows: list[dict[str, Any]], output: Path) -> None:
    speeds = sorted({round(f(r, "target_tws_kn"), 3) for r in rows})
    angles = sorted({round(abs(f(r, "target_twa_deg")), 3) for r in rows})
    angle_steps = [b - a for a, b in zip(angles, angles[1:]) if b > a]
    expected_step = min(angle_steps) if angle_steps else None
    series = []
    vals = []
    for index, tws in enumerate(speeds):
        for tack in ["PORT", "STARBOARD", "SYMMETRIC"]:
            selected = [r for r in rows if round(f(r, "target_tws_kn"), 3) == tws and r.get("tack") == tack and r.get("status") == "STABLE"]
            if not selected:
                continue
            points = [(f(row, "target_twa_deg"), f(row, "mean_heel_deg")) for row in sorted(selected, key=lambda r: f(r, "target_twa_deg"))]
            vals.extend(y for _, y in points if valid(y))
            tack_label = "PORT" if tack == "PORT" else "STARBOARD" if tack == "STARBOARD" else "boundary"
            series.append((f"{tws:g} kn {tack_label}", PALETTE[index % len(PALETTE)], points))
    extent = max([5.0] + [abs(x) for x in vals]) * 1.15
    line_chart(output, "Nordic 28 · Heel", "Signed heel angle from the physical snapshot; signed TWA keeps Port and Starboard separate. Gaps remain where no stable result exists.", "Signed target TWA (degrees)", "Mean heel (degrees)", series, -180, 180, -extent, extent, expected_x_step=expected_step)


def chart_status(rows: list[dict[str, Any]], output: Path) -> None:
    width, height = 900, 480
    parts = svg_header(width, height, "Nordic 28 · Polar case status", "Each bar is a TWS; each segment is a recorded status. Missing cases are listed separately in the summary.")
    tws_values = sorted({round(f(row, "target_tws_kn"), 3) for row in rows})
    left, top, plot_w, plot_h = 80.0, 90.0, 740.0, 290.0
    max_count = max([1] + [sum(round(f(row, "target_tws_kn"), 3) == tws for row in rows) for tws in tws_values])
    bar_w = min(75.0, plot_w / max(len(tws_values), 1) * 0.6)
    for i, tws in enumerate(tws_values):
        x = left + (i + 0.5) * plot_w / len(tws_values) - bar_w / 2
        count_by_status = Counter(str(row.get("status", "INVALID")) for row in rows if round(f(row, "target_tws_kn"), 3) == tws)
        y_bottom = top + plot_h
        total = sum(count_by_status.values())
        for status in STATUSES:
            count = count_by_status.get(status, 0)
            if count <= 0:
                continue
            segment_h = plot_h * count / max_count
            y_bottom -= segment_h
            parts.append(f'<rect x="{x:.1f}" y="{y_bottom:.1f}" width="{bar_w:.1f}" height="{segment_h:.1f}" fill="{STATUS_COLORS[status]}"/>')
            if segment_h >= 18:
                parts.append(svg_text(x + bar_w / 2, y_bottom + segment_h / 2 + 4, str(count), 10, "#ffffff"))
        parts.append(svg_text(x + bar_w / 2, top + plot_h + 22, f"{tws:g} kn", 11, "#354b5b"))
        parts.append(svg_text(x + bar_w / 2, y_bottom - 7, f"n={total}", 10, "#566978"))
    legend_x, legend_y = 90.0, 420.0
    for index, status in enumerate(STATUSES):
        x = legend_x + (index % 4) * 190
        y = legend_y + (index // 4) * 24
        parts.append(f'<rect x="{x:.1f}" y="{y-10:.1f}" width="12" height="12" fill="{STATUS_COLORS[status]}"/>')
        parts.append(svg_text(x + 18, y + 1, status, 10, "#3a4c5b", "start"))
    parts.append('</svg>')
    output.write_text("\n".join(parts), encoding="utf-8")


def p3_payload(data: dict[str, Any], rows: list[dict[str, Any]], analysis: dict[str, Any], gate: dict[str, Any]) -> dict[str, Any]:
    metadata = data.get("metadata", {})
    tws = sorted({round(f(row, "target_tws_kn"), 3) for row in rows})
    angles = sorted({round(abs(f(row, "target_twa_deg")), 3) for row in rows})
    enriched = []
    for row in rows:
        upwind, downwind = vmg_components(row)
        enriched.append({
            "case_id": row.get("case_id"), "tws_kn": f(row, "target_tws_kn"),
            "target_twa_deg_signed": f(row, "target_twa_deg"), "twa_deg_absolute": abs(f(row, "target_twa_deg")),
            "tack": row.get("tack"), "status": row.get("status"), "failure_reason": row.get("failure_reason"),
            "sog_kn": f(row, "mean_sog_kn"), "stw_kn": f(row, "mean_stw_kn"),
            "vmg_target_course_kn": f(row, "mean_vmg_kn"),
            "vmg_upwind_kn": upwind if valid(upwind) else None,
            "vmg_downwind_kn": downwind if valid(downwind) else None,
            "mean_velocity_world_mps": {"east_x": f(row, "mean_velocity_world_x_mps"), "south_z": f(row, "mean_velocity_world_z_mps")},
            "mean_heading_deg": f(row, "mean_heading_deg"), "mean_cog_deg": f(row, "mean_cog_deg"),
            "mean_heel_deg": f(row, "mean_heel_deg"), "mean_leeway_deg": f(row, "mean_leeway_deg"),
            "mean_rudder_deg": f(row, "mean_rudder_deg"), "rudder_saturation_fraction": f(row, "rudder_saturation_fraction"),
            "mean_main_sail_deg": f(row, "main_sail_deg"), "mean_jib_deg": f(row, "headsail_deg"),
            "elapsed_simulation_seconds": f(row, "elapsed_simulation_seconds"),
            "stability_first_qualified_simulation_seconds": f(row, "stability_first_qualified_simulation_seconds"),
        })
    return {
        "schema_version": 1,
        "vessel_name": "Nordic 28",
        "boat_scene_path": metadata.get("boat_scene_path", "res://scenes/boats/SailingBoat8m.tscn"),
        "test_date": metadata.get("created_at"),
        "tester_version": "Sailing Polar P2 · 1",
        "godot_version": metadata.get("godot_version"),
        "test_run_id": metadata.get("test_run_id"),
        "configuration_fingerprint": metadata.get("boat_config_hash"),
        "release_eligible": bool(gate.get("passed", False)) and len(rows) == 180,
        "release_quality_gate": gate,
        "units": {"tws": "kn", "twa": "degree", "sog": "kn", "stw": "kn", "vmg": "kn", "heel": "degree", "velocity": "m/s"},
        "wind_from_bearing_deg": f(metadata.get("config", {}), "wind_from_degrees", 180.0),
        "tws_grid_kn": tws,
        "absolute_twa_grid_deg": angles,
        "vmg_sign_convention": "positive upwind VMG is velocity projected toward the true wind-from bearing; positive downwind VMG is velocity projected toward the opposite (wind-to) bearing.",
        "summary_by_tws": analysis.get("by_tws_kn", {}),
        "measurements": enriched,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path, help="P1 polar_results.json in the Godot user:// run directory")
    parser.add_argument("--output-dir", required=True, type=Path, help="New, non-existing output folder; existing data is never overwritten")
    parser.add_argument("--label", choices=["sparse", "full"], required=True)
    parser.add_argument("--expected-count", type=int, required=True)
    args = parser.parse_args()
    if args.output_dir.exists():
        raise SystemExit(f"Refusing to overwrite existing output directory: {args.output_dir}")
    args.output_dir.mkdir(parents=True, exist_ok=False)
    data = read_input(args.input)
    rows = data["results"]
    gate = quality_gate(data)
    if len(data.get("cases", [])) != args.expected_count:
        gate["passed"] = False
        gate["errors"].append(f"expected this phase to contain {args.expected_count} cases, input has {len(data.get('cases', []))}")
    analysis = analyze_rows(rows)
    analysis["anomaly_review_candidates"] = anomalies(rows)
    analysis["quality_gate"] = gate
    analysis["test_run_id"] = data.get("metadata", {}).get("test_run_id")
    analysis["configuration_fingerprint"] = data.get("metadata", {}).get("boat_config_hash")
    analysis["dataset_kind"] = args.label
    prefix = f"polar_{args.label}"
    shutil.copyfile(args.input.with_name("polar_results.csv"), args.output_dir / f"{prefix}_results.csv")
    shutil.copyfile(args.input, args.output_dir / f"{prefix}_results.json")
    shutil.copyfile(args.input.with_name("polar_summary.json"), args.output_dir / f"{prefix}_runner_summary.json")
    write_json(args.output_dir / f"{prefix}_summary.json", analysis)
    write_json(args.output_dir / f"{prefix}_quality.json", gate)
    chart_polar(rows, args.output_dir / f"{prefix}_polar.svg", prefix)
    chart_vmg(rows, args.output_dir / f"{prefix}_vmg.svg")
    chart_symmetry(rows, args.output_dir / f"{prefix}_symmetry.svg")
    chart_heel(rows, args.output_dir / f"{prefix}_heel.svg")
    chart_status(rows, args.output_dir / f"{prefix}_status.svg")
    if args.label == "full":
        payload = p3_payload(data, rows, analysis, gate)
        dataset_path = PROJECT_ROOT / "resources/sailing/nordic28_polar.json"
        if dataset_path.exists():
            raise SystemExit(f"Refusing to overwrite existing P3 dataset: {dataset_path}")
        if payload["release_eligible"]:
            write_json(dataset_path, payload)
            print(f"P3 dataset written: {dataset_path}")
        else:
            print("P3 dataset withheld: full grid or technical quality gate did not pass")
    print(json.dumps({
        "output_dir": str(args.output_dir),
        "run_id": analysis.get("test_run_id"),
        "result_count": len(rows),
        "status_counts": analysis.get("status_counts"),
        "quality_pass": gate.get("passed"),
        "quality_errors": gate.get("errors"),
        "p3_release_eligible": bool(gate.get("passed")) and args.label == "full" and len(rows) == 180,
    }, indent=2))


if __name__ == "__main__":
    main()
