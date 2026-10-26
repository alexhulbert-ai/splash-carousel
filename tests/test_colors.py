import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import colors


@unittest.skipUnless(colors.MAGICK, 'ImageMagick is required')
class ColorTests(unittest.TestCase):
    def test_histograms_follow_actual_pixels_and_legacy_cache_is_upgraded(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            images = base / 'images'; images.mkdir()
            image = images / 'green.png'
            subprocess.run(colors.MAGICK + ['-size', '16x16', 'xc:#00ff00', str(image)], check=True)
            cache = base / 'colors.json'
            cache.write_text(json.dumps({'green.png': {'m': image.stat().st_mtime_ns, 'c': ['orange']}}))
            script = str(Path(colors.__file__))
            first = json.loads(subprocess.check_output([sys.executable, script, str(images), str(cache)]))
            self.assertEqual(first['colors']['green.png'], ['green'])
            self.assertEqual(first['palettes']['green.png'], {'green': 1.0})
            second = json.loads(subprocess.check_output([sys.executable, script, str(images), str(cache)]))
            self.assertEqual(first, second)
            self.assertFalse((base / 'colors.json.tmp').exists())
            image.unlink()
            empty = json.loads(subprocess.check_output([sys.executable, script, str(images), str(cache)]))
            self.assertEqual(empty, {'colors': {}, 'palettes': {}})

    def test_mixed_image_has_a_normalized_palette(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / 'mixed.png'
            subprocess.run(colors.MAGICK + ['-size', '16x16', 'xc:#0022ff', '-fill', '#ff0000', '-draw', 'rectangle 0,0 7,15', str(image)], check=True)
            _, histogram = colors.analyse(str(image))
            self.assertAlmostEqual(sum(histogram.values()), 1.0)
            self.assertAlmostEqual(histogram['red'], 0.5, delta=0.05)
            self.assertAlmostEqual(histogram['blue'], 0.5, delta=0.05)


if __name__ == '__main__':
    unittest.main()
