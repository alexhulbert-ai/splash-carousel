import io
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import wallpaper


class WallpaperTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.patchers = [patch.object(wallpaper, 'CONFIG', self.base / 'config'), patch.object(wallpaper, 'KEY', self.base / 'config/key'), patch.object(wallpaper, 'CACHE', self.base / 'cache')]
        for patcher in self.patchers:
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_key_is_private_and_never_echoed(self):
        result = wallpaper.run({'op': 'key-save', 'key': 'example-key'})
        self.assertEqual(result, {'configured': True})
        self.assertEqual(stat.S_IMODE(wallpaper.KEY.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(wallpaper.CONFIG.stat().st_mode), 0o700)
        self.assertEqual(wallpaper.run({'op': 'key-status'}), {'configured': True})
        with self.assertRaises(ValueError):
            wallpaper.run({'op': 'key-save', 'key': 'bad\nkey'})
        self.assertEqual(wallpaper.KEY.read_text().strip(), 'example-key')

    def test_import_copies_multiple_files_without_overwriting_and_is_idempotent(self):
        source = self.base / 'source'; source.mkdir()
        target = self.base / 'saved'; target.mkdir()
        (source / 'image one.jpg').write_bytes(b'first')
        (source / 'second.png').write_bytes(b'second')
        (target / 'image one.jpg').write_bytes(b'original')
        args = {'op': 'import', 'folder': str(target), 'paths': [(source / 'image one.jpg').as_uri(), str(source / 'second.png')]}
        self.assertEqual(wallpaper.run(args)['names'], ['image one-2.jpg', 'second.png'])
        self.assertEqual(wallpaper.run(args)['names'], ['image one-2.jpg', 'second.png'])
        self.assertEqual((target / 'image one.jpg').read_bytes(), b'original')
        self.assertTrue((source / 'image one.jpg').exists())
        self.assertFalse(list(target.glob('*.part')))

    def test_collection_urls_and_ids(self):
        for value in ['12345', 'ABC_-123', 'https://unsplash.com/collections/12345/my-photos?x=1']:
            self.assertEqual(wallpaper.collection_id(value), '12345' if '12345' in value else value)
        for value in ['https://example.com/collections/12345', '../private', '', 'a/b']:
            with self.assertRaises(ValueError):
                wallpaper.collection_id(value)

    def test_collection_url_search_returns_a_single_page_without_text_search(self):
        raw = {'id': '12345', 'title': 'Landscapes'}
        with patch.object(wallpaper, 'api', return_value=raw) as api:
            result = wallpaper.run({'op': 'search', 'kind': 'collections', 'query': ' https://unsplash.com/collections/12345/landscapes '})
        api.assert_called_once_with('collections/12345')
        self.assertEqual([item['collectionId'] for item in result['items']], ['12345'])
        self.assertEqual((result['lastPage'], result['total']), (1, 1))
        with patch.object(wallpaper, 'api') as api, self.assertRaises(ValueError):
            wallpaper.run({'op': 'search', 'kind': 'collections', 'query': 'https://example.com/collections/12345'})
        api.assert_not_called()

    def test_cache_protects_current_image_and_caps_total_at_twenty(self):
        wallpaper.CACHE.mkdir()
        files = []
        for index in range(25):
            path = wallpaper.CACHE / f'unsplash-{index}.jpg'
            path.write_bytes(b'image')
            os.utime(path, (index + 1, index + 1))
            files.append(path)
        wallpaper.write_json(wallpaper.CACHE / 'startup.json', {'item': {'path': str(files[1])}})
        wallpaper.run({'op': 'prune', 'protect': [str(files[0])]})
        self.assertTrue(files[0].exists())
        self.assertTrue(files[1].exists())
        self.assertEqual(len(list(wallpaper.CACHE.glob('*.jpg'))), 20)
        self.assertFalse(files[2].exists())

    def test_download_failure_leaves_no_partial_or_completed_image(self):
        item = {'photoId': 'id', 'full': 'https://images.unsplash.com/image'}
        with patch.object(wallpaper.urllib.request, 'urlopen', side_effect=urllib.error.URLError('offline')):
            with self.assertRaises(OSError):
                wallpaper.download(item, wallpaper.CACHE)
        self.assertEqual(list(wallpaper.CACHE.iterdir()), [])

    def test_saving_cached_photo_needs_no_image_download(self):
        wallpaper.CACHE.mkdir()
        (wallpaper.CACHE / 'unsplash-id.jpg').write_bytes(b'cached')
        with patch.object(wallpaper, 'api', return_value={}) as api, patch('colors.analyse', return_value=([], {'blue': 1})):
            result = wallpaper.download({'photoId': 'id'}, self.base / 'saved')
        self.assertEqual(Path(result['path']).read_bytes(), b'cached')
        self.assertEqual(result['palette'], {'blue': 1})
        api.assert_called_once_with('photos/id/download')

    def test_api_key_is_only_sent_to_api_host(self):
        wallpaper.run({'op': 'key-save', 'key': 'example-key'})
        response = io.BytesIO(b'{"results": []}')
        with patch.object(wallpaper.urllib.request, 'urlopen', return_value=response) as open_url:
            wallpaper.api('search/photos', {'query': 'landscape'})
        request = open_url.call_args.args[0]
        self.assertEqual(request.get_header('Authorization'), 'Client-ID example-key')
        self.assertNotIn('example-key', request.full_url)
        self.assertTrue(request.full_url.startswith('https://api.unsplash.com/'))

    def test_photo_normalization_keeps_keywords_attribution_and_stable_identity(self):
        raw = {'id': 'abc_-', 'width': 6000, 'height': 4000, 'urls': {'raw': 'https://images.unsplash.com/x?ixid=keep', 'full': 'https://images.unsplash.com/x', 'regular': 'https://images.unsplash.com/x?w=1080'}, 'user': {'name': 'Photographer', 'links': {'html': 'https://unsplash.com/@person'}}, 'tags': [{'title': 'green'}], 'alt_description': 'forest'}
        item = wallpaper.photo(raw)
        self.assertEqual(item['id'], 'unsplash:abc_-')
        self.assertEqual(item['tags'], ['green'])
        self.assertEqual(item['description'], 'forest')
        self.assertIn('ixid=keep', item['full'])
        self.assertIn('utm_source=', item['profile'])


if __name__ == '__main__':
    unittest.main()
