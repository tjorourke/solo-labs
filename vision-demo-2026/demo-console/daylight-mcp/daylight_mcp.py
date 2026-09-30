#!/usr/bin/env python3
"""Site daylight MCP: sunrise, sunset, safe outdoor work windows and moon phase for EMEA sites.

Pure arithmetic. No data store, no network, no secrets and nothing it can change, which is why
its AgentRegistry record carries mcp.governance/auto-approve=true. Stdlib only.
"""
from datetime import date, datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from zoneinfo import ZoneInfo
import json
import math

PLACES = {
    "dublin": ("Dublin", 53.3498, -6.2603, "Europe/Dublin"),
    "london": ("London", 51.5074, -0.1278, "Europe/London"),
    "madrid": ("Madrid", 40.4168, -3.7038, "Europe/Madrid"),
    "lisbon": ("Lisbon", 38.7223, -9.1393, "Europe/Lisbon"),
    "paris": ("Paris", 48.8566, 2.3522, "Europe/Paris"),
    "amsterdam": ("Amsterdam", 52.3676, 4.9041, "Europe/Amsterdam"),
    "berlin": ("Berlin", 52.5200, 13.4050, "Europe/Berlin"),
    "milan": ("Milan", 45.4642, 9.1900, "Europe/Rome"),
    "warsaw": ("Warsaw", 52.2297, 21.0122, "Europe/Warsaw"),
    "stockholm": ("Stockholm", 59.3293, 18.0686, "Europe/Stockholm"),
    "reykjavik": ("Reykjavik", 64.1466, -21.9426, "Atlantic/Reykjavik"),
    "tromso": ("Tromsø", 69.6492, 18.9553, "Europe/Oslo"),
    "dubai": ("Dubai", 25.2048, 55.2708, "Asia/Dubai"),
    "johannesburg": ("Johannesburg", -26.2041, 28.0473, "Africa/Johannesburg"),
}
# Outdoor site work (a tower climb, a rooftop swap) starts this long after sunrise and
# ends this long before sunset. A demo rule, stated in every answer that uses it.
WORK_BUFFER_MIN = 30
SYNODIC = 29.530588853
NEW_MOON_REF = datetime(2000, 1, 6, 18, 14, tzinfo=timezone.utc)


def _place(name):
    key = (name or "").strip().lower().replace("ø", "o").replace(" ", "")
    return PLACES.get(key)


def _day(value, tz):
    if value:
        return date.fromisoformat(value)
    return datetime.now(tz).date()


def _jd_to_dt(jd):
    return datetime.fromtimestamp((jd - 2440587.5) * 86400, tz=timezone.utc)


def _sun(lat, lon, d, altitude):
    """Sunrise equation. Returns (rise, noon, set) in UTC, or a polar state string."""
    n = d.toordinal() + 1721425 - 2451545
    jstar = n - lon / 360.0
    m = math.radians((357.5291 + 0.98560028 * jstar) % 360)
    c = 1.9148 * math.sin(m) + 0.02 * math.sin(2 * m) + 0.0003 * math.sin(3 * m)
    lam = math.radians((math.degrees(m) + c + 180 + 102.9372) % 360)
    transit = 2451545.0 + jstar + 0.0053 * math.sin(m) - 0.0069 * math.sin(2 * lam)
    dec = math.asin(math.sin(lam) * math.sin(math.radians(23.4397)))
    phi = math.radians(lat)
    cos_w = (math.sin(math.radians(altitude)) - math.sin(phi) * math.sin(dec)) / (math.cos(phi) * math.cos(dec))
    noon = _jd_to_dt(transit)
    if cos_w > 1:
        return "polar_night", noon, None
    if cos_w < -1:
        return "midnight_sun", noon, None
    w = math.degrees(math.acos(cos_w)) / 360.0
    return _jd_to_dt(transit - w), noon, _jd_to_dt(transit + w)


def _hm(dt, tz):
    return dt.astimezone(tz).strftime("%H:%M")


def _dur(td):
    mins = int(round(td.total_seconds() / 60))
    return f"{mins // 60}h {mins % 60:02d}m"


def daylight(args):
    p = _place(args.get("place"))
    if not p:
        return {"error": "unknown place", "known": sorted(v[0] for v in PLACES.values())}
    city, lat, lon, tzname = p
    tz = ZoneInfo(tzname)
    d = _day(args.get("date"), tz)
    rise, noon, sset = _sun(lat, lon, d, -0.833)
    out = {"place": city, "date": d.isoformat(), "timezone": tzname, "solar_noon": _hm(noon, tz)}
    if isinstance(rise, str):
        out["sun"] = "The sun does not rise today." if rise == "polar_night" else "The sun does not set today."
        return out
    dawn, _, dusk = _sun(lat, lon, d, -6)
    out.update({
        "sunrise": _hm(rise, tz), "sunset": _hm(sset, tz), "day_length": _dur(sset - rise),
    })
    if not isinstance(dawn, str):
        out["civil_dawn"] = _hm(dawn, tz)
        out["civil_dusk"] = _hm(dusk, tz)
    return out


def work_window(args):
    base = daylight(args)
    if "error" in base:
        return base
    rule = f"Starts {WORK_BUFFER_MIN} minutes after sunrise and ends {WORK_BUFFER_MIN} minutes before sunset."
    if "sunrise" not in base:
        return {**base, "work_window": None, "rule": rule,
                "note": "No safe daylight window: " + base["sun"].lower()}
    tz = ZoneInfo(base["timezone"])
    d = date.fromisoformat(base["date"])
    rise, _, sset = _sun(PLACES[_key(base["place"])][1], PLACES[_key(base["place"])][2], d, -0.833)
    start = rise + timedelta(minutes=WORK_BUFFER_MIN)
    end = sset - timedelta(minutes=WORK_BUFFER_MIN)
    return {"place": base["place"], "date": base["date"], "start": _hm(start, tz), "end": _hm(end, tz),
            "usable": _dur(end - start), "rule": rule}


def _key(city):
    return next(k for k, v in PLACES.items() if v[0] == city)


def moon_phase(args):
    d = date.fromisoformat(args["date"]) if args.get("date") else datetime.now(timezone.utc).date()
    at = datetime(d.year, d.month, d.day, 12, tzinfo=timezone.utc)
    age = ((at - NEW_MOON_REF).total_seconds() / 86400) % SYNODIC
    lit = (1 - math.cos(2 * math.pi * age / SYNODIC)) / 2
    names = ["New moon", "Waxing crescent", "First quarter", "Waxing gibbous",
             "Full moon", "Waning gibbous", "Last quarter", "Waning crescent"]
    return {"date": d.isoformat(), "phase": names[int((age / SYNODIC) * 8 + 0.5) % 8],
            "illuminated_percent": round(lit * 100), "age_days": round(age, 1)}


def local_time(args):
    p = _place(args.get("place"))
    if not p:
        return {"error": "unknown place", "known": sorted(v[0] for v in PLACES.values())}
    now = datetime.now(ZoneInfo(p[3]))
    return {"place": p[0], "timezone": p[3], "local_time": now.strftime("%Y-%m-%d %H:%M"),
            "utc_offset": now.strftime("%z")}


def list_places(_args):
    return [{"place": v[0], "timezone": v[3], "lat": v[1], "lon": v[2]} for v in PLACES.values()]


PLACE = {"place": {"type": "string", "description": "City, for example Berlin or Tromsø."}}
DATE = {"date": {"type": "string", "description": "YYYY-MM-DD. Defaults to today."}}
TOOLS = [
    {"name": "list_places", "description": "EMEA sites this server knows, with time zones.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "daylight", "description": "Sunrise, sunset, civil twilight and day length at a site.",
     "inputSchema": {"type": "object", "properties": {**PLACE, **DATE}, "required": ["place"]}},
    {"name": "work_window", "description": "Safe daylight window for outdoor site work, such as a tower climb.",
     "inputSchema": {"type": "object", "properties": {**PLACE, **DATE}, "required": ["place"]}},
    {"name": "moon_phase", "description": "Moon phase and how much of it is lit.",
     "inputSchema": {"type": "object", "properties": {**DATE}}},
    {"name": "local_time", "description": "Current local time and UTC offset at a site.",
     "inputSchema": {"type": "object", "properties": {**PLACE}, "required": ["place"]}},
]
CALLS = {"list_places": list_places, "daylight": daylight, "work_window": work_window,
         "moon_phase": moon_phase, "local_time": local_time}


def call(name, args):
    fn = CALLS.get(name)
    if not fn:
        return {"error": "unknown tool"}
    try:
        return fn(args or {})
    except ValueError as e:
        return {"error": str(e)}


def rpc(msg):
    method = msg.get("method")
    mid = msg.get("id")
    params = msg.get("params") or {}
    if method == "initialize":
        return {"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "site-daylight", "version": "1"},
        }}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS}}
    if method == "tools/call":
        result = call(params.get("name"), params.get("arguments") or {})
        return {"jsonrpc": "2.0", "id": mid, "result": {
            "content": [{"type": "text", "text": json.dumps(result)}],
            "isError": isinstance(result, dict) and "error" in result,
        }}
    if method == "ping":
        return {"jsonrpc": "2.0", "id": mid, "result": {}}
    if method and method.startswith("notifications/"):
        return None
    if mid is not None:
        return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": method}}
    return None


class H(BaseHTTPRequestHandler):
    def log_message(self, *args):
        return

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        try:
            msg = json.loads(self.rfile.read(n) or b"{}")
        except json.JSONDecodeError:
            self.send_error(400)
            return
        out = rpc(msg)
        if out is None:
            self.send_response(202)
            self.end_headers()
            return
        body = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"site-daylight mcp\n")


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 3000), H).serve_forever()
