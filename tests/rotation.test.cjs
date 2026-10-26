const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const rotation = vm.createContext({});
vm.runInContext(fs.readFileSync(path.join(__dirname, '../Rotation.js'), 'utf8').replace(/^\.pragma library\s*/, ''), rotation);
const pool = [
    {id: 'green1', palette: {green: 1}},
    {id: 'green2', palette: {green: 1}},
    {id: 'brown', palette: {orange: 1}},
    {id: 'blue', palette: {blue: 1}},
    {id: 'pink', palette: {pink: 1}},
];

test('every saved image gets one turn in each persisted round', () => {
    let bag, current = '', recent = [];
    for (let round = 0; round < 5; round++) {
        const shown = [];
        for (let index = 0; index < pool.length; index++) {
            const choice = rotation.choose(pool, bag, current, recent, true, () => 0);
            assert.ok(choice.item);
            assert.notEqual(choice.item.id, current);
            shown.push(choice.item.id);
            current = choice.item.id;
            bag = JSON.parse(JSON.stringify(choice.bag));
            recent = [choice.item, ...recent].slice(0, 100);
        }
        assert.equal(new Set(shown).size, pool.length);
    }
});

test('color variety avoids the recent green and brown palettes', () => {
    const choice = rotation.choose(pool, null, 'green1', [pool[0], pool[2]], true, () => 0);
    assert.equal(choice.item.id, 'blue');
});

test('adding and removing files preserves turns remaining in the round', () => {
    const bag = {known: ['gone', 'green1', 'blue'], remaining: ['gone', 'blue']};
    const choice = rotation.choose([pool[0], pool[3], pool[4]], bag, 'green1', [], false, () => 0);
    assert.equal(choice.item.id, 'blue');
    assert.deepEqual(Array.from(choice.bag.remaining), ['pink']);
});

test('empty and single-current pools retain the wallpaper', () => {
    assert.equal(rotation.choose([], null, '', [], true).item, null);
    assert.equal(rotation.choose([pool[0]], null, 'green1', [], true).item, null);
});

test('two images alternate and duplicate source IDs do not get extra turns', () => {
    let bag, current = '';
    const items = [pool[0], pool[3], pool[0]];
    for (let index = 0; index < 10; index++) {
        const choice = rotation.choose(items, bag, current, [], true, () => 0);
        assert.equal(choice.item.id, index % 2 ? 'blue' : 'green1');
        bag = choice.bag;
        current = choice.item.id;
    }
});

test('keywords match whole words and phrases with Unicode normalization', () => {
    assert.equal(rotation.blocked({fileName: 'cathedral.png'}, 'cat'), '');
    assert.equal(rotation.blocked({fileName: 'A-CAR.jpg'}, 'car'), 'car');
    assert.equal(rotation.blocked({description: 'Text-overlay photo'}, 'text overlay'), 'text overlay');
    assert.equal(rotation.blocked({tags: ['CAFÉ']}, 'cafe\u0301'), 'café');
});

test('a seven-day deadline survives reloads and sessions do not advance on restarts', () => {
    const week = rotation.interval(7, 'days');
    const state = JSON.parse(JSON.stringify({lastAt: 1000, nextAt: 1000 + week, session: 'boot:desktop'}));
    assert.equal(rotation.due(state, 'interval', week, 'boot:desktop', 1000 + week - 1), false);
    assert.equal(rotation.due(state, 'interval', week, 'boot:desktop', 1000 + week), true);
    assert.equal(rotation.due(state, 'session', week, 'boot:desktop', 1000 + week), false);
    assert.equal(rotation.due(state, 'session', week, 'boot:new-desktop', 1000), true);
    assert.equal(rotation.due(state, 'session', week, '', 1000), false);
    assert.ok(rotation.interval(36500, 'days') > 2147483647);
});

test('palette hints classify green, brown, blue and neutral colors', () => {
    for (const [hex, key] of [['#00ff00', 'green'], ['#805020', 'orange'], ['#0022ff', 'blue'], ['#ffffff', 'light'], ['#111111', 'dark']])
        assert.equal(rotation.palette(hex)[key], 1);
});
