#!/usr/bin/env python3
"""Conservative music/SFX conversion helper for Godot projects.

Scans one directory level, never removes source files, and trims only verified
digital silence. SFX mode is restricted to the catalogued assets in AUDIO-SFX-1
so modern-engine MM files cannot be processed accidentally.
"""

from __future__ import annotations

import argparse
import array
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable


SUPPORTED_EXTENSIONS = {".aac", ".flac", ".m4a", ".mp3", ".ogg", ".wav"}
SFX_LOOP_STEMS = {"OM02", "R02", "R03", "S01", "S02", "SW01", "SW02", "SW03", "W01", "W02"}
SFX_ONESHOT_STEMS = {"T01", "T02", "T03"}
DEFAULT_THRESHOLD_DB = -50.0
DEFAULT_MIN_SILENCE_SECONDS = 0.3
DEFAULT_SAFETY_MARGIN_SECONDS = 0.15
DEFAULT_TRUE_SILENCE_PEAK_DBFS = -80.0
EDGE_ANALYSIS_SECONDS = 3.0
RMS_WINDOW_SECONDS = 0.1


@dataclass
class SilenceSpan:
    start: float
    end: float

    @property
    def duration(self) -> float:
        return max(0.0, self.end - self.start)


@dataclass
class FileAnalysis:
    source: Path
    duration: float
    sample_rate: int
    channels: int
    channel_layout: str
    codec: str
    stream_bitrate: int
    format_bitrate: int
    source_size: int
    silence_spans: list[SilenceSpan] = field(default_factory=list)
    trim_start: float = 0.0
    trim_end: float = 0.0
    fade_in: bool = False
    fade_out: bool = False
    questionable_spans: list[str] = field(default_factory=list)
    decode_notes: list[str] = field(default_factory=list)
    head_rms_dbfs: float | None = None
    tail_rms_dbfs: float | None = None
    loop_step_dbfs: float | None = None
    source_mean_dbfs: float | None = None
    source_peak_dbfs: float | None = None
    output_duration: float | None = None
    output_size: int | None = None
    output_mean_dbfs: float | None = None
    output_peak_dbfs: float | None = None
    loop_variant_duration: float | None = None
    loop_variant_size: int | None = None
    loop_variant_candidate: bool = False
    loop_advice: str = "人工试听后判断"
    skipped_existing: bool = False


def _run(args: list[str], *, check: bool = True) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(args, capture_output=True, check=check)


def _decode_check(ffmpeg: str, path: Path) -> list[str]:
    result = _run(
        [
            ffmpeg,
            "-hide_banner",
            "-nostats",
            "-v",
            "warning",
            "-xerror",
            "-i",
            str(path),
            "-map",
            "0:a:0",
            "-f",
            "null",
            "-",
        ],
        check=False,
    )
    stderr = result.stderr.decode("utf-8", errors="replace").strip()
    if result.returncode != 0:
        raise RuntimeError(f"FFmpeg decode failed for {path}:\n{stderr}")
    return [line.strip() for line in stderr.splitlines() if line.strip()]


def _probe(ffprobe: str, path: Path) -> dict[str, Any]:
    result = _run(
        [
            ffprobe,
            "-v",
            "error",
            "-show_entries",
            "format=duration,size,bit_rate:stream=codec_name,sample_rate,channels,channel_layout,bit_rate,duration",
            "-select_streams",
            "a:0",
            "-of",
            "json",
            str(path),
        ]
    )
    data = json.loads(result.stdout.decode("utf-8"))
    streams = data.get("streams", [])
    if not streams:
        raise RuntimeError(f"No audio stream found in {path}")
    stream = streams[0]
    fmt = data.get("format", {})
    duration_value = fmt.get("duration", stream.get("duration"))
    if duration_value is None:
        raise RuntimeError(f"Duration is unavailable for {path}")
    return {
        "duration": float(duration_value),
        "size": int(fmt.get("size", path.stat().st_size)),
        "format_bitrate": int(fmt.get("bit_rate", 0) or 0),
        "codec": str(stream.get("codec_name", "unknown")),
        "sample_rate": int(stream.get("sample_rate", 0)),
        "channels": int(stream.get("channels", 0)),
        "channel_layout": str(stream.get("channel_layout", "unknown")),
        "stream_bitrate": int(stream.get("bit_rate", 0) or 0),
    }


def _parse_silences(log: str, duration: float) -> list[SilenceSpan]:
    pattern = re.compile(r"silence_(start|end):\s*([0-9]+(?:\.[0-9]+)?)")
    open_start: float | None = None
    spans: list[SilenceSpan] = []
    for kind, raw_time in pattern.findall(log):
        timestamp = float(raw_time)
        if kind == "start":
            open_start = timestamp
        elif open_start is not None:
            spans.append(SilenceSpan(open_start, timestamp))
            open_start = None
    if open_start is not None:
        spans.append(SilenceSpan(open_start, duration))
    return spans


def _detect_silences(
    ffmpeg: str,
    path: Path,
    threshold_db: float,
    min_seconds: float,
    duration: float,
) -> list[SilenceSpan]:
    result = _run(
        [
            ffmpeg,
            "-hide_banner",
            "-nostats",
            "-loglevel",
            "info",
            "-i",
            str(path),
            "-map",
            "0:a:0",
            "-af",
            f"silencedetect=noise={threshold_db:g}dB:d={min_seconds:g}",
            "-f",
            "null",
            "-",
        ],
        check=False,
    )
    if result.returncode != 0:
        stderr = result.stderr.decode("utf-8", errors="replace")
        raise RuntimeError(f"FFmpeg silence analysis failed for {path}:\n{stderr}")
    return _parse_silences(result.stderr.decode("utf-8", errors="replace"), duration)


def _decode_slice(
    ffmpeg: str,
    path: Path,
    start: float,
    duration: float,
    sample_rate: int,
    channels: int,
) -> array.array[float]:
    filter_text = f"atrim=start={max(0.0, start):.9f}:duration={max(0.0, duration):.9f},asetpts=PTS-STARTPTS"
    result = _run(
        [
            ffmpeg,
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(path),
            "-map",
            "0:a:0",
            "-af",
            filter_text,
            "-acodec",
            "pcm_f32le",
            "-ar",
            str(sample_rate),
            "-ac",
            str(channels),
            "-f",
            "f32le",
            "pipe:1",
        ]
    )
    samples = array.array("f")
    samples.frombytes(result.stdout)
    if sys.byteorder != "little":
        samples.byteswap()
    return samples


def _dbfs(amplitude: float) -> float:
    if amplitude <= 0.0:
        return float("-inf")
    return 20.0 * math.log10(amplitude)


def _window_levels(samples: array.array[float], sample_rate: int, channels: int) -> list[float]:
    frames = len(samples) // channels
    window_frames = max(1, int(sample_rate * RMS_WINDOW_SECONDS))
    levels: list[float] = []
    for first_frame in range(0, frames, window_frames):
        last_frame = min(frames, first_frame + window_frames)
        first = first_frame * channels
        last = last_frame * channels
        chunk = samples[first:last]
        if not chunk:
            continue
        rms = math.sqrt(sum(value * value for value in chunk) / len(chunk))
        levels.append(_dbfs(rms))
    return levels


def _looks_like_fade(levels: Iterable[float], *, direction: str) -> bool:
    values = [value for value in levels if math.isfinite(value) and value > -100.0]
    if len(values) < 5:
        return False
    change = values[-1] - values[0]
    if direction == "in":
        if change < 8.0:
            return False
        consistent = sum(1 for before, after in zip(values, values[1:]) if after >= before - 2.0)
    else:
        if change > -8.0:
            return False
        consistent = sum(1 for before, after in zip(values, values[1:]) if after <= before + 2.0)
    return consistent / max(1, len(values) - 1) >= 0.72


def _peak_for_interval(
    samples: array.array[float], sample_rate: int, channels: int, slice_start: float, start: float, end: float
) -> float:
    first_frame = max(0, int(math.floor((start - slice_start) * sample_rate)))
    last_frame = min(len(samples) // channels, int(math.ceil((end - slice_start) * sample_rate)))
    first = first_frame * channels
    last = last_frame * channels
    if last <= first:
        return 0.0
    return max(abs(value) for value in samples[first:last])


def _volume_stats(ffmpeg: str, path: Path) -> tuple[float | None, float | None]:
    result = _run(
        [
            ffmpeg,
            "-hide_banner",
            "-nostats",
            "-i",
            str(path),
            "-map",
            "0:a:0",
            "-af",
            "volumedetect",
            "-f",
            "null",
            "-",
        ],
        check=False,
    )
    if result.returncode != 0:
        return None, None
    text = result.stderr.decode("utf-8", errors="replace")
    mean_match = re.search(r"mean_volume:\s*(-?inf|[-+]?[0-9.]+)\s*dB", text)
    peak_match = re.search(r"max_volume:\s*(-?inf|[-+]?[0-9.]+)\s*dB", text)
    def value(match: re.Match[str] | None) -> float | None:
        if match is None or match.group(1) == "-inf":
            return None
        return float(match.group(1))
    return value(mean_match), value(peak_match)


def _format_db(value: float | None) -> str:
    return "N/A" if value is None else f"{value:.1f} dBFS"


def analyze_file(
    ffmpeg: str,
    ffprobe: str,
    source: Path,
    threshold_db: float,
    min_silence_seconds: float,
    safety_margin_seconds: float,
    true_silence_peak_dbfs: float,
) -> FileAnalysis:
    metadata = _probe(ffprobe, source)
    analysis = FileAnalysis(
        source=source,
        duration=metadata["duration"],
        sample_rate=metadata["sample_rate"],
        channels=metadata["channels"],
        channel_layout=metadata["channel_layout"],
        codec=metadata["codec"],
        stream_bitrate=metadata["stream_bitrate"],
        format_bitrate=metadata["format_bitrate"],
        source_size=metadata["size"],
    )
    analysis.decode_notes = _decode_check(ffmpeg, source)
    analysis.silence_spans = _detect_silences(
        ffmpeg, source, threshold_db, min_silence_seconds, analysis.duration
    )

    edge_seconds = min(EDGE_ANALYSIS_SECONDS, analysis.duration)
    head_samples = _decode_slice(ffmpeg, source, 0.0, edge_seconds, analysis.sample_rate, analysis.channels)
    tail_start = max(0.0, analysis.duration - edge_seconds)
    tail_samples = _decode_slice(
        ffmpeg, source, tail_start, edge_seconds, analysis.sample_rate, analysis.channels
    )
    head_levels = _window_levels(head_samples, analysis.sample_rate, analysis.channels)
    tail_levels = _window_levels(tail_samples, analysis.sample_rate, analysis.channels)
    analysis.fade_in = _looks_like_fade(head_levels, direction="in")
    analysis.fade_out = _looks_like_fade(tail_levels, direction="out")
    edge_frames = int(0.1 * analysis.sample_rate) * analysis.channels
    if head_samples and tail_samples:
        head_edge = head_samples[:edge_frames]
        tail_edge = tail_samples[-edge_frames:]
        head_energy = math.sqrt(sum(value * value for value in head_edge) / max(1, len(head_edge)))
        tail_energy = math.sqrt(sum(value * value for value in tail_edge) / max(1, len(tail_edge)))
        analysis.head_rms_dbfs = _dbfs(head_energy)
        analysis.tail_rms_dbfs = _dbfs(tail_energy)
        endpoint_count = min(analysis.channels, len(head_samples), len(tail_samples))
        step = max(abs(head_samples[index] - tail_samples[-analysis.channels + index]) for index in range(endpoint_count))
        analysis.loop_step_dbfs = _dbfs(step)

    minimum_peak = 10.0 ** (true_silence_peak_dbfs / 20.0)
    head_span = next(
        (span for span in analysis.silence_spans if span.start <= 0.08 and span.duration >= min_silence_seconds),
        None,
    )
    if head_span is not None:
        inspection_end = min(analysis.duration, max(head_span.end + 0.5, head_span.end))
        inspection = _decode_slice(
            ffmpeg, source, 0.0, inspection_end, analysis.sample_rate, analysis.channels
        )
        peak = _peak_for_interval(inspection, analysis.sample_rate, analysis.channels, 0.0, head_span.start, head_span.end)
        fade = _looks_like_fade(_window_levels(inspection, analysis.sample_rate, analysis.channels), direction="in")
        if peak <= minimum_peak and not fade:
            analysis.trim_start = max(0.0, head_span.end - safety_margin_seconds)
        else:
            analysis.questionable_spans.append(
                f"开头 {head_span.start:.3f}–{head_span.end:.3f}s 低于 {threshold_db:g} dBFS，但非确认数字静音或疑似渐入；保留"
            )

    tail_span = next(
        (
            span
            for span in reversed(analysis.silence_spans)
            if analysis.duration - span.end <= max(0.15, safety_margin_seconds)
            and span.duration >= min_silence_seconds
        ),
        None,
    )
    if tail_span is not None:
        inspection_start = max(0.0, tail_span.start - 0.5)
        inspection_duration = analysis.duration - inspection_start
        inspection = _decode_slice(
            ffmpeg, source, inspection_start, inspection_duration, analysis.sample_rate, analysis.channels
        )
        peak = _peak_for_interval(
            inspection,
            analysis.sample_rate,
            analysis.channels,
            inspection_start,
            tail_span.start,
            min(analysis.duration, tail_span.end),
        )
        fade = _looks_like_fade(_window_levels(inspection, analysis.sample_rate, analysis.channels), direction="out")
        if peak <= minimum_peak and not fade:
            analysis.trim_end = max(0.0, analysis.duration - tail_span.start - safety_margin_seconds)
        else:
            analysis.questionable_spans.append(
                f"结尾 {tail_span.start:.3f}–{tail_span.end:.3f}s 低于 {threshold_db:g} dBFS，但包含渐出、混响尾音或非确认静音；保留"
            )

    if analysis.trim_start + analysis.trim_end > analysis.duration - 0.5:
        analysis.questionable_spans.append("首尾静音候选过近，取消自动裁剪")
        analysis.trim_start = 0.0
        analysis.trim_end = 0.0

    analysis.source_mean_dbfs, analysis.source_peak_dbfs = _volume_stats(ffmpeg, source)
    if analysis.fade_out:
        analysis.loop_advice = "有自然渐出；建议自然播放完后切歌，若长循环需先试听再做交叉淡化"
    elif analysis.fade_in or (
        analysis.head_rms_dbfs is not None
        and analysis.tail_rms_dbfs is not None
        and abs(analysis.head_rms_dbfs - analysis.tail_rms_dbfs) > 6.0
    ):
        analysis.loop_advice = "首尾电平/渐变不匹配；建议交叉淡入淡出或自然播放完后切歌"
    elif analysis.loop_step_dbfs is not None and analysis.loop_step_dbfs > -35.0:
        analysis.loop_advice = "边界波形跳变偏大；建议交叉淡入淡出"
    else:
        analysis.loop_advice = "电平接缝较平缓，可试听后考虑直接循环"
    return analysis


def _safe_log(log_path: Path, message: str) -> None:
    try:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with log_path.open("a", encoding="utf-8") as log_file:
            log_file.write(message.rstrip() + "\n")
    except OSError as error:
        print(f"Could not persist error log at {log_path}: {error}", file=sys.stderr)


def _inspect_existing_output(
    ffmpeg: str, ffprobe: str, analysis: FileAnalysis, output: Path
) -> None:
    """Validate and report an output that the no-overwrite policy preserved."""
    expected_duration = analysis.duration - analysis.trim_start - analysis.trim_end
    notes = _decode_check(ffmpeg, output)
    metadata = _probe(ffprobe, output)
    if metadata["codec"] != "vorbis":
        raise RuntimeError(f"Existing output is not OGG Vorbis: {output} ({metadata['codec']})")
    if metadata["sample_rate"] != analysis.sample_rate or metadata["channels"] != analysis.channels:
        raise RuntimeError(
            f"Existing output layout does not match {analysis.source}: "
            f"{metadata['sample_rate']} Hz/{metadata['channels']} ch"
        )
    if abs(metadata["duration"] - expected_duration) > max(0.12, 3.0 / analysis.sample_rate):
        raise RuntimeError(
            f"Existing output duration does not match {analysis.source}: "
            f"expected {expected_duration:.3f}s, got {metadata['duration']:.3f}s"
        )
    analysis.output_duration = metadata["duration"]
    analysis.output_size = metadata["size"]
    analysis.output_mean_dbfs, analysis.output_peak_dbfs = _volume_stats(ffmpeg, output)
    analysis.decode_notes.extend(f"output: {note}" for note in notes)


def convert_file(
    ffmpeg: str,
    ffprobe: str,
    analysis: FileAnalysis,
    output: Path,
    quality: int,
    overwrite: bool,
    log_path: Path,
) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.resolve() == analysis.source.resolve():
        raise RuntimeError(f"Refusing to overwrite the source file: {analysis.source}")
    if output.exists() and not overwrite:
        analysis.skipped_existing = True
        _inspect_existing_output(ffmpeg, ffprobe, analysis, output)
        return

    expected_duration = analysis.duration - analysis.trim_start - analysis.trim_end
    filter_text = (
        f"atrim=start={analysis.trim_start:.9f}:end={analysis.duration - analysis.trim_end:.9f},asetpts=PTS-STARTPTS"
        if analysis.trim_start > 0.0 or analysis.trim_end > 0.0
        else None
    )
    with tempfile.NamedTemporaryFile(
        prefix=f".{output.stem}.", suffix=".tmp", dir=output.parent, delete=False
    ) as temp_file:
        temp_path = Path(temp_file.name)
    try:
        command = [
            ffmpeg,
            "-hide_banner",
            "-nostats",
            "-v",
            "error",
            "-i",
            str(analysis.source),
            "-map",
            "0:a:0",
            "-vn",
            "-sn",
            "-dn",
            "-map_metadata",
            "-1",
        ]
        if filter_text:
            command.extend(["-af", filter_text])
        command.extend(
            [
                "-ar",
                str(analysis.sample_rate),
                "-ac",
                str(analysis.channels),
                "-c:a",
                "libvorbis",
                "-q:a",
                str(quality),
                "-f",
                "ogg",
                "-y",
                str(temp_path),
            ]
        )
        result = _run(command, check=False)
        if result.returncode != 0:
            stderr = result.stderr.decode("utf-8", errors="replace")
            _safe_log(log_path, f"Command: {command!r}\n{stderr}")
            raise RuntimeError(f"FFmpeg conversion failed for {analysis.source}; details saved to {log_path}")
        if not temp_path.exists() or temp_path.stat().st_size <= 0:
            raise RuntimeError(f"FFmpeg created no valid output for {analysis.source}")
        decoded_notes = _decode_check(ffmpeg, temp_path)
        output_metadata = _probe(ffprobe, temp_path)
        if abs(output_metadata["duration"] - expected_duration) > max(0.12, 3.0 / analysis.sample_rate):
            raise RuntimeError(
                f"Unexpected output duration for {analysis.source}: "
                f"expected {expected_duration:.3f}s, got {output_metadata['duration']:.3f}s"
            )
        if output_metadata["sample_rate"] != analysis.sample_rate or output_metadata["channels"] != analysis.channels:
            raise RuntimeError(
                f"Output layout changed for {analysis.source}: "
                f"{output_metadata['sample_rate']} Hz/{output_metadata['channels']} ch"
            )
        if overwrite:
            os.replace(temp_path, output)
        else:
            try:
                os.link(temp_path, output)
            except FileExistsError:
                analysis.skipped_existing = True
                _inspect_existing_output(ffmpeg, ffprobe, analysis, output)
                return
            temp_path.unlink()

        analysis.output_duration = output_metadata["duration"]
        analysis.output_size = output.stat().st_size
        analysis.output_mean_dbfs, analysis.output_peak_dbfs = _volume_stats(ffmpeg, output)
        analysis.decode_notes.extend(f"output: {note}" for note in decoded_notes)
    finally:
        if temp_path.exists():
            temp_path.unlink()


def convert_loop_variant(
    ffmpeg: str,
    ffprobe: str,
    source: Path,
    output: Path,
    quality: int,
    crossfade_seconds: float,
    overwrite: bool,
    log_path: Path,
) -> tuple[float, int]:
    """Create an optional cyclic wrap crossfade from the already converted OGG."""
    if source.resolve() == output.resolve():
        raise RuntimeError(f"Refusing to overwrite loop source: {source}")
    metadata = _probe(ffprobe, source)
    duration = float(metadata["duration"])
    crossfade = min(crossfade_seconds, duration / 5.0)
    if crossfade <= 0.02 or duration <= crossfade * 3.0:
        raise RuntimeError(f"Loop crossfade duration is not viable for {source} ({duration:.3f}s).")
    if output.exists() and not overwrite:
        loop_metadata = _probe(ffprobe, output)
        notes = _decode_check(ffmpeg, output)
        expected_duration = duration - crossfade
        if loop_metadata["codec"] != "vorbis" or loop_metadata["channels"] != metadata["channels"] or loop_metadata["sample_rate"] != metadata["sample_rate"]:
            raise RuntimeError(f"Existing loop variant has an incompatible stream layout: {output}")
        if abs(loop_metadata["duration"] - expected_duration) > max(0.12, 3.0 / metadata["sample_rate"]):
            raise RuntimeError(f"Existing loop variant has an unexpected duration: {output}")
        if notes:
            raise RuntimeError(f"Existing loop variant failed decode validation: {output}: {notes}")
        return float(loop_metadata["duration"]), int(loop_metadata["size"])

    output.parent.mkdir(parents=True, exist_ok=True)
    middle_duration = duration - 2.0 * crossfade
    filter_graph = (
        "[0:a]asetpts=PTS-STARTPTS[middle];"
        "[1:a]asetpts=PTS-STARTPTS[tail];"
        "[2:a]asetpts=PTS-STARTPTS[head];"
        f"[tail][head]acrossfade=d={crossfade:.9f}:c1=tri:c2=tri[wrap];"
        "[middle][wrap]concat=n=2:v=0:a=1,asetpts=N/SR/TB[out]"
    )
    with tempfile.NamedTemporaryFile(prefix=f".{output.stem}.", suffix=".tmp", dir=output.parent, delete=False) as temp_file:
        temp_path = Path(temp_file.name)
    try:
        command = [
            ffmpeg, "-hide_banner", "-nostats", "-v", "error",
            "-ss", f"{crossfade:.9f}", "-t", f"{middle_duration:.9f}", "-i", str(source),
            "-ss", f"{duration - crossfade:.9f}", "-t", f"{crossfade:.9f}", "-i", str(source),
            "-ss", "0", "-t", f"{crossfade:.9f}", "-i", str(source),
            "-filter_complex", filter_graph, "-map", "[out]", "-vn", "-sn", "-dn",
            "-ar", str(metadata["sample_rate"]), "-ac", str(metadata["channels"]),
            "-c:a", "libvorbis", "-q:a", str(quality), "-f", "ogg", "-y", str(temp_path),
        ]
        result = _run(command, check=False)
        if result.returncode != 0:
            stderr = result.stderr.decode("utf-8", errors="replace")
            _safe_log(log_path, f"Command: {command!r}\n{stderr}")
            raise RuntimeError(f"FFmpeg loop crossfade failed for {source}; details saved to {log_path}")
        if not temp_path.exists() or temp_path.stat().st_size <= 0:
            raise RuntimeError(f"FFmpeg created no valid loop variant for {source}")
        decode_notes = _decode_check(ffmpeg, temp_path)
        loop_metadata = _probe(ffprobe, temp_path)
        expected_duration = duration - crossfade
        if abs(loop_metadata["duration"] - expected_duration) > max(0.12, 3.0 / metadata["sample_rate"]):
            raise RuntimeError(f"Loop variant duration mismatch for {source}: expected {expected_duration:.3f}s, got {loop_metadata['duration']:.3f}s")
        if loop_metadata["sample_rate"] != metadata["sample_rate"] or loop_metadata["channels"] != metadata["channels"] or decode_notes:
            raise RuntimeError(f"Loop variant validation failed for {source}: {decode_notes}")
        if overwrite:
            os.replace(temp_path, output)
        else:
            try:
                os.link(temp_path, output)
            except FileExistsError:
                return convert_loop_variant(ffmpeg, ffprobe, source, output, quality, crossfade_seconds, False, log_path)
            temp_path.unlink()
        return float(loop_metadata["duration"]), int(output.stat().st_size)
    finally:
        if temp_path.exists():
            temp_path.unlink()


def _format_seconds(value: float) -> str:
    return f"{value:.2f}s"


def _print_report(analyses: list[FileAnalysis], output_dir: Path, dry_run: bool, threshold_db: float, min_silence: float, margin: float, quality: int) -> None:
    print("\n| 文件 | 原始时长 | 开头裁剪 | 结尾裁剪 | 输出时长 | 输出大小 | 循环建议 |")
    print("|---|---:|---:|---:|---:|---:|---|")
    for item in analyses:
        output = output_dir / f"{item.source.stem}.ogg"
        output_duration = item.output_duration if item.output_duration is not None else item.duration - item.trim_start - item.trim_end
        output_size = f"{item.output_size / 1024:.1f} KiB" if item.output_size is not None else ("dry-run" if dry_run else "未生成")
        print(
            f"| {item.source.name} | {_format_seconds(item.duration)} | "
            f"{_format_seconds(item.trim_start)} | {_format_seconds(item.trim_end)} | "
            f"{_format_seconds(output_duration)} | {output_size} | {item.loop_advice} |"
        )
        if item.loop_variant_candidate:
            variant_duration = _format_seconds(item.loop_variant_duration) if item.loop_variant_duration is not None else "未生成"
            variant_size = f"{item.loop_variant_size / 1024:.1f} KiB" if item.loop_variant_size is not None else ("dry-run candidate" if dry_run else "未生成")
            print(f"  - 循环优化副本：{output_dir / (item.source.stem + '_loop.ogg')}；时长 {variant_duration}；大小 {variant_size}。原始转码版保留供对比。")
    print(f"\n模式：{'dry-run（未写音频）' if dry_run else '已转码'}；编码：OGG Vorbis q{quality}。")
    print(
        f"静音检测：{threshold_db:g} dBFS、最短 {min_silence:g}s；裁剪安全余量：{margin:g}s；"
        f"仅在确认数字静音且无渐入/渐出特征时裁剪。"
    )
    for item in analyses:
        print(
            f"\n{item.source.name}: {item.codec}, {item.sample_rate} Hz, {item.channels} ch "
            f"({item.channel_layout}), stream {item.stream_bitrate / 1000:.1f} kb/s, "
            f"file {item.source_size / 1024:.1f} KiB。"
        )
        spans = [span for span in item.silence_spans if span.duration >= min_silence]
        if spans:
            intervals = ", ".join(f"{span.start:.3f}–{span.end:.3f}s ({span.duration:.3f}s)" for span in spans)
            print(f"  - {threshold_db:g} dBFS 静音候选（≥{min_silence:g}s）：{intervals}")
        else:
            print(f"  - 未检测到达到阈值和时长条件的首尾/内部静音区间。")
        print(f"  - 边界 100ms RMS：开头 {_format_db(item.head_rms_dbfs)}，结尾 {_format_db(item.tail_rms_dbfs)}；首尾样点跳变 {_format_db(item.loop_step_dbfs)}。")
        print(f"  - 自然渐入：{'检测到' if item.fade_in else '未明确检测到'}；自然渐出：{'检测到' if item.fade_out else '未明确检测到'}。")
        if item.questionable_spans:
            for note in item.questionable_spans:
                print(f"  - 保守保留：{note}")
        elif not spans:
            print("  - 可疑静音：无。")
        if item.decode_notes:
            print("  - 解码警告：" + "；".join(item.decode_notes))
        else:
            print("  - 解码检查：未发现 FFmpeg 错误或警告。")
        if item.source_mean_dbfs is not None and item.output_mean_dbfs is not None:
            mean_diff = item.output_mean_dbfs - item.source_mean_dbfs
            peak_diff = (item.output_peak_dbfs or 0.0) - (item.source_peak_dbfs or 0.0)
            print(
                f"  - 音量对比（volumedetect）：mean {_format_db(item.source_mean_dbfs)} → "
                f"{_format_db(item.output_mean_dbfs)} ({mean_diff:+.1f} dB)，peak "
                f"{_format_db(item.source_peak_dbfs)} → {_format_db(item.output_peak_dbfs)} ({peak_diff:+.1f} dB)。"
            )
        elif dry_run:
            print(f"  - 输出响度/峰值对比：dry-run 未转码，待转换后测量。")
        if item.skipped_existing:
            print(f"  - 已有输出存在，按默认策略跳过：{output_dir / (item.source.stem + '.ogg')}")
        if item.output_duration is not None:
            print(f"  - 输出验证：{item.output_duration:.3f}s, {item.sample_rate} Hz, {item.channels} ch, {item.output_size} bytes。")


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path, help="音频文件或仅扫描一层的目录")
    parser.add_argument("--output", required=True, type=Path, help="OGG 输出目录")
    parser.add_argument("--category", choices=("music", "sfx"), default="music", help="媒体类别")
    parser.add_argument("--dry-run", action="store_true", help="只分析，不生成音频")
    parser.add_argument("--overwrite", action="store_true", help="允许覆盖已有 OGG 输出")
    parser.add_argument("--quality", type=int, default=6, choices=range(0, 11), help="libvorbis VBR quality（默认 q6）")
    parser.add_argument("--silence-threshold-db", type=float, default=DEFAULT_THRESHOLD_DB)
    parser.add_argument("--min-silence-duration", type=float, default=DEFAULT_MIN_SILENCE_SECONDS)
    parser.add_argument("--safety-margin", type=float, default=DEFAULT_SAFETY_MARGIN_SECONDS)
    parser.add_argument("--true-silence-peak-dbfs", type=float, default=DEFAULT_TRUE_SILENCE_PEAK_DBFS)
    parser.add_argument("--make-loop-variants", action="store_true", help="为接缝筛查不理想的 SFX Loop 额外生成独立循环副本")
    parser.add_argument("--loop-crossfade-seconds", type=float, default=1.0, help="循环副本首尾跨接淡化时长；默认 1 秒")
    parser.add_argument("--ffmpeg", default=os.environ.get("FFMPEG", "ffmpeg"))
    parser.add_argument("--ffprobe", default=os.environ.get("FFPROBE", "ffprobe"))
    parser.add_argument("--log-file", type=Path, help="错误日志位置；默认写入输出目录/audio_prepare_errors.log")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    input_path = args.input.expanduser()
    output_dir = args.output.expanduser()
    log_path = args.log_file.expanduser() if args.log_file else output_dir / "audio_prepare_errors.log"
    if not input_path.exists():
        parser_error = f"Input path does not exist: {input_path}"
        _safe_log(log_path, parser_error)
        print(parser_error, file=sys.stderr)
        return 2
    input_parts = {part.lower() for part in input_path.resolve().parts}
    if args.category == "music" and "sfx" in input_parts:
        parser_error = "The music processor refuses paths inside an sfx directory."
        _safe_log(log_path, parser_error)
        print(parser_error, file=sys.stderr)
        return 2
    if args.category == "sfx" and "sfx" not in input_parts:
        parser_error = "The SFX processor only accepts an input path inside an sfx directory."
        _safe_log(log_path, parser_error)
        print(parser_error, file=sys.stderr)
        return 2
    if shutil.which(args.ffmpeg) is None or shutil.which(args.ffprobe) is None:
        parser_error = f"ffmpeg/ffprobe not found (ffmpeg={args.ffmpeg}, ffprobe={args.ffprobe})"
        _safe_log(log_path, parser_error)
        print(parser_error, file=sys.stderr)
        return 2
    if args.min_silence_duration <= 0.0 or args.safety_margin < 0.0 or args.loop_crossfade_seconds <= 0.0:
        print("Silence duration must be positive and safety margin nonnegative.", file=sys.stderr)
        return 2
    if args.make_loop_variants and args.category != "sfx":
        print("--make-loop-variants is only supported for --category sfx.", file=sys.stderr)
        return 2

    if input_path.is_file():
        sources = [input_path] if input_path.suffix.lower() in SUPPORTED_EXTENSIONS else []
    else:
        # Deliberately non-recursive; the processed output subdirectory is not scanned.
        sources = sorted(
            path for path in input_path.iterdir() if path.is_file() and path.suffix.lower() in SUPPORTED_EXTENSIONS
        )
    if args.category == "sfx":
        allowed_stems = SFX_LOOP_STEMS | SFX_ONESHOT_STEMS
        sources = [source for source in sources if source.stem.upper() in allowed_stems and source.suffix.lower() == ".mp3"]
        print("SFX 规则：仅处理已列入目录的 Loop/One-shot MP3；MM 系列及未知素材均跳过。")
    if not sources:
        print(f"No supported audio files found in {input_path}")
        return 0

    analyses: list[FileAnalysis] = []
    failures = 0
    for source in sources:
        try:
            item = analyze_file(
                args.ffmpeg,
                args.ffprobe,
                source,
                args.silence_threshold_db,
                args.min_silence_duration,
                args.safety_margin,
                args.true_silence_peak_dbfs,
            )
            if args.category == "sfx" and source.stem.upper() in SFX_ONESHOT_STEMS:
                item.loop_advice = "One-shot；保留自然衰减；建议人工试听确认雷声尾音"
            elif args.category == "sfx" and source.stem.upper() in SFX_LOOP_STEMS:
                item.loop_advice = "Loop；接缝指标仅供筛查，需人工试听确认"
                edge_mismatch = (
                    item.fade_in or item.fade_out
                    or (item.loop_step_dbfs is not None and item.loop_step_dbfs > -35.0)
                    or (item.head_rms_dbfs is not None and item.tail_rms_dbfs is not None and abs(item.head_rms_dbfs - item.tail_rms_dbfs) > 6.0)
                )
                item.loop_variant_candidate = edge_mismatch
            target = output_dir / f"{source.stem}.ogg"
            if not args.dry_run:
                convert_file(args.ffmpeg, args.ffprobe, item, target, args.quality, args.overwrite, log_path)
                if args.make_loop_variants and item.loop_variant_candidate:
                    item.loop_variant_duration, item.loop_variant_size = convert_loop_variant(
                        args.ffmpeg,
                        args.ffprobe,
                        target,
                        output_dir / f"{source.stem}_loop.ogg",
                        args.quality,
                        args.loop_crossfade_seconds,
                        args.overwrite,
                        log_path,
                    )
            elif target.exists() and not args.overwrite:
                item.skipped_existing = True
                _inspect_existing_output(args.ffmpeg, args.ffprobe, item, target)
                if args.make_loop_variants and item.loop_variant_candidate:
                    variant_path = output_dir / f"{source.stem}_loop.ogg"
                    if variant_path.exists():
                        variant_meta = _probe(args.ffprobe, variant_path)
                        item.loop_variant_duration = float(variant_meta["duration"])
                        item.loop_variant_size = int(variant_meta["size"])
            analyses.append(item)
        except (OSError, ValueError, RuntimeError, json.JSONDecodeError, subprocess.SubprocessError) as error:
            failures += 1
            message = f"{source}: {error}"
            print(message, file=sys.stderr)
            _safe_log(log_path, message)
    _print_report(
        analyses,
        output_dir,
        args.dry_run,
        args.silence_threshold_db,
        args.min_silence_duration,
        args.safety_margin,
        args.quality,
    )
    print(f"处理完成：{len(analyses)} 个文件，{failures} 个错误。")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
