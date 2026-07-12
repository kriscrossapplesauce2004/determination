// det-audiobridge — Determination guest-audio sink, Android side.
//
// The real QCOM audio HAL on guacamoleb is 32-bit (audio.primary.msmnile.so),
// and Android stays PID1 with audioserver holding the HAL. So the guest cannot
// load the HAL itself (64-bit process, can't dlopen a 32-bit .so) and must not
// double-open the sound card behind audioserver's back. Instead the guest
// streams PCM here, and this process plays it through AAudio — i.e. through
// audioserver -> HAL -> speaker, exactly like any Android app. Android keeps
// full control of routing/volume/ducking, which is the whole point (max
// compatibility). Playback needs only audioserver, not system_server, so this
// keeps working in desktop mode where system_server is frozen.
//
// Wire format: raw interleaved PCM, s16le, 48000 Hz, 2ch. The guest's
// PulseAudio serves its sink monitor over TCP (module-simple-protocol-tcp);
// we connect out to it and pump frames into the stream. Connecting OUT (rather
// than listening) means Android is the client of the guest's PA, so there is
// nothing to firewall on the Android side.
//
// Usage:
//   det-audiobridge --tone            play a 2s 440Hz test tone and exit
//   det-audiobridge <host> <port>     stream PCM from host:port to the speaker

#include <aaudio/AAudio.h>
#include <arpa/inet.h>
#include <errno.h>
#include <math.h>
#include <netdb.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define RATE     48000
#define CHANS    2
#define FRAMES   1920          // 40ms chunk

static AAudioStream *open_stream(void) {
    AAudioStreamBuilder *b = NULL;
    aaudio_result_t r = AAudio_createStreamBuilder(&b);
    if (r != AAUDIO_OK) { fprintf(stderr, "createStreamBuilder: %s\n", AAudio_convertResultToText(r)); return NULL; }
    AAudioStreamBuilder_setDirection(b, AAUDIO_DIRECTION_OUTPUT);
    AAudioStreamBuilder_setFormat(b, AAUDIO_FORMAT_PCM_I16);
    AAudioStreamBuilder_setChannelCount(b, CHANS);
    AAudioStreamBuilder_setSampleRate(b, RATE);
    AAudioStreamBuilder_setPerformanceMode(b, AAUDIO_PERFORMANCE_MODE_NONE);
    AAudioStreamBuilder_setUsage(b, AAUDIO_USAGE_MEDIA);
    AAudioStream *s = NULL;
    r = AAudioStreamBuilder_openStream(b, &s);
    AAudioStreamBuilder_delete(b);
    if (r != AAUDIO_OK) { fprintf(stderr, "openStream: %s\n", AAudio_convertResultToText(r)); return NULL; }
    fprintf(stderr, "aaudio: opened rate=%d ch=%d fmt=i16 device=%d\n",
            AAudioStream_getSampleRate(s), AAudioStream_getChannelCount(s),
            AAudioStream_getDeviceId(s));
    r = AAudioStream_requestStart(s);
    if (r != AAUDIO_OK) { fprintf(stderr, "requestStart: %s\n", AAudio_convertResultToText(r)); AAudioStream_close(s); return NULL; }
    return s;
}

static int play_tone(void) {
    AAudioStream *s = open_stream();
    if (!s) return 1;
    int16_t buf[FRAMES * CHANS];
    double ph = 0.0, step = 2.0 * M_PI * 440.0 / RATE;
    for (int chunk = 0; chunk < RATE / FRAMES * 2; chunk++) {      // ~2s
        for (int i = 0; i < FRAMES; i++) {
            int16_t v = (int16_t)(sin(ph) * 8000.0);
            buf[i*2] = v; buf[i*2+1] = v;
            ph += step; if (ph > 2*M_PI) ph -= 2*M_PI;
        }
        aaudio_result_t w = AAudioStream_write(s, buf, FRAMES, 1000000000LL);
        if (w < 0) { fprintf(stderr, "write: %s\n", AAudio_convertResultToText(w)); break; }
    }
    AAudioStream_requestStop(s);
    AAudioStream_close(s);
    fprintf(stderr, "tone done\n");
    return 0;
}

static int connect_to(const char *host, const char *port) {
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, port, &hints, &res) != 0) return -1;
    int fd = -1;
    for (struct addrinfo *a = res; a; a = a->ai_next) {
        fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, a->ai_addr, a->ai_addrlen) == 0) break;
        close(fd); fd = -1;
    }
    freeaddrinfo(res);
    return fd;
}

static int stream_from(const char *host, const char *port) {
    AAudioStream *s = open_stream();
    if (!s) return 1;
    int16_t buf[FRAMES * CHANS];
    const size_t bytes = sizeof(buf);
    for (;;) {
        int fd = connect_to(host, port);
        if (fd < 0) { fprintf(stderr, "connect %s:%s failed (%s), retry in 2s\n", host, port, strerror(errno)); sleep(2); continue; }
        fprintf(stderr, "connected to %s:%s\n", host, port);
        for (;;) {
            size_t got = 0;
            while (got < bytes) {
                ssize_t n = read(fd, (char*)buf + got, bytes - got);
                if (n <= 0) { got = 0; break; }
                got += n;
            }
            if (got < bytes) break;     // peer closed / error -> reconnect
            aaudio_result_t w = AAudioStream_write(s, buf, FRAMES, 1000000000LL);
            if (w < 0) { fprintf(stderr, "write: %s\n", AAudio_convertResultToText(w)); break; }
        }
        close(fd);
        fprintf(stderr, "disconnected, will reconnect\n");
    }
    AAudioStream_close(s);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--tone") == 0) return play_tone();
    if (argc == 3) return stream_from(argv[1], argv[2]);
    fprintf(stderr, "usage: %s --tone | %s <host> <port>\n", argv[0], argv[0]);
    return 2;
}
