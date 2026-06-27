// supertoroid-metal.swift
// Supertoroid renderer — Swift + Metal (MetalKit / MTKView), macOS.
//
// A Metal rewrite of the OpenGL version. Shares the same CPU-side math and mesh,
// but uses MSL shaders, a render pipeline, and Metal's [0, 1] clip-space depth.
//
// Build (single file, no Xcode project):
//   swiftc supertoroid-metal.swift -o supertoroid-metal \
//          -framework Cocoa -framework Metal -framework MetalKit
//   ./supertoroid-metal
//
// Controls:
//   Mouse drag — rotate
//   Scroll     — zoom
//   N / M      — exponent n
//   T / Y      — twist
//   R          — reset
//   F          — fullscreen
//   ESC        — quit

import Cocoa
import MetalKit
import simd

// ============================================================
// MARK: - Math (column-major Float 4x4, same convention as the GL version)
// ============================================================

struct Mat4 {
    var m = [Float](repeating: 0, count: 16)
    static func identity() -> Mat4 {
        var r = Mat4(); r.m[0] = 1; r.m[5] = 1; r.m[10] = 1; r.m[15] = 1; return r
    }
}

// Standard column-major multiply: result = a * b
func mat4Mul(_ a: Mat4, _ b: Mat4) -> Mat4 {
    var r = Mat4()
    for col in 0..<4 {
        for row in 0..<4 {
            var s: Float = 0
            for k in 0..<4 { s += a.m[k * 4 + row] * b.m[col * 4 + k] }
            r.m[col * 4 + row] = s
        }
    }
    return r
}

// Metal perspective: clip-space z maps to [0, 1] (near -> 0, far -> 1).
// This is the key difference from the OpenGL matrix, which maps to [-1, 1].
func mat4PerspectiveMetal(_ fovY: Float, _ aspect: Float, _ zNear: Float, _ zFar: Float) -> Mat4 {
    let f = 1.0 / tanf(fovY * 0.5)
    var r = Mat4()
    r.m[0]  = f / aspect
    r.m[5]  = f
    r.m[10] = zFar / (zNear - zFar)
    r.m[11] = -1.0
    r.m[14] = (zFar * zNear) / (zNear - zFar)
    return r
}

func mat4RotX(_ a: Float) -> Mat4 {
    var r = Mat4.identity()
    r.m[5] = cosf(a);  r.m[6]  = sinf(a)
    r.m[9] = -sinf(a); r.m[10] = cosf(a)
    return r
}

func mat4RotY(_ a: Float) -> Mat4 {
    var r = Mat4.identity()
    r.m[0] = cosf(a); r.m[2]  = -sinf(a)
    r.m[8] = sinf(a); r.m[10] = cosf(a)
    return r
}

func mat4Translate(_ x: Float, _ y: Float, _ z: Float) -> Mat4 {
    var r = Mat4.identity()
    r.m[12] = x; r.m[13] = y; r.m[14] = z
    return r
}

// Convert our column-major [Float] matrix into a simd_float4x4 (also column-major),
// so the layout matches what MSL expects in the uniform buffer.
func toSimd(_ a: Mat4) -> simd_float4x4 {
    return simd_float4x4(columns: (
        SIMD4<Float>(a.m[0],  a.m[1],  a.m[2],  a.m[3]),
        SIMD4<Float>(a.m[4],  a.m[5],  a.m[6],  a.m[7]),
        SIMD4<Float>(a.m[8],  a.m[9],  a.m[10], a.m[11]),
        SIMD4<Float>(a.m[12], a.m[13], a.m[14], a.m[15])
    ))
}

// ============================================================
// MARK: - Uniforms (memory layout MUST match the MSL `Uniforms` struct)
// ============================================================

struct Uniforms {
    var mvp: simd_float4x4
    var model: simd_float4x4
    var normalMat: simd_float4x4
    var lightDir: SIMD3<Float>   // 16-byte aligned, like MSL float3
    var time: Float
}

// ============================================================
// MARK: - Supertoroid mesh (interleaved: pos3, normal3, uv2 = 8 floats / 32 bytes)
// ============================================================

func buildSupertoroid(n: Float, twist: Float, a: Float, Nu: Int, Nv: Int)
    -> (verts: [Float], indices: [UInt32])
{
    var verts = [Float](); verts.reserveCapacity((Nu + 1) * (Nv + 1) * 8)
    var indices = [UInt32](); indices.reserveCapacity(Nu * Nv * 6)

    let invN: Float = 1.0 / n
    let pi2: Float = 2.0 * Float.pi

    func pos(_ u: Float, _ v: Float) -> (Float, Float, Float) {
        var cv = abs(cosf(v)); if cv < 1e-9 { cv = 1e-9 }
        var sv = abs(sinf(v)); if sv < 1e-9 { sv = 1e-9 }
        let R = powf(powf(cv, n) + powf(sv, n), -invN)
        let phi = twist * u + v
        let r = a + R * cosf(phi)
        return (r * cosf(u), r * sinf(u), R * sinf(phi))
    }

    for iv in 0...Nv {
        let vp = pi2 * Float(iv) / Float(Nv)
        for iu in 0...Nu {
            let up = pi2 * Float(iu) / Float(Nu)
            let p = pos(up, vp)

            let eps: Float = 1e-4
            let pu1 = pos(up + eps, vp), pu0 = pos(up - eps, vp)
            let pv1 = pos(up, vp + eps), pv0 = pos(up, vp - eps)
            let dux = (pu1.0 - pu0.0) / (2 * eps), duy = (pu1.1 - pu0.1) / (2 * eps), duz = (pu1.2 - pu0.2) / (2 * eps)
            let dvx = (pv1.0 - pv0.0) / (2 * eps), dvy = (pv1.1 - pv0.1) / (2 * eps), dvz = (pv1.2 - pv0.2) / (2 * eps)
            var nx = duy * dvz - duz * dvy
            var ny = duz * dvx - dux * dvz
            var nz = dux * dvy - duy * dvx
            var nl = sqrtf(nx * nx + ny * ny + nz * nz); if nl < 1e-9 { nl = 1 }
            nx /= nl; ny /= nl; nz /= nl

            verts.append(contentsOf: [p.0, p.1, p.2, nx, ny, nz,
                                      Float(iu) / Float(Nu), Float(iv) / Float(Nv)])
        }
    }

    for iv in 0..<Nv {
        for iu in 0..<Nu {
            let i0 = UInt32(iv * (Nu + 1) + iu)
            let i1 = i0 + 1
            let i2 = i0 + UInt32(Nu + 1)
            let i3 = i2 + 1
            indices.append(contentsOf: [i0, i1, i2,  i1, i3, i2])
        }
    }
    return (verts, indices)
}

// ============================================================
// MARK: - Metal Shading Language source
// ============================================================

let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 uv       [[attribute(2)]];
};

struct Uniforms {
    float4x4 mvp;
    float4x4 model;
    float4x4 normalMat;
    float3   lightDir;
    float    time;
};

struct VertexOut {
    float4 position [[position]];
    float3 normal;
    float3 worldPos;
    float2 uv;
};

vertex VertexOut vertexShader(VertexIn in [[stage_in]],
                              constant Uniforms& u [[buffer(1)]]) {
    VertexOut out;
    out.position = u.mvp * float4(in.position, 1.0);
    out.normal   = normalize((u.normalMat * float4(in.normal, 0.0)).xyz);
    out.worldPos = (u.model * float4(in.position, 1.0)).xyz;
    out.uv       = in.uv;
    return out;
}

static float3 hsv2rgb(float3 c) {
    float4 K = float4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

fragment float4 fragmentShader(VertexOut in [[stage_in]],
                               constant Uniforms& u [[buffer(0)]]) {
    float3 N = normalize(in.normal);
    float3 L = normalize(u.lightDir);
    float3 V = normalize(-in.worldPos);
    float3 H = normalize(L + V);

    float hue = fract(in.uv.x + in.uv.y * 0.3 + u.time * 0.08);
    float3 baseColor = hsv2rgb(float3(hue, 0.75, 1.0));

    float ambient  = 0.12;
    float diffuse  = max(dot(N, L), 0.0) * 0.65;
    float specular = pow(max(dot(N, H), 0.0), 64.0) * 0.6;
    float rim      = pow(1.0 - max(dot(N, V), 0.0), 3.0) * 0.3;

    float3 col = baseColor * (ambient + diffuse) + float3(1.0) * specular + baseColor * rim;

    float grid = smoothstep(0.96, 1.0, max(
        abs(sin(in.uv.x * 3.14159 * 48.0)),
        abs(sin(in.uv.y * 3.14159 * 48.0))
    ));
    col = mix(col, col * 0.35, grid * 0.6);

    return float4(col, 1.0);
}
"""

// ============================================================
// MARK: - Renderer
// ============================================================

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    var pipeline: MTLRenderPipelineState!
    var depthState: MTLDepthStencilState!
    var vbuf: MTLBuffer!
    var ibuf: MTLBuffer!
    var indexCount = 0

    // Camera / parameters
    var rotX: Float = 0.3, rotY: Float = 0.5, zoom: Float = 11.0
    var n: Float = 4.0, twist: Float = 2.0, a: Float = 3.5
    let Nu = 256, Nv = 128
    var time: Float = 0
    var lastTime = ProcessInfo.processInfo.systemUptime

    init?(mtkView: MTKView) {
        guard let dev = mtkView.device, let q = dev.makeCommandQueue() else { return nil }
        device = dev
        queue = q
        super.init()

        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.depthStencilPixelFormat = .depth32Float
        mtkView.clearColor = MTLClearColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1.0)
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false

        do {
            try buildPipeline(view: mtkView)
        } catch {
            FileHandle.standardError.write("Pipeline error: \(error)\n".data(using: .utf8)!)
            return nil
        }
        buildDepthState()
        uploadMesh()
    }

    func buildPipeline(view: MTKView) throws {
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        guard let vfn = library.makeFunction(name: "vertexShader"),
              let ffn = library.makeFunction(name: "fragmentShader") else {
            throw NSError(domain: "Renderer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "shader functions not found"])
        }

        // Vertex layout: pos@0 (float3), normal@12 (float3), uv@24 (float2), stride 32.
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3; vd.attributes[0].offset = 0;  vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float3; vd.attributes[1].offset = 12; vd.attributes[1].bufferIndex = 0
        vd.attributes[2].format = .float2; vd.attributes[2].offset = 24; vd.attributes[2].bufferIndex = 0
        vd.layouts[0].stride = 32
        vd.layouts[0].stepFunction = .perVertex

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.vertexDescriptor = vd
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        desc.depthAttachmentPixelFormat = view.depthStencilPixelFormat

        pipeline = try device.makeRenderPipelineState(descriptor: desc)
    }

    func buildDepthState() {
        let d = MTLDepthStencilDescriptor()
        d.depthCompareFunction = .less
        d.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: d)
    }

    func uploadMesh() {
        let (verts, indices) = buildSupertoroid(n: n, twist: twist, a: a, Nu: Nu, Nv: Nv)
        indexCount = indices.count
        vbuf = device.makeBuffer(bytes: verts,
                                 length: verts.count * MemoryLayout<Float>.stride,
                                 options: .storageModeShared)
        ibuf = device.makeBuffer(bytes: indices,
                                 length: indices.count * MemoryLayout<UInt32>.stride,
                                 options: .storageModeShared)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { /* aspect read per-frame */ }

    func draw(in view: MTKView) {
        let now = ProcessInfo.processInfo.systemUptime
        var dt = Float(now - lastTime); lastTime = now
        if dt > 0.05 { dt = 0.05 }
        time += dt

        let size = view.drawableSize
        let aspect = Float(size.width) / Float(max(size.height, 1))

        let proj  = mat4PerspectiveMetal(0.8, aspect, 0.1, 200.0)
        let viewM = mat4Translate(0, 0, -zoom)
        let model = mat4Mul(mat4RotX(rotX), mat4RotY(rotY))
        let mvp   = mat4Mul(proj, mat4Mul(viewM, model))

        var uni = Uniforms(mvp: toSimd(mvp),
                           model: toSimd(model),
                           normalMat: toSimd(model),
                           lightDir: SIMD3<Float>(0.6, 1.0, 0.8),
                           time: time)

        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        // Depth buffer resolves visibility, so culling is disabled for robustness.
        // To enable back-face culling instead: enc.setCullMode(.back)
        // and enc.setFrontFacingWinding(.clockwise) — Metal judges winding in
        // framebuffer space (y-flipped vs NDC), so CW matches the GL CCW-front mesh.
        enc.setCullMode(.none)

        enc.setVertexBuffer(vbuf, offset: 0, index: 0)
        enc.setVertexBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setFragmentBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 0)

        enc.drawIndexedPrimitives(type: .triangle,
                                  indexCount: indexCount,
                                  indexType: .uint32,
                                  indexBuffer: ibuf,
                                  indexBufferOffset: 0)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

// ============================================================
// MARK: - View (input handling)
// ============================================================

final class ToroidMTKView: MTKView {
    weak var renderer: Renderer?
    var dragging = false
    var lastMouse = NSPoint.zero

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with e: NSEvent) {
        dragging = true
        lastMouse = e.locationInWindow
    }

    override func mouseDragged(with e: NSEvent) {
        guard dragging, let r = renderer else { return }
        let p = e.locationInWindow
        r.rotY += Float(p.x - lastMouse.x) * 0.008
        r.rotX -= Float(p.y - lastMouse.y) * 0.008
        lastMouse = p
    }

    override func mouseUp(with e: NSEvent) { dragging = false }

    override func scrollWheel(with e: NSEvent) {
        guard let r = renderer else { return }
        r.zoom -= Float(e.scrollingDeltaY) * 0.02
        r.zoom = min(max(r.zoom, 1.5), 30.0)
    }

    override func keyDown(with e: NSEvent) {
        guard let r = renderer, let ch = e.charactersIgnoringModifiers?.lowercased().first else { return }
        switch ch {
        case "\u{1b}": NSApp.terminate(nil)
        case "n": r.n = max(2.1, r.n - 0.5); r.uploadMesh(); updateTitle(r)
        case "m": r.n = min(16.0, r.n + 0.5); r.uploadMesh(); updateTitle(r)
        case "t": r.twist = max(1.0, r.twist - 1.0); r.uploadMesh(); updateTitle(r)
        case "y": r.twist = min(8.0, r.twist + 1.0); r.uploadMesh(); updateTitle(r)
        case "r":
            r.n = 4.0; r.twist = 2.0; r.rotX = 0.3; r.rotY = 0.5; r.zoom = 11.0
            r.uploadMesh(); updateTitle(r)
        case "f": window?.toggleFullScreen(nil)
        default: break
        }
    }

    func updateTitle(_ r: Renderer) {
        window?.title = String(format:
            "Supertoroid (Metal)  |  n=%.1f  twist=%.1f  |  N/M: n  T/Y: twist  R: reset  F: fullscreen  ESC: quit",
            r.n, r.twist)
    }
}

// ============================================================
// MARK: - Application entry point
// ============================================================

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var view: ToroidMTKView!
    var renderer: Renderer!

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            FileHandle.standardError.write("Metal is not supported on this machine.\n".data(using: .utf8)!)
            NSApp.terminate(nil); return
        }

        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                          styleMask: style, backing: .buffered, defer: false)
        window.center()
        window.title = "Supertoroid (Metal)"
        window.delegate = self

        let v = ToroidMTKView(frame: window.contentView!.bounds, device: device)
        guard let r = Renderer(mtkView: v) else {
            FileHandle.standardError.write("Failed to create the Metal renderer.\n".data(using: .utf8)!)
            NSApp.terminate(nil); return
        }
        v.delegate = r
        v.renderer = r
        renderer = r
        view = v
        view.autoresizingMask = [.width, .height]

        window.contentView = view
        window.makeFirstResponder(view)
        window.makeKeyAndOrderFront(nil)
        v.updateTitle(r)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()