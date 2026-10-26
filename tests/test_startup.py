import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import wallpaper


class StartupTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        for name in ("CACHE", "DMS_CONFIG", "DMS_STATE", "DMS_CACHE"):
            patcher = patch.object(wallpaper, name, self.base / name)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.reset_fixture()

    def reset_fixture(self):
        self.options = dict(rotationEnabled=True, rotationPool="saved", cadence="session")
        self.session_path = wallpaper.DMS_STATE / "session.json"
        self.state_path = wallpaper.DMS_STATE / "plugins/wallhavenCarousel_state.json"
        self.image = self.base / "next.jpg"
        self.image.write_bytes(b"image")
        self.colors = dict(colors=dict(dark={"primary": "#123456"}, light={"primary": "#abcdef"}))
        wallpaper.write_json(wallpaper.DMS_CONFIG / "plugin_settings.json", {"wallhavenCarousel": self.options, "seaglassCanvas": {"preset": None}})
        wallpaper.write_json(self.session_path, dict(wallpaperPath="previous.jpg", isLightMode=True, unrelated=True))
        wallpaper.write_json(self.state_path, dict(rotation=dict(lastAt=123, session="previous-session", recent=[{"id": "previous"}]), metadata={"keep": True}))
        self.prepared = dict(
            item=dict(id="next", path=str(self.image), palette={"blue": 1}),
            rotation=dict(bags={"saved": {"remaining": ["another"]}}),
            lastAt=123, intervalMs=86400000, inputs=wallpaper.startup_inputs(), colors=self.colors,
        )
        wallpaper.write_json(wallpaper.CACHE / "startup.json", self.prepared)

    def activate(self):
        with patch.object(wallpaper, "run", return_value={"session": "new-session"}), \
             patch.object(wallpaper.subprocess, "run", side_effect=AssertionError("Startup must not run a generator")), \
             patch.object(wallpaper, "api", side_effect=AssertionError("Startup must not access the network")):
            wallpaper.startup()

    def test_boot_activates_cached_colors_and_consumes_one_turn_only(self):
        self.activate()
        session = wallpaper.read_json(self.session_path, {})
        state = wallpaper.read_json(self.state_path, {})
        self.assertEqual(session["wallpaperPath"], str(self.image))
        self.assertTrue(session["unrelated"])
        self.assertEqual(wallpaper.read_json(wallpaper.DMS_CACHE / "dms-colors.json", {}), self.colors)
        self.assertEqual(state["rotation"]["session"], "new-session")
        self.assertEqual(state["rotation"]["recent"], [{"id": "next", "palette": {"blue": 1}}, {"id": "previous"}])
        self.assertEqual(state["rotation"]["bags"], self.prepared["rotation"]["bags"])
        self.assertEqual(state["metadata"], {"keep": True})
        self.activate()
        self.assertEqual(wallpaper.read_json(self.state_path, {}), state)

    def test_missing_stale_and_deleted_preparation_keep_current_theme_without_delayed_rotation(self):
        for failure in ("missing", "invalid", "settings", "history", "image"):
            with self.subTest(failure=failure):
                self.reset_fixture()
                if failure == "missing":
                    (wallpaper.CACHE / "startup.json").unlink()
                elif failure == "invalid":
                    (wallpaper.CACHE / "startup.json").write_text("invalid json")
                elif failure == "settings":
                    wallpaper.write_json(wallpaper.DMS_CONFIG / "settings.json", {"matugenScheme": "scheme-content"})
                elif failure == "history":
                    state = wallpaper.read_json(self.state_path, {})
                    state["rotation"]["lastAt"] = 456
                    wallpaper.write_json(self.state_path, state)
                else:
                    self.image.unlink()
                self.activate()
                self.assertEqual(wallpaper.read_json(self.session_path, {})["wallpaperPath"], "previous.jpg")
                self.assertEqual(wallpaper.read_json(self.state_path, {})["rotation"]["recent"], [{"id": "previous"}])
                self.assertEqual(wallpaper.read_json(self.state_path, {})["rotation"]["session"], "new-session")
                self.assertFalse((wallpaper.DMS_CACHE / "dms-colors.json").exists())

    def test_weekly_disabled_paused_and_per_monitor_rotation_are_untouched(self):
        variants = [
            {"wallhavenCarousel": dict(self.options, cadence="weekly")},
            {"wallhavenCarousel": dict(self.options, rotationEnabled=False)},
            {"wallhavenCarousel": dict(self.options, enabled=False)},
            {"wallhavenCarousel": self.options, "seaglassCanvas": {"preset": {"name": "oled"}}},
        ]
        for plugins in variants:
            wallpaper.write_json(wallpaper.DMS_CONFIG / "plugin_settings.json", plugins)
            self.activate()
            self.assertEqual(wallpaper.read_json(self.state_path, {})["rotation"]["session"], "previous-session")
        wallpaper.write_json(wallpaper.DMS_CONFIG / "plugin_settings.json", {"wallhavenCarousel": self.options})
        wallpaper.write_json(self.session_path, dict(wallpaperPath="previous.jpg", perMonitorWallpaper=True))
        self.activate()
        self.assertEqual(wallpaper.read_json(self.state_path, {})["rotation"]["session"], "previous-session")

    def test_preparation_isolates_outputs_and_disables_application_hooks(self):
        (wallpaper.CACHE / "startup.json").unlink()
        before = self.state_path.read_bytes(), self.session_path.read_bytes()

        def generate(command, **kwargs):
            if command[1:] == ["matugen", "check"]:
                return subprocess.CompletedProcess(command, 0, json.dumps([{"id": name} for name in ("gtk", "kitty", "qtengine")]))
            self.assertEqual(command[command.index("--value") + 1], str(self.image))
            self.assertIn("--run-user-templates=false", command)
            self.assertIn("--sync-mode-with-portal=false", command)
            self.assertEqual(command[-3:], ["gtk,kitty,qtengine", "--run-user-templates=false", "--sync-mode-with-portal=false"])
            staging = Path(command[-7])
            self.assertTrue(staging.is_relative_to(wallpaper.CACHE))
            wallpaper.write_json(staging / "dms-colors.json", self.colors)
            return subprocess.CompletedProcess(command, 0)

        args = dict(command="dms matugen generate --value previous.jpg --kind image --state-dir live --config-dir live --shell-dir shell --sync-mode-with-portal", options=self.options,
                    item=self.prepared["item"], rotation=self.prepared["rotation"], lastAt=123, intervalMs=86400000)
        with patch.object(wallpaper.subprocess, "run", side_effect=generate):
            wallpaper.prepare_startup(args)
        self.assertEqual((self.state_path.read_bytes(), self.session_path.read_bytes()), before)
        self.assertFalse((wallpaper.DMS_CACHE / "dms-colors.json").exists())
        self.assertEqual(wallpaper.read_json(wallpaper.CACHE / "startup.json", {})["colors"], self.colors)
        self.assertFalse(list(wallpaper.CACHE.glob("startup-*")))

    def test_failed_preparation_does_not_replace_a_ready_cache(self):
        before = (wallpaper.CACHE / "startup.json").read_bytes()
        with patch.object(wallpaper.subprocess, "run", side_effect=subprocess.TimeoutExpired("dms", 90)):
            with self.assertRaises(subprocess.TimeoutExpired):
                wallpaper.prepare_startup(dict(command="dms matugen generate --value old --kind image", options=self.options, item=self.prepared["item"]))
        self.assertEqual((wallpaper.CACHE / "startup.json").read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
