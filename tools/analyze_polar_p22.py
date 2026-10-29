#!/usr/bin/env python3
"""Flatten and visualize the isolated Nordic 28 P2.2 run using only stdlib."""

from __future__ import annotations

import argparse
import csv
import html
import json
import math
import re
from collections import Counter, defaultdict
from pathlib import Path


COLORS = ["#286c9c", "#e19732", "#4d9673", "#bd5b55", "#8064a2", "#7b8790"]
AREAS = [(15.32025, "BASE"), (28.0, "SA28"), (30.0, "SA30"), (32.0, "SA32")]
STATUSES = ["STABLE", "NO_FORWARD_PROGRESS", "HEADING_FAILED", "UNSTABLE", "TIMEOUT", "INVALID", "INTERRUPTED"]


def read_json(path: Path):
    return json.loads(path.read_text())


def write_csv(path: Path, rows: list[dict], fields: list[str] | None = None):
    path.parent.mkdir(parents=True, exist_ok=True)
    if fields is None:
        keys = set()
        for row in rows:
            keys.update(row)
        fields = sorted(keys)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def flatten_results(raw_rows: list[dict]) -> list[dict]:
    rows = []
    for source in raw_rows:
        row = {key: value for key, value in source.items() if key != "extended_telemetry"}
        ext = source.get("extended_telemetry") or {}
        row.update({f"ext_{key}": value for key, value in ext.items()})
        tws = float(row.get("target_tws_kn") or 0.0)
        twa = float(row.get("target_twa_deg") or 0.0)
        wind_from = float(row.get("wind_from_deg") or 180.0)
        vx = float(row.get("mean_velocity_world_x_mps") or 0.0)
        vz = float(row.get("mean_velocity_world_z_mps") or 0.0)
        wind_angle = math.radians(wind_from)
        # Positive VMG means motion toward the true wind source (upwind).
        upwind_mps = vx * math.sin(wind_angle) - vz * math.cos(wind_angle)
        row["wind_axis_upwind_vmg_kn"] = upwind_mps * 1.9438444924406
        row["wind_axis_downwind_vmg_kn"] = -upwind_mps * 1.9438444924406
        row["absolute_target_twa_deg"] = abs(twa)
        row["physical_tws_kn"] = tws
        row["polar_point_valid"] = str(row.get("status")) == "STABLE"
        rows.append(row)
    return rows


def pair_rows(rows: list[dict], predicate):
    return [row for row in rows if predicate(row)]


def get_area_pair(rows: list[dict], area: float, tws: float, twa_abs: float, require_stable=True):
    matches = pair_rows(
        rows,
        lambda row: row.get("experiment_phase") == "area"
        and abs(float(row.get("configured_total_sail_area_m2", 0.0)) - area) < 0.01
        and abs(float(row.get("target_tws_kn", 0.0)) - tws) < 0.01
        and abs(float(row.get("target_twa_deg", 0.0))) == twa_abs,
    )
    by_tack = {str(row.get("tack")): row for row in matches}
    if require_stable and not all(str(by_tack.get(tack, {}).get("status")) == "STABLE" for tack in ("PORT", "STARBOARD")):
        return None
    return by_tack if by_tack else None


def average_pair(pair: dict | None, field: str, absolute=False):
    if not pair or not all(tack in pair for tack in ("PORT", "STARBOARD")):
        return None
    values = []
    for tack in ("PORT", "STARBOARD"):
        value = pair[tack].get(field)
        if value in (None, ""):
            return None
        number = float(value)
        values.append(abs(number) if absolute else number)
    return sum(values) / len(values)


def build_area_comparison(rows: list[dict]) -> list[dict]:
    output = []
    targets = [(8.0, 90), (12.0, 50), (12.0, 70), (12.0, 90), (12.0, 120)]
    for tws, twa in targets:
        for area, label in AREAS:
            pair = get_area_pair(rows, area, tws, twa, require_stable=False)
            if not pair:
                continue
            port = pair.get("PORT", {})
            starboard = pair.get("STARBOARD", {})
            stable_pair = port.get("status") == "STABLE" and starboard.get("status") == "STABLE"
            output.append({
                "area_scheme": label,
                "total_area_m2": area,
                "main_area_m2": float(port.get("configured_main_sail_area_m2", starboard.get("configured_main_sail_area_m2", 0.0)) or 0.0),
                "jib_area_m2": float(port.get("configured_headsail_area_m2", starboard.get("configured_headsail_area_m2", 0.0)) or 0.0),
                "target_tws_kn": tws,
                "absolute_target_twa_deg": twa,
                "port_status": port.get("status", "MISSING"),
                "starboard_status": starboard.get("status", "MISSING"),
                "both_tacks_stable": stable_pair,
                "port_sog_kn": port.get("mean_sog_kn"),
                "starboard_sog_kn": starboard.get("mean_sog_kn"),
                "mean_sog_kn_if_both_stable": average_pair(pair, "mean_sog_kn") if stable_pair else None,
                "delta_vs_base_kn_if_both_stable": None,
                "port_vlong_mps": port.get("mean_longitudinal_velocity_mps"),
                "starboard_vlong_mps": starboard.get("mean_longitudinal_velocity_mps"),
                "port_upwind_vmg_kn": port.get("wind_axis_upwind_vmg_kn"),
                "starboard_upwind_vmg_kn": starboard.get("wind_axis_upwind_vmg_kn"),
                "port_downwind_vmg_kn": port.get("wind_axis_downwind_vmg_kn"),
                "starboard_downwind_vmg_kn": starboard.get("wind_axis_downwind_vmg_kn"),
                "port_heel_deg": port.get("mean_heel_deg"),
                "starboard_heel_deg": starboard.get("mean_heel_deg"),
                "port_leeway_deg": port.get("mean_leeway_deg"),
                "starboard_leeway_deg": starboard.get("mean_leeway_deg"),
                "port_rudder_deg": port.get("mean_rudder_deg"),
                "starboard_rudder_deg": starboard.get("mean_rudder_deg"),
                "port_rudder_saturation_fraction": port.get("rudder_saturation_fraction"),
                "starboard_rudder_saturation_fraction": starboard.get("rudder_saturation_fraction"),
                "port_forward_sail_force_n": (port.get("mean_main_forward_force_n", 0.0) or 0.0) + (port.get("mean_headsail_forward_force_n", 0.0) or 0.0),
                "starboard_forward_sail_force_n": (starboard.get("mean_main_forward_force_n", 0.0) or 0.0) + (starboard.get("mean_headsail_forward_force_n", 0.0) or 0.0),
                "port_lateral_sail_force_starboard_n": (port.get("ext_mean_main_net_lateral_force_starboard_n", 0.0) or 0.0) + (port.get("ext_mean_jib_net_lateral_force_starboard_n", 0.0) or 0.0),
                "starboard_lateral_sail_force_starboard_n": (starboard.get("ext_mean_main_net_lateral_force_starboard_n", 0.0) or 0.0) + (starboard.get("ext_mean_jib_net_lateral_force_starboard_n", 0.0) or 0.0),
            })
    base_lookup = {(r["target_tws_kn"], r["absolute_target_twa_deg"]): r for r in output if r["area_scheme"] == "BASE"}
    for row in output:
        baseline = base_lookup.get((row["target_tws_kn"], row["absolute_target_twa_deg"]))
        if row["both_tacks_stable"] and baseline and baseline["both_tacks_stable"]:
            base_speed = baseline["mean_sog_kn_if_both_stable"]
            row["delta_vs_base_kn_if_both_stable"] = row["mean_sog_kn_if_both_stable"] - base_speed
            row["delta_vs_base_percent_if_both_stable"] = 100.0 * (row["mean_sog_kn_if_both_stable"] / base_speed - 1.0) if base_speed else None
    return output


def build_force_balance_rows(rows: list[dict]) -> list[dict]:
    output = []
    for row in rows:
        if row.get("experiment_phase") != "area":
            continue
        ext = {key.removeprefix("ext_"): value for key, value in row.items() if key.startswith("ext_")}
        torque_parts = [
            ext.get("mean_main_net_torque_local_nm_y"), ext.get("mean_jib_net_torque_local_nm_y"),
            ext.get("mean_keel_net_torque_local_nm_y"), ext.get("mean_rudder_net_torque_local_nm_y"),
            ext.get("mean_axis_damping_yaw_torque_nm"),
        ]
        measured_yaw_sum = ext.get("mean_measured_yaw_torque_sum_nm")
        buoyancy_yaw = None
        if measured_yaw_sum not in (None, "") and all(value not in (None, "") for value in torque_parts):
            buoyancy_yaw = float(measured_yaw_sum) - sum(float(value) for value in torque_parts)
        output.append({
            "area_scheme": row.get("experiment_group"),
            "total_area_m2": row.get("configured_total_sail_area_m2"),
            "main_area_m2": row.get("configured_main_sail_area_m2"),
            "jib_area_m2": row.get("configured_headsail_area_m2"),
            "target_tws_kn": row.get("target_tws_kn"),
            "target_twa_deg": row.get("target_twa_deg"),
            "measured_twa_deg": ext.get("mean_measured_twa_deg"),
            "tack": row.get("tack"), "status": row.get("status"),
            "sog_kn": row.get("mean_sog_kn"),
            "body_forward_speed_kn": float(row.get("mean_longitudinal_velocity_mps") or 0.0) * 1.9438444924406,
            "body_lateral_speed_mps": ext.get("mean_body_lateral_speed_mps"),
            "wind_axis_upwind_vmg_kn": row.get("wind_axis_upwind_vmg_kn"),
            "wind_axis_downwind_vmg_kn": row.get("wind_axis_downwind_vmg_kn"),
            "leeway_deg": row.get("mean_leeway_deg"), "heel_deg": row.get("mean_heel_deg"),
            "main_angle_deg": ext.get("mean_main_actual_angle_deg"), "main_target_angle_deg": ext.get("mean_main_target_angle_deg"),
            "jib_angle_deg": ext.get("mean_jib_actual_angle_deg"), "jib_target_angle_deg": ext.get("mean_jib_target_angle_deg"),
            "rudder_deg": row.get("mean_rudder_deg"), "rudder_target_deg": ext.get("mean_rudder_target_angle_deg"),
            "rudder_saturation_fraction": row.get("rudder_saturation_fraction"),
            "main_forward_force_n": ext.get("mean_main_net_forward_force_n"),
            "jib_forward_force_n": ext.get("mean_jib_net_forward_force_n"),
            "hull_forward_resistance_n": row.get("mean_hull_resistance_forward_n"),
            "keel_forward_force_n": row.get("mean_keel_force_forward_n"),
            "rudder_forward_force_n": row.get("mean_rudder_force_forward_n"),
            "main_lateral_force_starboard_n": ext.get("mean_main_net_lateral_force_starboard_n"),
            "jib_lateral_force_starboard_n": ext.get("mean_jib_net_lateral_force_starboard_n"),
            "hull_lateral_force_starboard_n": ext.get("mean_hull_lateral_resistance_starboard_n"),
            "keel_lateral_force_starboard_n": ext.get("mean_keel_net_lateral_force_starboard_n"),
            "rudder_lateral_force_starboard_n": ext.get("mean_rudder_net_lateral_force_starboard_n"),
            "main_aoa_deg": ext.get("mean_main_aoa_deg"), "main_cl": ext.get("mean_main_cl"), "main_cd": ext.get("mean_main_cd"),
            "jib_aoa_deg": ext.get("mean_jib_aoa_deg"), "jib_cl": ext.get("mean_jib_cl"), "jib_cd": ext.get("mean_jib_cd"),
            "keel_aoa_deg": ext.get("mean_keel_aoa_deg"), "keel_cl": ext.get("mean_keel_cl"), "keel_cd": ext.get("mean_keel_cd"),
            "rudder_aoa_deg": ext.get("mean_rudder_aoa_deg"), "rudder_cl": ext.get("mean_rudder_cl"), "rudder_cd": ext.get("mean_rudder_cd"),
            "main_yaw_torque_nm": ext.get("mean_main_net_torque_local_nm_y"),
            "jib_yaw_torque_nm": ext.get("mean_jib_net_torque_local_nm_y"),
            "keel_yaw_torque_nm": ext.get("mean_keel_net_torque_local_nm_y"),
            "rudder_yaw_torque_nm": ext.get("mean_rudder_net_torque_local_nm_y"),
            "explicit_damping_yaw_torque_nm": ext.get("mean_axis_damping_yaw_torque_nm"),
            "buoyancy_yaw_torque_nm_reconstructed_from_partial_sum": buoyancy_yaw,
            "measured_yaw_torque_partial_sum_nm": measured_yaw_sum,
            "main_pc_x_m": ext.get("mean_main_pressure_center_local_m_x"),
            "main_pc_y_m": ext.get("mean_main_pressure_center_local_m_y"),
            "main_pc_z_m": ext.get("mean_main_pressure_center_local_m_z"),
            "jib_pc_x_m": ext.get("mean_jib_pressure_center_local_m_x"),
            "jib_pc_y_m": ext.get("mean_jib_pressure_center_local_m_y"),
            "jib_pc_z_m": ext.get("mean_jib_pressure_center_local_m_z"),
            "keel_application_z_m": ext.get("mean_keel_application_local_m_z"),
            "rudder_application_z_m": ext.get("mean_rudder_application_local_m_z"),
            "com_x_m": ext.get("mean_com_local_x_m"), "com_y_m": ext.get("mean_com_local_y_m"), "com_z_m": ext.get("mean_com_local_z_m"),
            "telemetry_finite": ext.get("telemetry_finite"),
        })
    return output


def build_trim_rows(rows: list[dict]) -> list[dict]:
    auto_reference = {}
    for reference in rows:
        if reference.get("experiment_phase") != "area" or reference.get("experiment_group") != "BASE":
            continue
        key = (str(reference.get("tack")), round(float(reference.get("target_tws_kn", 0.0)), 3), round(float(reference.get("target_twa_deg", 0.0)), 3))
        ext_reference = reference.get("ext_mean_main_target_angle_deg"), reference.get("ext_mean_jib_target_angle_deg")
        auto_reference[key] = ext_reference
    output = []
    for row in rows:
        if row.get("experiment_phase") != "trim":
            continue
        ext = {key.removeprefix("ext_"): value for key, value in row.items() if key.startswith("ext_")}
        # Godot's String % formatter does not support the %+g specifier used by
        # the runner for display metadata. Preserve the raw text as evidence,
        # but recover the scan variable from the stable case_id and numeric
        # requested angles so the analysis remains traceable.
        match = re.fullmatch(r"trim_(main|jib)_([+-]?\d+)_([a-z]+)_(\d+)", str(row.get("case_id", "")))
        sail = match.group(1) if match else "unknown"
        offset = float(match.group(2)) if match else None
        reference_key = (str(row.get("tack")), round(float(row.get("target_tws_kn", 0.0)), 3), round(float(row.get("target_twa_deg", 0.0)), 3))
        reference_pair = auto_reference.get(reference_key, (None, None))
        scanned_reference = reference_pair[0] if sail == "main" else reference_pair[1]
        requested_scanned = row.get("requested_main_trim_magnitude_deg" if sail == "main" else "requested_headsail_trim_magnitude_deg")
        requested_offset = None
        if scanned_reference not in (None, "") and requested_scanned not in (None, ""):
            requested_offset = float(requested_scanned) - abs(float(scanned_reference))
        actual_scanned = ext.get("mean_main_actual_angle_deg" if sail == "main" else "mean_jib_actual_angle_deg")
        request_shortfall = None
        if requested_scanned not in (None, "") and actual_scanned not in (None, ""):
            request_shortfall = max(0.0, abs(float(requested_scanned)) - abs(float(actual_scanned)))
        output.append({
            "case_id": row.get("case_id"),
            "test_run_id": row.get("test_run_id"),
            "config_hash": row.get("boat_config_hash"),
            "target_tws_kn": row.get("target_tws_kn"),
            "target_twa_deg": row.get("target_twa_deg"),
            "tack": row.get("tack"),
            "status": row.get("status"),
            "trim_variable": f"{sail}_{offset:+g}_deg" if offset is not None else row.get("experiment_variable"),
            "trim_sail": sail,
            "trim_offset_deg_from_case_id": offset,
            "trim_offset_deg_from_requested_vs_auto_reference": requested_offset,
            "trim_offset_metadata_matches": None if offset is None or requested_offset is None else abs(offset - requested_offset) < 0.1,
            "raw_trim_variable_metadata": row.get("experiment_variable"),
            "requested_main_magnitude_deg": row.get("requested_main_trim_magnitude_deg"),
            "requested_jib_magnitude_deg": row.get("requested_headsail_trim_magnitude_deg"),
            "requested_minus_actual_magnitude_deg": request_shortfall,
            "actual_main_angle_deg": ext.get("mean_main_actual_angle_deg"),
            "actual_jib_angle_deg": ext.get("mean_jib_actual_angle_deg"),
            "actual_twa_deg": ext.get("mean_measured_twa_deg"),
            "sog_kn": row.get("mean_sog_kn"),
            "wind_axis_upwind_vmg_kn": row.get("wind_axis_upwind_vmg_kn"),
            "wind_axis_downwind_vmg_kn": row.get("wind_axis_downwind_vmg_kn"),
            "heel_deg": row.get("mean_heel_deg"),
            "leeway_deg": row.get("mean_leeway_deg"),
            "rudder_deg": row.get("mean_rudder_deg"),
            "rudder_saturation_fraction": row.get("rudder_saturation_fraction"),
            "main_aoa_deg": ext.get("mean_main_aoa_deg"), "main_cl": ext.get("mean_main_cl"), "main_cd": ext.get("mean_main_cd"),
            "jib_aoa_deg": ext.get("mean_jib_aoa_deg"), "jib_cl": ext.get("mean_jib_cl"), "jib_cd": ext.get("mean_jib_cd"),
            "main_forward_force_n": ext.get("mean_main_net_forward_force_n"),
            "jib_forward_force_n": ext.get("mean_jib_net_forward_force_n"),
            "twa_heading_error_deg": row.get("heading_error_deg"),
        })
    return output


def build_yaw_rows(rows: list[dict]) -> list[dict]:
    output = []
    for row in rows:
        area = float(row.get("configured_total_sail_area_m2", 0.0) or 0.0)
        if row.get("experiment_phase") != "area" or area not in (15.32025, 30.0):
            continue
        if abs(float(row.get("target_tws_kn", 0.0)) - 12.0) > 0.01 or abs(float(row.get("target_twa_deg", 0.0))) not in (50.0, 70.0):
            continue
        ext = {key.removeprefix("ext_"): value for key, value in row.items() if key.startswith("ext_")}
        output.append({
            "area_scheme": "BASE" if area < 20 else "SA30",
            "total_area_m2": area,
            "target_tws_kn": row.get("target_tws_kn"),
            "target_twa_deg": row.get("target_twa_deg"),
            "tack": row.get("tack"), "status": row.get("status"),
            "actual_twa_deg": ext.get("mean_measured_twa_deg"),
            "sog_kn": row.get("mean_sog_kn"), "leeway_deg": row.get("mean_leeway_deg"),
            "rudder_angle_deg": row.get("mean_rudder_deg"),
            "rudder_saturation_fraction": row.get("rudder_saturation_fraction"),
            "main_yaw_torque_nm": ext.get("mean_main_net_torque_local_nm_y"),
            "jib_yaw_torque_nm": ext.get("mean_jib_net_torque_local_nm_y"),
            "keel_yaw_torque_nm": ext.get("mean_keel_net_torque_local_nm_y"),
            "rudder_yaw_torque_nm": ext.get("mean_rudder_net_torque_local_nm_y"),
            "explicit_damping_yaw_torque_nm": ext.get("mean_axis_damping_yaw_torque_nm"),
            "measured_yaw_torque_sum_nm": ext.get("mean_measured_yaw_torque_sum_nm"),
            "main_x_arm_m": ext.get("mean_main_net_arm_from_com_local_m_x"),
            "main_z_arm_m": ext.get("mean_main_net_arm_from_com_local_m_z"),
            "jib_x_arm_m": ext.get("mean_jib_net_arm_from_com_local_m_x"),
            "jib_z_arm_m": ext.get("mean_jib_net_arm_from_com_local_m_z"),
            "rudder_aoa_deg": ext.get("mean_rudder_aoa_deg"),
            "keel_aoa_deg": ext.get("mean_keel_aoa_deg"),
        })
    return output


def write_bar_chart(path: Path, title: str, categories: list[str], series: list[tuple[str, list[float | None]]], ylabel: str):
    width, height = 1160, 640
    left, right, top, bottom = 95, 30, 80, 155
    plot_w, plot_h = width - left - right, height - top - bottom
    vals = [v for _, arr in series for v in arr if v is not None and math.isfinite(v)]
    if not vals:
        vals = [0.0, 1.0]
    ymin, ymax = min(0.0, min(vals)), max(0.0, max(vals))
    span = max(ymax - ymin, 1.0)
    ymin -= span * 0.12
    ymax += span * 0.12
    zero_y = top + (ymax / (ymax - ymin)) * plot_h
    count = max(1, len(categories))
    group_w = plot_w / count
    n_series = max(1, len(series))
    bar_w = min(64.0, group_w * 0.72 / n_series)
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
           '<rect width="100%" height="100%" fill="#ffffff"/>',
           f'<text x="{width/2:.1f}" y="38" text-anchor="middle" font-family="Arial,sans-serif" font-size="24" font-weight="bold">{html.escape(title)}</text>',
           f'<text transform="translate(26 {top+plot_h/2:.1f}) rotate(-90)" text-anchor="middle" font-family="Arial,sans-serif" font-size="15">{html.escape(ylabel)}</text>']
    for index in range(6):
        value = ymin + (ymax - ymin) * index / 5
        y = top + plot_h - plot_h * index / 5
        svg.append(f'<line x1="{left}" y1="{y:.1f}" x2="{width-right}" y2="{y:.1f}" stroke="#e3e7eb"/>')
        svg.append(f'<text x="{left-10}" y="{y+5:.1f}" text-anchor="end" font-family="Arial,sans-serif" font-size="12" fill="#46515c">{value:.2f}</text>')
    svg.append(f'<line x1="{left}" y1="{zero_y:.1f}" x2="{width-right}" y2="{zero_y:.1f}" stroke="#4b5560" stroke-width="1.4"/>')
    for ci, category in enumerate(categories):
        gx = left + group_w * (ci + 0.5)
        for si, (label, values) in enumerate(series):
            if ci >= len(values) or values[ci] is None or not math.isfinite(values[ci]):
                continue
            value = values[ci]
            x = gx + (si - (n_series - 1) / 2) * bar_w - bar_w / 2
            vy = top + plot_h - (value - ymin) / (ymax - ymin) * plot_h
            rect_y, rect_h = min(vy, zero_y), max(1.0, abs(zero_y - vy))
            color = COLORS[si % len(COLORS)]
            svg.append(f'<rect x="{x:.1f}" y="{rect_y:.1f}" width="{bar_w*0.88:.1f}" height="{rect_h:.1f}" fill="{color}" rx="2"/>')
            svg.append(f'<text x="{x+bar_w*0.44:.1f}" y="{(vy-5 if value >= 0 else vy+15):.1f}" text-anchor="middle" font-family="Arial,sans-serif" font-size="10" fill="#26313a">{value:.2f}</text>')
        svg.append(f'<text x="{gx:.1f}" y="{top+plot_h+28}" text-anchor="middle" font-family="Arial,sans-serif" font-size="12" fill="#26313a">{html.escape(category)}</text>')
    legend_y = height - 55
    legend_total_w = sum(max(80, len(label) * 8 + 30) for label, _ in series)
    legend_x = max(left, (width - legend_total_w) / 2)
    for si, (label, _) in enumerate(series):
        x = legend_x
        color = COLORS[si % len(COLORS)]
        svg.append(f'<rect x="{x:.1f}" y="{legend_y}" width="14" height="14" fill="{color}"/>')
        svg.append(f'<text x="{x+20:.1f}" y="{legend_y+12}" font-family="Arial,sans-serif" font-size="12">{html.escape(label)}</text>')
        legend_x += max(80, len(label) * 8 + 30)
    svg.append('</svg>')
    path.write_text('\n'.join(svg), encoding='utf-8')


def create_charts(analysis_dir: Path, area_rows: list[dict], trim_rows: list[dict], yaw_rows: list[dict], all_rows: list[dict]):
    area_labels = [label for _, label in AREAS]
    speed_targets = [(8.0, 90), (12.0, 90), (12.0, 120)]
    speed_series = []
    for area, label in AREAS:
        vals = []
        for tws, twa in speed_targets:
            row = next((r for r in area_rows if r["area_scheme"] == label and r["target_tws_kn"] == tws and r["absolute_target_twa_deg"] == twa), None)
            vals.append(row.get("mean_sog_kn_if_both_stable") if row and row.get("both_tacks_stable") else None)
        speed_series.append((label, vals))
    write_bar_chart(analysis_dir / "area_speed_comparison.svg", "P2.2 · Sail-area sensitivity (stable mirror pairs only)", ["8 kn · 90°", "12 kn · 90°", "12 kn · 120°"], speed_series, "Mean SOG (kn)")

    for metric, filename, title, absolute in [
        ("mean_heel_deg", "area_heel_comparison.svg", "P2.2 · Heel by sail area · 12 kn", True),
        ("mean_rudder_deg", "area_rudder_comparison.svg", "P2.2 · Rudder angle magnitude · 12 kn", True),
    ]:
        categories = ["70°", "90°", "120°"]
        series = []
        for area, label in AREAS:
            vals = []
            for twa in (70, 90, 120):
                pair = get_area_pair(all_rows, area, 12.0, twa, require_stable=True)
                vals.append(average_pair(pair, metric, absolute))
            series.append((label, vals))
        write_bar_chart(analysis_dir / filename, title, categories, series, "|Heel| (deg)" if metric == "mean_heel_deg" else "|Rudder| (deg)")

    yaw_categories = []
    yaw_series_map = {name: [] for name in ["Main sail", "Jib", "Keel", "Rudder", "Explicit yaw damping"]}
    selected = [r for r in yaw_rows if str(r.get("tack")) == "PORT"]
    selected.sort(key=lambda r: (r["area_scheme"], abs(float(r["target_twa_deg"]))))
    for row in selected:
        yaw_categories.append(f"{row['area_scheme']} · {abs(float(row['target_twa_deg'])):.0f}°")
        for name, field in [("Main sail", "main_yaw_torque_nm"), ("Jib", "jib_yaw_torque_nm"), ("Keel", "keel_yaw_torque_nm"), ("Rudder", "rudder_yaw_torque_nm"), ("Explicit yaw damping", "explicit_damping_yaw_torque_nm")]:
            value = row.get(field)
            yaw_series_map[name].append(float(value) if value not in (None, "") else None)
    write_bar_chart(analysis_dir / "yaw_moment_decomposition.svg", "P2.2 · Signed yaw moments · Port tack · 12 kn", yaw_categories, list(yaw_series_map.items()), "Local +Y yaw torque (N·m)")

    for sail, field in [("Main sail", "actual_main_angle_deg"), ("Jib", "actual_jib_angle_deg")]:
        categories = ["−10°", "−5°", "+5°", "+10°"]
        series = []
        for twa in (70, 90, 120):
            values = []
            for offset in (-10, -5, 5, 10):
                variants = [r for r in trim_rows if abs(float(r.get("target_twa_deg", 0.0))) == twa and r.get("tack") == "PORT" and str(r.get("trim_variable", "")) == f"{sail.split()[0].lower()}_{offset:+g}_deg" and r.get("status") == "STABLE"]
                if not variants:
                    values.append(None)
                else:
                    values.append(sum(float(r.get("sog_kn", 0.0)) for r in variants) / len(variants))
            series.append((f"TWA {twa}°", values))
        write_bar_chart(analysis_dir / f"trim_sensitivity_{sail.split()[0].lower()}_sog.svg", f"P2.2 · {sail} trim sensitivity · SOG", categories, series, "SOG (kn)")

    status_series = []
    for status in STATUSES:
        vals = []
        for _, label in AREAS:
            vals.append(sum(1 for r in all_rows if r.get("experiment_phase") == "area" and r.get("experiment_group") == label and r.get("status") == status))
        status_series.append((status, vals))
    write_bar_chart(analysis_dir / "area_status_distribution.svg", "P2.2 · Status counts by sail-area configuration", area_labels, status_series, "Case count")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-root", required=True, type=Path)
    args = parser.parse_args()
    run_root = args.run_root.resolve()
    raw = read_json(run_root / "raw_results.json")
    rows = flatten_results(raw.get("results", []))
    analysis = run_root / "analysis"
    analysis.mkdir(parents=True, exist_ok=True)
    write_csv(analysis / "p22_results.csv", rows)
    area_rows = build_area_comparison(rows)
    force_rows = build_force_balance_rows(rows)
    trim_rows = build_trim_rows(rows)
    yaw_rows = build_yaw_rows(rows)
    write_csv(analysis / "area_comparison.csv", area_rows)
    write_csv(analysis / "force_balance.csv", force_rows)
    write_csv(analysis / "trim_sensitivity.csv", trim_rows)
    write_csv(analysis / "yaw_moment_diagnostics.csv", yaw_rows)
    status_counts = Counter(str(r.get("status", "INVALID")) for r in rows if r.get("experiment_phase") == "area")
    status_rows = [{"area_scheme": label, "status": status, "count": sum(1 for r in rows if r.get("experiment_phase") == "area" and r.get("experiment_group") == label and r.get("status") == status)} for _, label in AREAS for status in STATUSES]
    write_csv(analysis / "status_counts.csv", status_rows)

    p2_path = Path("docs/sailing/polar_p2/full/polar_2026-10-28_14-04-00_856682/polar_full_results.csv")
    p2_rows = list(csv.DictReader(p2_path.open(encoding="utf-8")))
    p2_map = {(round(float(r["target_tws_kn"]), 3), round(float(r["target_twa_deg"]), 3), r["tack"]): r for r in p2_rows}
    baseline_rows = []
    for row in rows:
        if row.get("experiment_phase") != "area" or row.get("experiment_group") != "BASE":
            continue
        key = (round(float(row["target_tws_kn"]), 3), round(float(row["target_twa_deg"]), 3), str(row.get("tack")))
        old = p2_map.get(key)
        if old:
            baseline_rows.append({
                "target_tws_kn": key[0], "target_twa_deg": key[1], "tack": key[2],
                "p2_status": old["status"], "p22_status": row["status"],
                "p2_sog_kn": float(old["mean_sog_kn"]), "p22_sog_kn": float(row["mean_sog_kn"]),
                "sog_delta_kn": float(row["mean_sog_kn"]) - float(old["mean_sog_kn"]),
                "p2_main_force_forward_n": float(old["mean_main_forward_force_n"]),
                "p22_main_force_forward_n": row.get("mean_main_forward_force_n"),
                "p2_jib_force_forward_n": float(old["mean_headsail_forward_force_n"]),
                "p22_jib_force_forward_n": row.get("mean_headsail_forward_force_n"),
                "p2_mean_rudder_deg": float(old["mean_rudder_deg"]), "p22_mean_rudder_deg": row.get("mean_rudder_deg"),
            })
    write_csv(analysis / "p2_baseline_comparison.csv", baseline_rows)

    smoke = [r for r in rows if r.get("experiment_phase") == "smoke" and r.get("target_tws_kn") == 12 and abs(float(r.get("target_twa_deg", 0.0))) == 90 and r.get("configured_total_sail_area_m2") == 15.32025]
    smoke_off = next((r for r in smoke if r.get("experiment_variable") == "telemetry_off"), None)
    smoke_on = next((r for r in smoke if r.get("experiment_variable") == "telemetry_on"), None)
    mirror_rows = []
    for area, label in AREAS:
        for tws, twa in [(8.0, 70), (8.0, 90), (8.0, 120), (12.0, 50), (12.0, 70), (12.0, 90), (12.0, 120)]:
            pair = get_area_pair(rows, area, tws, twa, require_stable=False)
            if not pair or not all(tack in pair for tack in ("PORT", "STARBOARD")):
                continue
            p, s = pair["PORT"], pair["STARBOARD"]
            mirror_rows.append({
                "area_scheme": label, "target_tws_kn": tws, "abs_target_twa_deg": twa,
                "port_status": p.get("status"), "starboard_status": s.get("status"),
                "status_match": p.get("status") == s.get("status"),
                "sog_abs_difference_kn": abs(float(p.get("mean_sog_kn", 0.0)) - float(s.get("mean_sog_kn", 0.0))),
                "heel_signed_sum_deg": float(p.get("mean_heel_deg", 0.0)) + float(s.get("mean_heel_deg", 0.0)),
                "leeway_signed_sum_deg": float(p.get("mean_leeway_deg") or 0.0) + float(s.get("mean_leeway_deg") or 0.0),
                "yaw_torque_signed_sum_nm": float(p.get("ext_mean_measured_yaw_torque_sum_nm") or 0.0) + float(s.get("ext_mean_measured_yaw_torque_sum_nm") or 0.0),
            })
    write_csv(analysis / "mirror_comparison.csv", mirror_rows)
    create_charts(analysis, area_rows, trim_rows, yaw_rows, rows)

    summary = {
        "run_root": str(run_root),
        "row_count": len(rows),
        "phase_counts": dict(Counter(str(r.get("experiment_phase", "")) for r in rows)),
        "area_status_counts": dict(status_counts),
        "trim_status_counts": dict(Counter(str(r.get("status", "INVALID")) for r in trim_rows)),
        "smoke_telemetry_off": {"status": smoke_off.get("status"), "sog_kn": smoke_off.get("mean_sog_kn")} if smoke_off else None,
        "smoke_telemetry_on": {"status": smoke_on.get("status"), "sog_kn": smoke_on.get("mean_sog_kn"), "finite": smoke_on.get("ext_telemetry_finite"), "wind_query_count": smoke_on.get("ext_mean_wind_query_count_per_tick"), "wave_query_count": smoke_on.get("ext_mean_wave_query_count_per_tick")} if smoke_on else None,
        "area_comparison_rows": area_rows,
        "mirror_row_count": len(mirror_rows),
        "mirror_max_sog_difference_kn": max((r["sog_abs_difference_kn"] for r in mirror_rows), default=None),
        "artifacts": sorted(p.name for p in analysis.glob("*.svg")),
    }
    (analysis / "p22_summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({k: summary[k] for k in ["row_count", "phase_counts", "area_status_counts", "trim_status_counts", "mirror_max_sog_difference_kn"]}, indent=2, ensure_ascii=False))
    print(f"Analysis output: {analysis}")


if __name__ == "__main__":
    main()
