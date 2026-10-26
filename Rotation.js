.pragma library

function words(value) {
    return String(value || "").normalize("NFKC").toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();
}

function blocked(item, blacklist) {
    const fields = [item.fileName, item.description, item.title, item.category].concat(item.tags || []);
    const text = fields.map(value => " " + words(value) + " ");
    return String(blacklist || "").split(/[\n,]/).map(words).filter(Boolean).find(term => text.some(field => field.includes(" " + term + " "))) || "";
}

function palette(hex) {
    const match = /^#?([a-f\d]{6})$/i.exec(hex || "");
    if (!match)
        return {};
    const rgb = [0, 2, 4].map(i => parseInt(match[1].slice(i, i + 2), 16) / 255);
    const high = Math.max(...rgb), low = Math.min(...rgb), delta = high - low;
    let hue = 0;
    if (delta) {
        const index = rgb.indexOf(high);
        hue = ((rgb[(index + 1) % 3] - rgb[(index + 2) % 3]) / delta + index * 2 + 6) % 6 * 60;
    }
    const bounds = [[15, "red"], [45, "orange"], [70, "yellow"], [165, "green"], [200, "teal"], [255, "blue"], [300, "purple"], [345, "pink"], [361, "red"]];
    const key = high < 0.2 ? "dark" : delta / (high || 1) < 0.15 ? (high > 0.8 ? "light" : "gray") : bounds.find(bound => hue < bound[0])[1];
    return {[key]: 1};
}

function choose(pool, previous, current, recent, variety, random) {
    const unique = pool.filter((item, index) => pool.findIndex(other => other.id === item.id) === index);
    const ids = unique.map(item => item.id);
    const known = previous?.known || [];
    let remaining = (previous?.remaining || []).filter(id => ids.includes(id));
    remaining = remaining.concat(ids.filter(id => !known.includes(id) && !remaining.includes(id)));
    if (!remaining.length)
        remaining = ids.slice();
    let candidates = unique.filter(item => item.id !== current && remaining.includes(item.id));
    if (!candidates.length && ids.length > 1) {
        remaining = ids.slice();
        candidates = unique.filter(item => item.id !== current);
    }
    const recentIds = (recent || []).slice(0, Math.min(3, ids.length - 1)).map(item => item.id);
    const fresh = candidates.filter(item => !recentIds.includes(item.id));
    if (fresh.length)
        candidates = fresh;
    let best = Infinity, choices = [];
    for (const item of candidates) {
        let score = 0;
        if (variety) {
            for (const shown of (recent || []).slice(0, 3)) {
                for (const key of Object.keys(item.palette || {}))
                    score += item.palette[key] * (shown.palette?.[key] || 0);
            }
        }
        if (score < best - 0.000001) {
            best = score;
            choices = [item];
        } else if (Math.abs(score - best) < 0.000001) {
            choices.push(item);
        }
    }
    const item = choices.length ? choices[Math.floor((random || Math.random)() * choices.length)] : null;
    return {item: item, bag: {known: ids, remaining: remaining.filter(id => id !== item?.id)}};
}

function due(state, cadence, intervalMs, session, now) {
    if (cadence === "session")
        return !!session && state.session !== session;
    return now >= (state.nextAt || (state.lastAt ? state.lastAt + intervalMs : 0));
}

function interval(value, unit) {
    const amount = Number(value);
    return Math.max(1, Math.min(36500, Number.isFinite(amount) ? amount : 1)) * ({minutes: 60000, hours: 3600000, days: 86400000}[unit] || 86400000);
}
