#include <metal_stdlib>
using namespace metal;

// ============================================================================
// Кастомные переходы (Metal-кернелы):
//   door / grid / colorFade
//
// Все кернелы принимают: исходное изображение (из него выходим),
// целевое изображение (в него переходим), параметр t (0...1),
// и возвращают смешанный кадр.
// ============================================================================

// Размер текстуры для нормализации координат.
constant float2 inline_texSize = float2(1.0);

// Глобальный сэмплер для выборки текстур в кернелах.
constexpr sampler s = sampler(coord::normalized, address::clamp_to_edge, filter::linear);

// --- Вспомогательные утилиты ------------------------------------------------

float2 uvForId(uint2 gid, texture2d<float> tex) {
    return float2(float(gid.x) + 0.5, float(gid.y) + 0.5) / float2(tex.get_width(), tex.get_height());
}

float easeInOutCubic(float t) {
    t = clamp(t, 0.0, 1.0);
    return t < 0.5 ? 4.0 * t * t * t : 1.0 - pow(-2.0 * t + 2.0, 3.0) / 2.0;
}

float4 sampleSource(texture2d<float> from, sampler s, float2 uv, float scale, float2 center) {
    float2 scaled = (uv - center) * scale + center;
    if (scaled.x < 0.0 || scaled.x > 1.0 || scaled.y < 0.0 || scaled.y > 1.0) {
        return float4(0.0);
    }
    return from.sample(s, scaled);
}

// --- Дверь (door) -------------------------------------------------------------

kernel void door(
    texture2d<float, access::sample> from [[texture(0)]],
    texture2d<float, access::sample> to   [[texture(1)]],
    texture2d<float, access::write>  out  [[texture(2)]],
    constant float& progress [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    float2 uv = uvForId(gid, from);
    float t = easeInOutCubic(progress);
    // Двустворчатые двери: створки — половины ИСХОДНОГО кадра — строго
    // параллельно расходятся от центра к краям (rigid, без сжатия), в
    // образовавшемся проёме виден целевой кадр. Растяжения картинки нет:
    // лица на исходном слайде не деформируются.
    float travel = t * 0.5; // 0 → двери закрыты, 0.5 → полностью открыты
    if (uv.x <= 0.5 - travel) {
        // Левая створка ушла влево: показываем её исходное содержимое.
        out.write(from.sample(s, float2(uv.x + travel, uv.y)), gid);
        return;
    }
    if (uv.x >= 0.5 + travel) {
        // Правая створка ушла вправо.
        out.write(from.sample(s, float2(uv.x - travel, uv.y)), gid);
        return;
    }
    // Центральный проём — целевой кадр.
    out.write(to.sample(s, uv), gid);
}

// --- Сетка (grid) ------------------------------------------------------------

kernel void gridTransition(
    texture2d<float, access::sample> from [[texture(0)]],
    texture2d<float, access::sample> to   [[texture(1)]],
    texture2d<float, access::write>  out  [[texture(2)]],
    constant float& progress [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    float2 uv = uvForId(gid, from);
    float t = easeInOutCubic(progress);
    // Прямоугольная сетка 4×3: ячейки открываются детерминированно по времени.
    float2 gridCount = float2(4.0, 3.0);
    float2 cell = floor(uv * gridCount);
    float cellID = cell.y * gridCount.x + cell.x;
    float totalCells = gridCount.x * gridCount.y;
    // Детерминированное «раскрытие»: ячейки открываются последовательно
    // на основе их id и простого хеша.
    float order = fract(sin(cellID * 12.9898) * 43758.5453); // 0...1
    float threshold = t;
    float delay = order * 0.2; // каждая ячейка открывается в своё окно.
    float localProgress = clamp((t - delay) / (1.0 - 0.0), 0.0, 1.0);
    // Смешивание: если t ещё не дошло до этой ячейки — показываем исходный.
    if (t < delay) {
        out.write(from.sample(s, uv), gid);
        return;
    }
    // Иначе — плавный переход внутри ячейки.
    float2 cellUV = fract(uv * gridCount);
    float centerDist = length(cellUV - 0.5);
    float alpha = smoothstep(0.5, 0.0, centerDist) * localProgress;
    float4 a = from.sample(s, uv);
    float4 b = to.sample(s, uv);
    out.write(mix(a, b, alpha), gid);
}

// --- Цветной fade (colorFade) -------------------------------------------------

kernel void colorFade(
    texture2d<float, access::sample> from [[texture(0)]],
    texture2d<float, access::sample> to   [[texture(1)]],
    texture2d<float, access::write>  out  [[texture(2)]],
    constant float& progress [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    float2 uv = uvForId(gid, from);
    float t = easeInOutCubic(progress);
    // Белая заливка (v1: фиксированный цвет).
    float4 white = float4(1.0);
    float4 a = from.sample(s, uv);
    float4 b = to.sample(s, uv);
    // Фаза 1 (0...0.5): исходный кадр → белый.
    // Фаза 2 (0.5...1): белый → целевой кадр.
    float4 color;
    if (t < 0.5) {
        color = mix(a, white, t * 2.0);
    } else {
        color = mix(white, b, (t - 0.5) * 2.0);
    }
    out.write(color, gid);
}