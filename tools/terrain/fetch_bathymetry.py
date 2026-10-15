#!/usr/bin/env python3
"""Download the EMODnet DTM 2024 Øresund subset without authentication.

The downloader first requests a tiny NetCDF probe. It only starts the full
regional request after the probe has a valid NetCDF signature.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import sys
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[2]
REGION_JSON = ROOT / "assets/geodata/processed/oresund_region.json"
GEOREFERENCE_TRES = ROOT / "resources/oresund_georeference.tres"
SOURCE_DIR = ROOT / "assets/geodata/source"
DATASET_ID = "bathymetry_dtm_2024"
ERDDAP_BASE = f"https://erddap.emodnet.eu/erddap/griddap/{DATASET_ID}.nc"
FULL_NETCDF = SOURCE_DIR / "emodnet_bathymetry_2024_oresund.nc"
PROBE_NETCDF = SOURCE_DIR / "emodnet_bathymetry_probe.nc"
DOWNLOAD_MANIFEST = SOURCE_DIR / "emodnet_bathymetry_download.json"
FAILURE_REPORT = SOURCE_DIR / "emodnet_bathymetry_download_failure.json"


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def load_bounds() -> tuple[float, float, float, float]:
    region = json.loads(REGION_JSON.read_text(encoding="utf-8"))
    bounds = region.get("wgs84_bounds")
    if not isinstance(bounds, list) or len(bounds) != 4:
        raise RuntimeError(f"Invalid WGS84 bounds in {REGION_JSON}")
    west, south, east, north = map(float, bounds)
    text = GEOREFERENCE_TRES.read_text(encoding="utf-8")
    values = {}
    for name in ("south_latitude_deg", "north_latitude_deg", "west_longitude_deg", "east_longitude_deg"):
        match = re.search(rf"^{name}\s*=\s*(-?[0-9.]+)", text, flags=re.MULTILINE)
        if match is None:
            raise RuntimeError(f"Could not read {name} from {GEOREFERENCE_TRES}")
        values[name] = float(match.group(1))
    expected = (values["west_longitude_deg"], values["south_latitude_deg"], values["east_longitude_deg"], values["north_latitude_deg"])
    if any(abs(a - b) > 1e-5 for a, b in zip((west, south, east, north), expected)):
        raise RuntimeError("The coastline crop and GeoReference bounds differ; refusing to create a second extent.")
    return west, south, east, north


def make_url(bounds: tuple[float, float, float, float], variables: tuple[str, ...]) -> str:
    west, south, east, north = bounds
    query_parts = []
    for variable in variables:
        query_parts.append(
            f"{variable}[({south:.8f}):1:({north:.8f})][({west:.8f}):1:({east:.8f})]"
        )
    # ERDDAP accepts encoded brackets and parentheses; encoding avoids shell
    # glob interpretation and preserves the griddap projection constraints.
    return ERDDAP_BASE + "?" + quote(",".join(query_parts), safe=",():.+-_")


def download(url: str, destination: Path) -> dict:
    destination.parent.mkdir(parents=True, exist_ok=True)
    request = Request(url, headers={"User-Agent": "SeaPrototypeBathymetry/1.0 (offline game data build)"})
    last_error: Exception | None = None
    for attempt in range(3):
        try:
            with urlopen(request, timeout=180) as response:
                content_type = response.headers.get("Content-Type", "")
                payload = response.read()
                status = response.status
                headers = dict(response.headers.items())
            if not (payload.startswith(b"CDF\x01") or payload.startswith(b"CDF\x02") or payload.startswith(b"\x89HDF\r\n\x1a\n")):
                excerpt = payload[:500].decode("utf-8", errors="replace")
                raise RuntimeError(f"HTTP {status}, unexpected content type {content_type!r}; body begins: {excerpt}")
            destination.write_bytes(payload)
            return {
                "http_status": status,
                "content_type": content_type,
                "content_length_bytes": len(payload),
                "sha256": hashlib.sha256(payload).hexdigest(),
                "etag": headers.get("ETag"),
                "last_modified": headers.get("Last-Modified"),
                "netcdf_signature": payload[:8].hex(),
            }
        except HTTPError as error:
            body = error.read(2000).decode("utf-8", errors="replace")
            last_error = RuntimeError(f"HTTP {error.code}; response body: {body}")
            # 4xx responses are usually a bad query and will not improve on retry.
            if 400 <= error.code < 500 and error.code not in (408, 429):
                break
        except (URLError, TimeoutError, OSError, RuntimeError) as error:
            last_error = error
        if attempt < 2:
            time.sleep(2 ** attempt)
    raise RuntimeError(str(last_error) if last_error else "Unknown download failure")


def write_failure(url: str, bounds: tuple[float, float, float, float], message: str) -> None:
    report = {
        "attempted_at_utc": utc_now(),
        "dataset_id": DATASET_ID,
        "request_url": url,
        "bounds_wgs84_wsen": list(bounds),
        "http_status": None,
        "response_body": None,
        "error": message,
        "note": "No HTTP response was received if the error is a DNS or connection failure.",
    }
    match = re.match(r"HTTP (\d+)[,;]\s*(.*)", message, flags=re.DOTALL)
    if match:
        report["http_status"] = int(match.group(1))
        response_text = match.group(2)
        body_match = re.search(r"(?:response body|body begins):\s*(.*)", response_text, flags=re.DOTALL)
        report["response_body"] = body_match.group(1) if body_match else response_text
    FAILURE_REPORT.parent.mkdir(parents=True, exist_ok=True)
    FAILURE_REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe-only", action="store_true", help="request and validate only the small open-water probe")
    args = parser.parse_args()
    full_bounds = load_bounds()
    probe = (12.745, 55.695, 12.755, 55.705)
    probe_url = make_url(probe, ("elevation",))
    print(f"Probe URL: {probe_url}")
    try:
        probe_result = download(probe_url, PROBE_NETCDF)
    except Exception as error:
        write_failure(probe_url, probe, str(error))
        print(f"Probe failed: {error}", file=sys.stderr)
        print(f"Recorded: {FAILURE_REPORT.relative_to(ROOT)}", file=sys.stderr)
        return 2
    print(f"Probe passed: {PROBE_NETCDF.relative_to(ROOT)} · {probe_result}")
    FAILURE_REPORT.unlink(missing_ok=True)
    if args.probe_only:
        return 0

    full_url = make_url(full_bounds, ("elevation", "interpolation_flag", "value_count"))
    print(f"Full-region URL: {full_url}")
    try:
        full_result = download(full_url, FULL_NETCDF)
    except Exception as error:
        write_failure(full_url, full_bounds, str(error))
        print(f"Regional download failed: {error}", file=sys.stderr)
        print(f"Recorded: {FAILURE_REPORT.relative_to(ROOT)}", file=sys.stderr)
        return 2
    DOWNLOAD_MANIFEST.write_text(json.dumps({
        "downloaded_at_utc": utc_now(),
        "dataset_id": DATASET_ID,
        "dataset_doi": "https://doi.org/10.12770/cf51df64-56f9-4a99-b1aa-36b8d7b743a1",
        "region_bounds_wgs84_wsen": list(full_bounds),
        "request_url": full_url,
        "response": full_result,
        "netcdf_file": FULL_NETCDF.name,
    }, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Downloaded: {FULL_NETCDF.relative_to(ROOT)} · {full_result}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
