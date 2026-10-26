import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { test } from 'node:test';

const qml = readFileSync(new URL('../DiscoverView.qml', import.meta.url), 'utf8');

// Exercise the production functions with a fake model and process runner.
function discovery(overrides = {}) {
    const calls = [];
    const data = Array.from({ length: 12 }, (_, i) => ({ wid: String(i), fileName: `wallhaven-${i}.jpg`, full: `https://w.wallhaven.cc/${i}.jpg` }));
    const state = {
        hub: { apiKey: '', previewDir: '/cache/preview', previewScript: '/plugin/preview-cache.sh', userAgent: 'test-agent' },
        api: 'https://wallhaven.cc/api/v1', query: '', categories: '111', purity: '111', sorting: 'toplist', topRange: '1M', atleast: '', seed: '',
        previewing: true, grid: { currentIndex: 0 }, results: { count: data.length, get: i => data[i] },
        cachedFull: {}, fetchingFull: {}, failedFull: {}, previewQueue: [], cacheMinutes: 30,
        Proc: { runCommand: (...args) => calls.push(args) },
        I18n: { trFor: (_id, text) => text },
        ...overrides,
    };
    state.view = state;
    vm.createContext(state);
    for (const match of qml.matchAll(/^    function (\w+)\(([^)]*)\) \{\n([\s\S]*?)^    \}/gm)) {
        vm.runInContext(`function ${match[1]}(${match[2]}) {\n${match[3]}\n}`, state);
    }
    return { state, calls };
}

test('no key keeps SFW; all seven toplist periods reach the API URL', () => {
    const { state } = discovery();
    for (const period of ['1d', '3d', '1w', '1M', '3M', '6M', '1y']) {
        state.topRange = period;
        const url = new URL(state.url(1));
        assert.equal(url.searchParams.get('purity'), '100');
        assert.equal(url.searchParams.get('topRange'), period);
        assert.equal(url.searchParams.has('apikey'), false);
    }
    state.hub.apiKey = 'fake-test-key';
    state.purity = '010';
    assert.equal(new URL(state.url(2)).searchParams.get('purity'), '010');
    assert.equal(state.explain('HTTP 401'), 'Wallhaven rejected the API key. Check it in the plugin settings.');
});

test('fast navigation keeps at most three active downloads and replaces queued neighbors', () => {
    const { state, calls } = discovery();
    state.prefetchAround();
    assert.equal(calls.length, 2);
    state.grid.currentIndex = 3;
    state.prefetchAround();
    assert.equal(calls.length, 3);
    state.grid.currentIndex = 9;
    state.prefetchAround();
    assert.equal(calls.length, 3);
    assert.equal(Object.keys(state.fetchingFull).length, 3);
    calls[0][2]('', 0);
    assert.equal(calls.length, 4);
    assert.equal(calls[3][0], 'wallhavenCarousel.preview.9');
    assert.equal(Object.keys(state.fetchingFull).length, 3);
    state.previewing = false;
    state.prefetchAround();
    calls[1][2]('', 0);
    assert.equal(calls.length, 4);
});

test('failed previews are not cached and can be retried', () => {
    const { state, calls } = discovery({ previewing: false });
    state.fetchFull(2);
    calls[0][2]('', 1);
    assert.equal(state.failedFull['2'], true);
    assert.equal(state.cachedFull['2'], undefined);
    assert.equal(state.fetchingFull['2'], undefined);
    state.fetchFull(2);
    assert.equal(state.failedFull['2'], undefined);
    calls[1][2]('', 0);
    assert.equal(state.isCached('2'), true);
    assert.equal(state.fullSource(state.results.get(2)), 'file:///cache/preview/wallhaven-2.jpg');
});

test('collection covers do not enter the photo preview cache', () => {
    const { state, calls } = discovery({
        results: { count: 1, get: () => ({ isCollection: true, fileName: '' }) },
    });
    state.prefetchAround();
    assert.equal(calls.length, 0);
});
