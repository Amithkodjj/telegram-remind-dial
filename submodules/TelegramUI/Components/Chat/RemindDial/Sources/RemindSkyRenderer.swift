import Foundation
import Metal
import QuartzCore
import simd

struct RemindSkyUniforms {
    var resolution: SIMD2<Float>
    var center: SIMD2<Float>
    var knob: SIMD2<Float>
    var time: Float
    var hour: Float
    var spin: Float
    var speed: Float
    var knobRadius: Float
    var padding: Float = 0.0
}

final class RemindSkyRenderer {
    let device: MTLDevice

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    private static var shared: RemindSkyRenderer?
    private static var waiting: [(RemindSkyRenderer) -> Void] = []
    private static var isLoading = false

    static func load(_ completion: @escaping (RemindSkyRenderer) -> Void) {
        if let shared = RemindSkyRenderer.shared {
            completion(shared)
            return
        }
        RemindSkyRenderer.waiting.append(completion)
        if RemindSkyRenderer.isLoading {
            return
        }
        RemindSkyRenderer.isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let renderer = RemindSkyRenderer()
            DispatchQueue.main.async {
                RemindSkyRenderer.shared = renderer
                RemindSkyRenderer.isLoading = false
                let callbacks = RemindSkyRenderer.waiting
                RemindSkyRenderer.waiting = []
                if let renderer {
                    callbacks.forEach { $0(renderer) }
                }
            }
        }
    }

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(), let library = try? device.makeLibrary(source: remindSkyShaders, options: nil) else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "skyVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "skyFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
    }

    func draw(layer: CAMetalLayer, uniforms: RemindSkyUniforms) {
        guard let drawable = layer.nextDrawable(), let commandBuffer = self.queue.makeCommandBuffer() else {
            return
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return
        }
        var values = uniforms
        encoder.setRenderPipelineState(self.pipeline)
        encoder.setFragmentBytes(&values, length: MemoryLayout<RemindSkyUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

private let remindSkyShaders = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 resolution;
    float2 center;
    float2 knob;
    float time;
    float hour;
    float spin;
    float speed;
    float knobRadius;
    float padding;
};

struct Varyings {
    float4 position [[position]];
};

vertex Varyings skyVertex(uint id [[vertex_id]]) {
    float2 p = float2(float((id << 1) & 2), float(id & 2));
    Varyings out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1.0, 0.0)), f.x), mix(hash21(i + float2(0.0, 1.0)), hash21(i + float2(1.0, 1.0)), f.x), f.y);
}

static float fbm(float2 p, int octaves) {
    float amplitude = 0.5;
    float sum = 0.0;
    float2x2 turn = float2x2(float2(1.6, 1.2), float2(-1.2, 1.6));
    for (int i = 0; i < octaves; i++) {
        sum += amplitude * noise(p);
        p = turn * p;
        amplitude *= 0.5;
    }
    return sum;
}

static float3 stars(float2 p, float time, float spin, float speed) {
    float3 result = float3(0.0);
    float travel = time * 0.018 + spin * 0.75;
    for (int i = 0; i < 6; i++) {
        float raw = float(i) / 6.0 + travel;
        float phase = fract(raw);
        float seed = floor(raw) + float(i) * 11.0;
        float scale = mix(26.0, 2.2, phase * phase);
        float fade = smoothstep(0.0, 0.25, phase) * smoothstep(1.0, 0.75, phase);
        float2 q = p * scale;
        float2 cell = floor(q);
        float2 local = fract(q) - 0.5;
        float h = hash21(cell + seed);
        if (h < 0.34) {
            continue;
        }
        float2 offset = float2(hash21(cell + seed + 3.1), hash21(cell + seed + 7.7)) - 0.5;
        float2 d = local - offset * 0.7;
        float2 radial = normalize((cell + 0.5 + offset) / scale + float2(0.0001));
        float along = dot(d, radial);
        float across = dot(d, float2(-radial.y, radial.x));
        float stretch = 1.0 + speed * 26.0 * phase;
        float distance = length(float2(along / stretch, across));
        float size = mix(0.018, 0.075, pow(h, 7.0)) * (0.5 + phase);
        float twinkle = 0.65 + 0.35 * sin(time * (2.0 + h * 5.0) + h * 40.0);
        float point = smoothstep(size * 2.2, 0.0, distance);
        float3 tint = mix(float3(0.72, 0.84, 1.0), float3(1.0, 0.86, 0.68), fract(h * 37.0));
        result += tint * point * point * fade * twinkle * (1.0 + speed * 2.5) * 1.5;
    }
    return result;
}

fragment float4 skyFragment(Varyings in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float2 uv = in.position.xy / u.resolution;
    float2 p = (in.position.xy - u.center) / u.resolution.x * 2.0;
    p.y = -p.y;
    float2 light = (u.knob - u.center) / u.resolution.x * 2.0;
    light.y = -light.y;
    float t = u.time;
    float height = 1.0 - uv.y;

    float sunAngle = u.hour / 24.0 * 6.2831853;
    float elevation = -cos(sunAngle);
    float day = smoothstep(-0.1, 0.32, elevation);
    float golden = exp(-(elevation * elevation) / 0.07);
    float isEvening = smoothstep(11.0, 13.0, u.hour);

    float3 zenith = mix(float3(0.008, 0.016, 0.075), float3(0.03, 0.27, 0.82), day);
    float3 horizon = mix(float3(0.05, 0.075, 0.24), float3(0.56, 0.84, 1.0), day);
    float3 goldZenith = mix(float3(0.2, 0.22, 0.6), float3(0.28, 0.13, 0.5), isEvening);
    float3 goldHorizon = mix(float3(1.0, 0.56, 0.42), float3(1.0, 0.36, 0.2), isEvening);
    zenith = mix(zenith, goldZenith, golden * 0.8);
    horizon = mix(horizon, goldHorizon, golden);

    float3 sunColor = mix(float3(1.0, 0.95, 0.78), float3(1.0, 0.56, 0.24), golden);
    float3 moonColor = float3(0.62, 0.74, 1.0);
    float3 glowColor = mix(moonColor, sunColor, day);

    float3 color = mix(horizon, zenith, pow(clamp(height, 0.0, 1.0), 0.72));
    if (golden > 0.02) {
        float band = exp(-pow((height - 0.3) * 4.5, 2.0));
        color = mix(color, mix(float3(1.0, 0.44, 0.58), float3(1.0, 0.3, 0.46), isEvening), band * golden * 0.55);
    }

    if (day < 0.98) {
        float night = 1.0 - day;
        float2 axis = normalize(float2(0.55, 1.0));
        float across = dot(p, float2(-axis.y, axis.x));
        float band = exp(-pow(across * 1.7, 2.0));
        float2 flow = p * (1.0 - fract(t * 0.004 + u.spin * 0.12) * 0.4);
        float warp = fbm(flow * 1.6 + float2(t * 0.012, 0.0), 4);
        float dust = fbm(flow * 2.4 + warp * 1.7, 5);
        float3 nebula = mix(float3(0.42, 0.14, 0.78), float3(0.04, 0.55, 0.72), smoothstep(0.3, 0.72, warp));
        color += nebula * pow(dust, 2.6) * (0.5 + band * 1.9) * night * 0.95;
        color += float3(0.74, 0.76, 1.0) * pow(fbm(flow * 9.0, 4), 5.0) * band * night * 1.7;
        color += stars(p, t, u.spin, u.speed) * night;

        float curtain = fbm(float2(p.x * 2.2 + t * 0.06 + u.spin * 0.5, t * 0.05), 4);
        float ribbon = smoothstep(0.72, 0.0, abs(p.y - 0.95 - curtain * 0.5)) * smoothstep(0.25, 0.7, curtain);
        color += mix(float3(0.1, 0.9, 0.55), float3(0.5, 0.25, 0.95), clamp((p.y - 0.7) * 0.9, 0.0, 1.0)) * ribbon * night * 0.34;
    }

    float2 toKnob = p - light;
    float knobDistance = length(toKnob);
    color += glowColor * (mix(0.2, 0.46, day) / (1.0 + knobDistance * knobDistance * 11.0));
    color += glowColor * (0.012 / (knobDistance * knobDistance + 0.012)) * mix(0.3, 0.8, day);

    float angle = atan2(toKnob.y, toKnob.x);
    float rayPattern = pow(0.5 + 0.5 * sin(angle * 9.0 + u.spin * 5.0 + t * 0.12), 7.0) + 0.65 * pow(0.5 + 0.5 * sin(angle * 23.0 - u.spin * 8.0 - t * 0.19), 13.0);
    color += sunColor * rayPattern * (0.3 / (1.0 + knobDistance * 3.4)) * day;

    float zoom = t * 0.011 + u.spin * 0.6;
    float cover = mix(0.5, 1.0, day);
    float3 shadowTone = mix(float3(0.035, 0.05, 0.14), float3(0.54, 0.65, 0.84), day);
    float3 litTone = mix(float3(0.26, 0.31, 0.5), float3(1.0, 1.0, 0.97), day);
    shadowTone = mix(shadowTone, mix(float3(0.42, 0.26, 0.56), float3(0.42, 0.14, 0.34), isEvening), golden * 0.9);
    litTone = mix(litTone, mix(float3(1.0, 0.76, 0.6), float3(1.0, 0.58, 0.32), isEvening), golden * 0.95);
    for (int i = 0; i < 3; i++) {
        float raw = float(i) / 3.0 + zoom;
        float phase = fract(raw);
        float seed = floor(raw) * 3.7 + float(i) * 9.1;
        float scale = mix(3.2, 0.72, phase);
        float weight = sin(phase * 3.14159);
        float2 q = p * scale + float2(seed, seed * 0.6) + float2(t * 0.012, t * 0.004);
        float warp = fbm(q * 0.9, 3);
        float density = fbm(q + warp * 0.8, 5);
        float alpha = smoothstep(0.42, 0.74, density) * weight * cover;
        if (alpha > 0.002) {
            float2 towards = normalize(light - p + float2(0.0001));
            float behind = fbm(q + warp * 0.8 + towards * 0.16, 4);
            float lit = clamp((density - behind) * 4.2 + 0.55, 0.0, 1.0);
            float3 cloud = mix(shadowTone, litTone, lit);
            cloud += glowColor * (0.3 / (1.0 + knobDistance * knobDistance * 7.0)) * lit;
            color = mix(color, cloud, alpha * 0.93);
        }
    }

    float pixel = 1.5 / u.resolution.y;
    float3 farTone = mix(color, mix(float3(0.03, 0.05, 0.14), float3(0.33, 0.5, 0.7), day), 0.75);
    farTone = mix(farTone, float3(0.42, 0.18, 0.36), golden * 0.7);
    for (int k = 0; k < 3; k++) {
        float layer = float(k);
        float x = uv.x * (1.7 + layer * 1.5) + u.spin * (0.1 + layer * 0.13) + layer * 13.0;
        float ridge = 0.23 - layer * 0.062 + 0.085 * fbm(float2(x, layer * 5.0), 5);
        float inside = smoothstep(ridge + pixel, ridge - pixel, height);
        float3 tone = mix(farTone, float3(0.01, 0.015, 0.04) + day * float3(0.03, 0.06, 0.08), 0.34 + layer * 0.31);
        if (k == 2 && day < 0.7) {
            float2 grid = float2(uv.x * 62.0, height * 110.0);
            float2 cell = floor(grid);
            float2 inner = fract(grid) - 0.5;
            float on = step(0.9, hash21(cell + 4.0));
            float glow = smoothstep(0.34, 0.0, length(inner)) * on * (1.0 - day) * smoothstep(ridge, ridge - 0.02, height);
            tone += float3(1.0, 0.72, 0.36) * glow * (0.7 + 0.3 * sin(t * 2.0 + cell.x));
        }
        color = mix(color, tone, inside);
    }

    if (knobDistance < u.knobRadius * 1.06) {
        float2 q = toKnob / u.knobRadius;
        float r2 = dot(q, q);
        float z = sqrt(max(1.0 - r2, 0.0));
        float3 normal = float3(q, z);

        float granules = fbm(q * 5.5 / (0.6 + z * 0.8) + float2(t * 0.16, -t * 0.08), 4);
        float3 sunBody = mix(float3(1.0, 0.86, 0.48), float3(1.0, 1.0, 0.97), smoothstep(0.0, 0.72, z));
        sunBody = mix(sunBody, float3(1.0, 0.62, 0.3), golden * 0.55);
        sunBody += (granules - 0.5) * float3(0.03, 0.05, 0.08);
        sunBody *= 1.12;

        float3 lightDirection = normalize(float3(-0.55, 0.42, 0.72));
        float lambert = max(dot(normal, lightDirection), 0.0);
        float2 surface = q * 2.5 / (0.5 + z * 0.9) + float2(u.spin * 0.7, 0.0) + 3.0;
        float maria = smoothstep(0.42, 0.62, fbm(surface * 0.9, 4));
        float craters = fbm(surface * 3.4, 4);
        float3 moonBody = mix(float3(0.9, 0.91, 0.98), float3(0.48, 0.5, 0.6), maria * 0.85) * (0.78 + craters * 0.42);
        moonBody = moonBody * (0.06 + lambert * 1.18) + float3(0.04, 0.07, 0.16) * (1.0 - lambert);

        float3 body = mix(moonBody, sunBody, smoothstep(0.1, 0.45, day));
        float edge = smoothstep(1.04, 0.97, sqrt(r2));
        color = mix(color, body, edge);
    }

    color *= 1.0 - 0.1 * dot(p, p);
    color = pow(clamp(color, 0.0, 1.0), float3(0.94));
    color += (hash21(in.position.xy + fract(t)) - 0.5) / 180.0;
    return float4(color, 1.0);
}
"""
