/*
 * Determination display-owner transition.
 *
 * This is deliberately neither an Android activity nor a Wayland client. It
 * becomes the sole HWC2 client in the short gap between SurfaceFlinger and
 * phoc, renders a finite GLES sequence, lands on black, and releases the HAL.
 * The desktop -> phone product path intentionally uses crDroid's bootanimation
 * instead, although the phone direction remains useful for isolated testing.
 *
 * Built against libhybris' proven test_common HWC window; see
 * guest/build-transition.sh.
 */

#include <android-config.h>

#include <EGL/egl.h>
#include <GLES2/gl2.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>

#include "test_common.h"

namespace {

constexpr int kDurationMs = 3200;

const char *kVertexShader = R"(
attribute vec2 position;
varying mediump vec2 uv;

void main() {
    uv = position * 0.5 + 0.5;
    gl_Position = vec4(position, 0.0, 1.0);
}
)";

const char *kFragmentShader = R"(
precision highp float;

varying mediump vec2 uv;
uniform float progress;
uniform float direction;
uniform float aspect;

const float PI = 3.14159265359;
const float TAU = 6.28318530718;

float saturate(float x) {
    return clamp(x, 0.0, 1.0);
}

float ease_out_quint(float x) {
    x = saturate(x);
    return 1.0 - pow(1.0 - x, 5.0);
}

float spring(float x) {
    x = saturate(x);
    return 1.0 - exp(-7.5 * x) * cos(11.0 * x);
}

float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float soul_pixel(vec2 cell) {
    float x = floor(cell.x);
    float y = floor(cell.y);
    if (y < 0.0 || y > 10.0 || x < 0.0 || x > 12.0) return 0.0;
    if (y < 1.0) return step(2.0, x) * step(x, 4.0) + step(8.0, x) * step(x, 10.0);
    if (y < 2.0) return step(1.0, x) * step(x, 5.0) + step(7.0, x) * step(x, 11.0);
    if (y < 5.0) return 1.0;
    if (y < 6.0) return step(1.0, x) * step(x, 11.0);
    if (y < 7.0) return step(2.0, x) * step(x, 10.0);
    if (y < 8.0) return step(3.0, x) * step(x, 9.0);
    if (y < 9.0) return step(4.0, x) * step(x, 8.0);
    if (y < 10.0) return step(5.0, x) * step(x, 7.0);
    return step(6.0, x) * step(x, 6.0);
}

void main() {
    float t = saturate(progress);
    float spin = mix(1.0, -1.0, direction);
    vec2 screen = uv - 0.5;
    vec2 p = (uv - 0.5) * vec2(aspect, 1.0);
    float loop_progress = saturate((t - 0.18) / 0.60);
    float cycle = fract(loop_progress * 2.0);
    float cycle_envelope = smoothstep(0.00, 0.10, cycle) *
                           (1.0 - smoothstep(0.82, 1.00, cycle));
    float loop_window = smoothstep(0.14, 0.20, t) *
                        (1.0 - smoothstep(0.76, 0.82, t));

    // Act I --- Android falls away into a restrained, dimensional signal field.
    float field_in = smoothstep(0.00, 0.12, t);
    float field_out = 1.0 - smoothstep(0.90, 0.98, t);
    float vignette = 1.0 - smoothstep(0.16, 0.72, length(screen * vec2(0.74, 1.0)));
    vec2 grid_uv = uv * vec2(18.0, 38.0);
    vec2 grid_dist = min(fract(grid_uv), 1.0 - fract(grid_uv));
    float grid = 1.0 - smoothstep(0.0, 0.035, min(grid_dist.x, grid_dist.y));
    float scan = 0.5 + 0.5 * sin(uv.y * 980.0 + t * 18.0);
    vec3 color = vec3(0.0035, 0.0030, 0.0045);
    color += vec3(0.024, 0.002, 0.004) * vignette * field_in * field_out;
    color += vec3(0.12, 0.004, 0.010) * grid * (0.025 + scan * 0.018) * field_in * field_out;

    // The first cue is immediate: one precise line grows from the centre.
    float line_in = ease_out_quint((t - 0.015) / 0.17);
    float line_out = 1.0 - smoothstep(0.91, 0.98, t);
    float line_half = 0.205 * line_in;
    float axis = (1.0 - smoothstep(0.0012, 0.0038, abs(p.y))) *
                 (1.0 - smoothstep(line_half, line_half + 0.012, abs(p.x)));
    float tracer_x = mix(-0.205, 0.205, ease_out_quint((t - 0.07) / 0.24));
    float tracer = exp(-abs(p.x - tracer_x) * 95.0) * axis;
    color += vec3(0.70, 0.004, 0.018) * axis * line_out;
    color += vec3(1.0, 0.22, 0.25) * tracer * line_out;

    // Act II --- every pixel arrives on its own cue, then the whole soul settles
    // as one physical object. The slight overshoot is a damped spring, not a
    // generic scale tween.
    float assemble = saturate((t - 0.08) / 0.20);
    float settle = spring(assemble);
    float breathe = 1.0 + sin(cycle * TAU) * 0.035 * cycle_envelope * loop_window;
    float collapse = smoothstep(0.80, 0.93, t);
    vec2 heart_p = p;
    heart_p.x /= max(mix(0.58, 1.72, collapse) * settle * breathe, 0.05);
    heart_p.y /= max(mix(0.58, 0.11, collapse) * settle * breathe, 0.05);
    float cell_size = 0.0115;
    vec2 cell = vec2(
        heart_p.x / cell_size + 6.5,
        -heart_p.y / cell_size + 5.5
    );
    vec2 pixel_coord = floor(cell);
    vec2 pixel_local = abs(fract(cell) - 0.5);
    float pixel_box = 1.0 - smoothstep(0.39, 0.49, max(pixel_local.x, pixel_local.y));
    float pixel_delay = hash21(pixel_coord);
    float pixel_reveal = smoothstep(0.08 + pixel_delay * 0.14,
                                    0.13 + pixel_delay * 0.14, t);
    float soul = min(soul_pixel(cell), 1.0) * pixel_box * pixel_reveal;
    soul *= 1.0 - smoothstep(0.88, 0.95, t);

    // Each bounded cycle has a strong beat and a quieter answer. The middle
    // choreography repeats twice, but the process still has a hard endpoint.
    float beat_a = exp(-pow((cycle - 0.28) / 0.040, 2.0));
    float beat_b = exp(-pow((cycle - 0.47) / 0.032, 2.0)) * 0.58;
    float beat = (beat_a + beat_b) * cycle_envelope * loop_window;
    float radius = length(p);
    float soul_glow = exp(-radius * 13.5) * smoothstep(0.11, 0.25, t) *
                      (1.0 - smoothstep(0.86, 0.95, t));
    vec3 red = vec3(1.0, 0.006, 0.025);
    color += red * soul_glow * (0.22 + beat * 0.30);
    color = mix(color, red + vec3(beat * 0.42), soul);

    // Act III --- two rings acquire the mark in sequence. Angular ticks rotate
    // against the rings, creating depth without adding a competing focal point.
    float ring_window = cycle_envelope * loop_window;
    float ring_a_r = mix(0.035, 0.205, ease_out_quint((cycle - 0.03) / 0.58));
    float ring_b_r = mix(0.025, 0.154, ease_out_quint((cycle - 0.20) / 0.50));
    float ring_a = 1.0 - smoothstep(0.0015, 0.0055, abs(radius - ring_a_r));
    float ring_b = 1.0 - smoothstep(0.0012, 0.0040, abs(radius - ring_b_r));
    float angle = atan(p.y, p.x) + spin * t * 5.2;
    float tick_phase = abs(fract(angle / TAU * 24.0) - 0.5);
    float ticks = 1.0 - smoothstep(0.055, 0.13, tick_phase);
    float tick_band = smoothstep(0.166, 0.174, radius) *
                      (1.0 - smoothstep(0.193, 0.202, radius));
    ticks *= tick_band * ring_window;
    color += red * (ring_a * 0.46 + ring_b * 0.25) * ring_window;
    color += vec3(1.0, 0.10, 0.14) * ticks * 0.42;

    // Act IV --- energy resolves into the original line, then a physical shutter
    // closes to true black so phoc never inherits a branded/stale buffer.
    float resolve = smoothstep(0.80, 0.93, t);
    float flare = exp(-abs(p.y) * 115.0) * exp(-abs(p.x) * 8.0) * resolve;
    float core = exp(-radius * 72.0) * beat;
    color += vec3(1.0, 0.025, 0.045) * flare * 0.72;
    color += vec3(1.0, 0.72, 0.74) * core;

    float shutter_t = smoothstep(0.915, 0.990, t);
    float aperture = mix(0.58, 0.0, shutter_t);
    float shutter = 1.0 - smoothstep(aperture, aperture + 0.018, abs(screen.y));
    color *= shutter;
    color *= 1.0 - smoothstep(0.980, 1.0, t);
    gl_FragColor = vec4(color, 1.0);
}
)";

void fail(const char *message) {
    std::fprintf(stderr, "det-transition: %s (egl=0x%x gl=0x%x)\n",
                 message, eglGetError(), glGetError());
    std::exit(1);
}

}  // namespace

int main(int argc, char **argv) {
    float direction = 0.0f;
    if (argc == 2 && std::strcmp(argv[1], "phone") == 0) {
        direction = 1.0f;
    } else if (argc != 2 || std::strcmp(argv[1], "desktop") != 0) {
        std::fprintf(stderr, "usage: det-transition desktop|phone\n");
        return 2;
    }

    HWComposer *window = create_hwcomposer_window();
    if (!window) fail("could not create HWC window");

    const EGLint config_attributes[] = {
        EGL_BUFFER_SIZE, 32,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_NONE,
    };
    const EGLint context_attributes[] = {
        EGL_CONTEXT_CLIENT_VERSION, 2,
        EGL_NONE,
    };

    EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (display == EGL_NO_DISPLAY || !eglInitialize(display, nullptr, nullptr))
        fail("could not initialize EGL display");

    EGLConfig config = nullptr;
    EGLint config_count = 0;
    if (!eglChooseConfig(display, config_attributes, &config, 1, &config_count) || config_count != 1)
        fail("could not choose EGL config");

    EGLSurface surface = eglCreateWindowSurface(
        display, config,
        reinterpret_cast<EGLNativeWindowType>(static_cast<ANativeWindow *>(window)), nullptr);
    if (surface == EGL_NO_SURFACE) fail("could not create EGL window surface");

    EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attributes);
    if (context == EGL_NO_CONTEXT || !eglMakeCurrent(display, surface, surface, context))
        fail("could not create GLES2 context");

    EGLint width = 0;
    EGLint height = 0;
    eglQuerySurface(display, surface, EGL_WIDTH, &width);
    eglQuerySurface(display, surface, EGL_HEIGHT, &height);
    if (width <= 0 || height <= 0) fail("invalid HWC surface dimensions");

    GLuint program = create_program(kVertexShader, kFragmentShader);
    if (!program) fail("could not build transition shader");
    glUseProgram(program);

    const GLint position = glGetAttribLocation(program, "position");
    const GLint progress = glGetUniformLocation(program, "progress");
    const GLint direction_uniform = glGetUniformLocation(program, "direction");
    const GLint aspect = glGetUniformLocation(program, "aspect");
    if (position < 0 || progress < 0 || direction_uniform < 0 || aspect < 0)
        fail("transition shader uniforms are incomplete");

    const GLfloat vertices[] = {
        -1.0f, -1.0f,
         1.0f, -1.0f,
        -1.0f,  1.0f,
         1.0f,  1.0f,
    };
    glViewport(0, 0, width, height);
    glVertexAttribPointer(position, 2, GL_FLOAT, GL_FALSE, 0, vertices);
    glEnableVertexAttribArray(position);
    glUniform1f(direction_uniform, direction);
    glUniform1f(aspect, static_cast<float>(width) / static_cast<float>(height));
    eglSwapInterval(display, 1);

    const auto started = std::chrono::steady_clock::now();
    for (;;) {
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - started).count();
        const float t = static_cast<float>(elapsed) / static_cast<float>(kDurationMs);
        glUniform1f(progress, t > 1.0f ? 1.0f : t);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        if (!eglSwapBuffers(display, surface)) fail("frame presentation failed");
        if (t >= 1.0f) break;
    }

    // Latch black twice before teardown. The first frame may still be queued;
    // the second gives HWC a full present interval before the next owner binds.
    glUniform1f(progress, 1.0f);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    eglSwapBuffers(display, surface);

    glDeleteProgram(program);
    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(display, context);
    eglDestroySurface(display, surface);
    eglTerminate(display);
    delete window;

    std::fprintf(stderr, "det-transition: %s complete (%dx%d, %dms)\n",
                 argv[1], width, height, kDurationMs);
    return 0;
}
