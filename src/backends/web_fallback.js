// Fetches the Noto fonts picked by opentype's web_fallback (see Font.Cache.web_fallback).

const max_attempts = 3;
const retry_delay_ms = 1000;

/** @param {number} status */
function isPermanentStatus(status) {
    return status >= 400 && status < 500 && status !== 408 && status !== 429;
}

/**
 * @param {string} url
 * @returns {Promise<Uint8Array>}
 */
async function fetchWithRetries(url) {
    for (let attempt = 1; ; attempt++) {
        let response;
        try {
            response = await fetch(url);
        } catch (err) {
            if (attempt >= max_attempts) throw err;
        }
        if (response) {
            if (response.ok) return new Uint8Array(await response.arrayBuffer());
            if (isPermanentStatus(response.status) || attempt >= max_attempts) {
                throw new Error(`HTTP ${response.status}`);
            }
        }
        await new Promise((resolve) => setTimeout(resolve, retry_delay_ms));
    }
}

/**
 * @param {import("./web.js").Dvui} dvui
 * @param {number} font
 * @param {string} url
 */
export function fetchFallbackFont(dvui, font, url) {
    const exports = dvui.instance.exports;
    fetchWithRetries(url).then(
        (bytes) => exports.dvui_font_fallback_loaded(font, dvui.allocBuffer(exports.gpa_u8, bytes), bytes.length),
        (err) => {
            console.warn(`font fallback: ${url} unavailable: ${err}`);
            exports.dvui_font_fallback_failed(font);
        },
    ).finally(() => dvui.requestRender());
}
