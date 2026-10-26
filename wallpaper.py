#!/usr/bin/env python3
import filecmp
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "wallpaper-carousel"
CACHE = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "wallpaper-carousel"
KEY = CONFIG / "unsplash-key"
EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp", ".jxl", ".avif", ".heif"}
REFERRAL = "utm_source=wallpaper_carousel&utm_medium=referral"
DMS_CONFIG = CONFIG.parent / "DankMaterialShell"
DMS_STATE = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "DankMaterialShell"
DMS_CACHE = CACHE.parent / "DankMaterialShell"
STARTUP_OPTIONS = ("enabled", "rotationEnabled", "rotationPool", "cadence", "folder", "collections", "blacklist", "colorVariety", "favorites", "tags")


def api(path, params=None):
    key = KEY.read_text().strip()
    if not key:
        raise ValueError("Add your Unsplash access key in Wallpaper Carousel settings.")
    url = "https://api.unsplash.com/" + path.lstrip("/")
    if params:
        url += "?" + urllib.parse.urlencode(params)
    request = urllib.request.Request(url, headers={"Authorization": "Client-ID " + key, "Accept-Version": "v1", "User-Agent": "WallpaperCarousel/1.2"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def photo(raw):
    ident = str(raw["id"])
    if not re.fullmatch(r"[A-Za-z0-9_-]+", ident):
        raise ValueError("Invalid photo identifier.")
    urls, user = raw["urls"], raw.get("user") or {}
    full = urllib.parse.urlsplit(urls.get("raw") or urls["full"])
    params = dict(urllib.parse.parse_qsl(full.query))
    params.update(w=3840, q=85, fit="max", fm="jpg")
    return dict(
        id="unsplash:" + ident, wid="unsplash:" + ident, photoId=ident, provider="unsplash", isCollection=False,
        fileName="unsplash-" + ident + ".jpg", thumb=urls.get("small", urls["regular"]), shape=urls["regular"],
        full=urllib.parse.urlunsplit(full._replace(query=urllib.parse.urlencode(params))),
        description=raw.get("description") or raw.get("alt_description") or "",
        tags=[tag["title"] for tag in raw.get("tags", []) if tag.get("title")],
        resolution=f'{raw["width"]}x{raw["height"]}', size=0, category="Unsplash", colors=raw.get("color") or "",
        views=raw.get("views", 0), favs=raw.get("likes", 0),
        photographer=user.get("name", ""), profile=(user.get("links", {}).get("html", "https://unsplash.com") + "?" + REFERRAL),
        link=raw.get("links", {}).get("html", "https://unsplash.com") + "?" + REFERRAL,
        collectionId="", title="",
    )


def collection(raw):
    cover = raw.get("cover_photo") or {}
    urls = cover.get("urls") or {}
    author = cover.get("user") or raw.get("user") or {}
    return dict(
        id="collection:" + str(raw["id"]), wid="collection:" + str(raw["id"]), collectionId=str(raw["id"]),
        provider="unsplash", isCollection=True, title=raw["title"], description=raw.get("description") or "",
        thumb=urls.get("small", ""), shape=urls.get("regular", ""), full=urls.get("regular", ""),
        fileName="", photoId="", tags=[], resolution=str(raw.get("total_photos", 0)) + " photos", size=0,
        category="Collection", colors="", views=0, favs=0, photographer=author.get("name", ""),
        profile=author.get("links", {}).get("html", "https://unsplash.com") + "?" + REFERRAL,
        link=raw.get("links", {}).get("html", "https://unsplash.com") + "?" + REFERRAL,
    )


def collection_id(value):
    value = value.strip()
    if value.startswith(("https://", "http://")):
        url = urllib.parse.urlsplit(value)
        parts = url.path.strip("/").split("/")
        value = parts[1] if url.hostname in ("unsplash.com", "www.unsplash.com") and len(parts) >= 2 and parts[0] == "collections" else ""
    if not re.fullmatch(r"[A-Za-z0-9_-]+", value):
        raise ValueError("Enter an Unsplash collection URL or ID.")
    return value


def atomic_copy(source, directory):
    directory.mkdir(parents=True, exist_ok=True)
    destination = directory / source.name
    index = 1
    while destination.exists():
        if source.resolve() == destination.resolve() or filecmp.cmp(source, destination, shallow=False):
            return destination
        index += 1
        destination = directory / f"{source.stem}-{index}{source.suffix}"
    fd, temporary = tempfile.mkstemp(prefix=".wallpaper-", suffix=".part", dir=directory)
    try:
        with os.fdopen(fd, "wb") as output, source.open("rb") as original:
            shutil.copyfileobj(original, output)
        os.link(temporary, destination)
        return destination
    finally:
        Path(temporary).unlink(missing_ok=True)


def download(item, directory):
    ident = item["photoId"]
    if not re.fullmatch(r"[A-Za-z0-9_-]+", ident):
        raise ValueError("Invalid photo identifier.")
    directory.mkdir(parents=True, exist_ok=True)
    name = "unsplash-" + ident + ".jpg"
    destination, cached = directory / name, CACHE / name
    created = not destination.exists()
    if created:
        if cached.exists() and directory != CACHE:
            destination = atomic_copy(cached, directory)
        else:
            if urllib.parse.urlsplit(item["full"]).hostname != "images.unsplash.com":
                raise ValueError("Invalid Unsplash image URL.")
            fd, temporary = tempfile.mkstemp(prefix=".wallpaper-", suffix=".part", dir=directory)
            try:
                with os.fdopen(fd, "wb") as output, urllib.request.urlopen(item["full"], timeout=90) as response:
                    if not response.headers.get("Content-Type", "").startswith("image/"):
                        raise ValueError("Unsplash did not return an image.")
                    shutil.copyfileobj(response, output)
                if not Path(temporary).stat().st_size:
                    raise ValueError("Unsplash returned an empty image.")
                os.replace(temporary, destination)
            finally:
                Path(temporary).unlink(missing_ok=True)
    os.utime(destination, None)
    import colors
    _, palette = colors.analyse(str(destination)) if colors.MAGICK else ([], {})
    if colors.MAGICK and not palette:
        if created:
            destination.unlink(missing_ok=True)
        raise ValueError("The downloaded file is not a readable image.")
    try:
        api("photos/" + ident + "/download")
    except (OSError, ValueError):
        pass
    return dict(path=str(destination), fileName=destination.name, palette=palette)


def read_json(path, default):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def write_text(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            output.write(value)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def write_json(path, value):
    write_text(path, json.dumps(value))


def startup_inputs():
    plugins = read_json(DMS_CONFIG / "plugin_settings.json", {})
    options = plugins.get("wallhavenCarousel", {})
    settings = read_json(DMS_CONFIG / "settings.json", {})
    session = read_json(DMS_STATE / "session.json", {})
    return dict(
        options={key: options.get(key) for key in STARTUP_OPTIONS},
        theme={key: value for key, value in settings.items() if key.startswith("matugen") or key in ("currentThemeName", "iconTheme")},
        canvas=plugins.get("seaglassCanvas", {}),
        session={key: session.get(key) for key in ("wallpaperPath", "isLightMode", "perMonitorWallpaper", "perModeWallpaper", "wallpaperCyclingFolderPath")},
    )


def prepare_startup(args):
    command = shlex.split(args["command"])
    if command[1:3] != ["matugen", "generate"]:
        raise ValueError("No completed DMS theme command is available.")
    inputs = startup_inputs()
    if inputs["options"] != {key: args["options"].get(key) for key in STARTUP_OPTIONS}:
        raise ValueError("Wallpaper settings changed during preparation.")
    command[command.index("--value") + 1] = args["item"]["path"]
    command[command.index("--kind") + 1] = "image"
    templates = subprocess.run([command[0], "matugen", "check"], check=True, capture_output=True, text=True, timeout=15)
    skip = ",".join(item["id"] for item in json.loads(templates.stdout))
    CACHE.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="startup-", dir=CACHE) as directory:
        staging = Path(directory)
        # Isolate outputs and disable application templates and refreshes during preparation
        command += ["--state-dir", directory, "--config-dir", str(staging / "config"), "--skip-templates", skip,
                    "--run-user-templates=false", "--sync-mode-with-portal=false"]
        completed = subprocess.run(command, capture_output=True, text=True, timeout=90)
        if completed.returncode not in (0, 2):
            raise ValueError("Couldn't prepare the next wallpaper's colors.")
        colors = read_json(staging / "dms-colors.json", {})
        if not colors.get("colors", {}).get("dark") or not colors.get("colors", {}).get("light"):
            raise ValueError("DMS did not produce a complete color cache.")
    if startup_inputs() != inputs:
        raise ValueError("Theme settings changed during preparation.")
    write_json(CACHE / "startup.json", dict(
        item=args["item"], rotation=args["rotation"], lastAt=args["lastAt"],
        intervalMs=args["intervalMs"], inputs=inputs, colors=colors,
    ))
    return {}


def startup():
    inputs = startup_inputs()
    options = inputs["options"]
    if options["enabled"] is False or not options["rotationEnabled"] or (options["cadence"] or "session") != "session":
        return
    if (inputs["canvas"].get("preset") or {}).get("name") == "oled" or inputs["session"]["perMonitorWallpaper"] or inputs["session"]["perModeWallpaper"]:
        return
    state_path = DMS_STATE / "plugins/wallhavenCarousel_state.json"
    state = read_json(state_path, {})
    rotation = state.get("rotation", {})
    session_id = run({"op": "session"})["session"]
    if rotation.get("session") == session_id:
        return
    prepared = read_json(CACHE / "startup.json", {})
    if prepared.get("inputs") == inputs and prepared.get("lastAt") == rotation.get("lastAt", 0) and prepared.get("colors", {}).get("colors") and Path(prepared.get("item", {}).get("path", "")).is_file():
        item = prepared["item"]
        session_path = DMS_STATE / "session.json"
        session = read_json(session_path, {})
        session["wallpaperPath"] = item["path"]
        next_rotation = prepared["rotation"]
        now = int(time.time() * 1000)
        next_rotation.update(lastAt=now, nextAt=now + prepared["intervalMs"],
                             recent=([dict(id=item["id"], palette=item.get("palette", {}))] + rotation.get("recent", []))[:100])
        if item.get("provider") == "unsplash":
            next_rotation["currentRemote"] = item
        write_json(DMS_CACHE / "dms-colors.json", prepared["colors"])
        write_json(session_path, session)
        rotation = next_rotation
        (CACHE / "startup.json").unlink(missing_ok=True)
    # A missing or stale cache keeps this session's theme instead of changing it after login
    rotation["session"] = session_id
    state["rotation"] = rotation
    write_json(state_path, state)


def run(args):
    op = args["op"]
    if op == "prepare-startup":
        return prepare_startup(args)
    if op == "key-status":
        return dict(configured=KEY.is_file() and bool(KEY.read_text().strip()))
    if op == "key-save":
        CONFIG.mkdir(mode=0o700, parents=True, exist_ok=True)
        key = args.get("key", "").strip()
        if not re.fullmatch(r"[A-Za-z0-9_-]+", key):
            raise ValueError("Enter your Unsplash access key, without spaces.")
        write_text(KEY, key + "\n")
        return dict(configured=True)
    if op == "search":
        kind, page = args.get("kind", "photos"), max(1, int(args.get("page", 1)))
        query = args.get("query", "").strip()
        if kind == "collections" and query.startswith(("https://", "http://")):
            item = collection(api("collections/" + collection_id(query)))
            return dict(items=[item], lastPage=1, total=1)
        params = dict(page=page, per_page=30)
        if args.get("collectionId"):
            params["orientation"] = "landscape"
            raw = api("collections/" + collection_id(args["collectionId"]) + "/photos", params)
            return dict(items=[photo(item) for item in raw], lastPage=page + (len(raw) == 30), total=-1)
        if kind not in ("photos", "collections"):
            raise ValueError("Unknown Unsplash search type.")
        params["query"] = query or "wallpaper"
        if kind == "photos":
            params.update(orientation="landscape", content_filter="high")
        raw = api("search/" + kind, params)
        normalize = collection if kind == "collections" else photo
        return dict(items=[normalize(item) for item in raw["results"]], lastPage=raw["total_pages"], total=raw["total"])
    if op == "collection":
        return dict(item=collection(api("collections/" + collection_id(args["value"]))))
    if op == "detail":
        ident = str(args["photoId"])
        if not re.fullmatch(r"[A-Za-z0-9_-]+", ident):
            raise ValueError("Invalid photo identifier.")
        return dict(item=photo(api("photos/" + ident)))
    if op == "sample":
        ids = [collection_id(value) for value in args.get("collections", [])]
        if not ids:
            raise ValueError("Subscribe to a collection first.")
        raw = api("photos/random", dict(collections=",".join(ids), count=30, orientation="landscape", content_filter="high"))
        return dict(items=[photo(item) for item in raw])
    if op == "download":
        directory = CACHE if args.get("temporary") else Path(args["folder"]).expanduser()
        return download(args["item"], directory)
    if op == "import":
        names = []
        for value in args["paths"]:
            path = Path(urllib.parse.unquote(urllib.parse.urlsplit(value).path) if value.startswith("file://") else value).expanduser()
            if not path.is_file() or path.suffix.lower() not in EXTENSIONS:
                raise ValueError("Select supported image files.")
            names.append(atomic_copy(path, Path(args["folder"]).expanduser()).name)
        return dict(names=names)
    if op == "prune":
        protected = set(args.get("protect", []))
        prepared = read_json(CACHE / "startup.json", {})
        protected.add(prepared.get("item", {}).get("path", ""))
        files = sorted(CACHE.glob("unsplash-*.jpg"), key=lambda path: path.stat().st_mtime_ns, reverse=True)
        kept = sum(str(path) in protected for path in files)
        for path in files:
            if str(path) in protected:
                continue
            if kept < 20:
                kept += 1
            else:
                path.unlink(missing_ok=True)
        return {}
    if op == "session":
        boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
        session = args.get("session") or os.environ.get("XDG_SESSION_ID")
        if not session:
            display = Path(os.environ.get("XDG_RUNTIME_DIR", "/run/user/" + str(os.getuid()))) / os.environ.get("WAYLAND_DISPLAY", "wayland-0")
            stat = display.stat()
            session = f"{stat.st_ino}:{stat.st_ctime_ns}"
        return dict(session=boot + ":" + session)
    raise ValueError("Unknown wallpaper operation.")


def main():
    try:
        result = dict(ok=True, **run(json.load(sys.stdin)))
    except urllib.error.HTTPError as error:
        message = "Unsplash is rate limiting requests. Try again later." if error.code == 429 else "Check your Unsplash access key." if error.code in (401, 403) else f"Unsplash returned HTTP {error.code}."
        result = dict(ok=False, error=message, status=error.code)
    except FileNotFoundError as error:
        result = dict(ok=False, error="Add your Unsplash access key in Wallpaper Carousel settings." if error.filename == str(KEY) else "The requested image or directory is unavailable.")
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        result = dict(ok=False, error=str(error) if isinstance(error, ValueError) else "Wallpaper operation failed. Check your connection and selected files.")
    print(json.dumps(result))


if __name__ == "__main__":
    if sys.argv[1:] == ["startup"]:
        try:
            startup()
        except (OSError, ValueError, KeyError, TypeError) as error:
            print(f"Wallpaper startup skipped: {error}", file=sys.stderr)
    else:
        main()
