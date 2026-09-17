// VCamProbe — minimale Diagnose-Dylib: nur ctor + Datei-Log.
// Zweck: isolieren, ob opainject den %ctor ausführt (ohne Hooks/Frameworks).
#import <Foundation/Foundation.h>
#import <fcntl.h>
#import <unistd.h>
#import <stdarg.h>
#import <string.h>

static void FLOG(const char *fmt, ...) {
    char buf[1024];
    va_list ap; va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    const char *paths[] = { "/var/mobile/Documents/vcamprobe.log", "/var/tmp/vcamprobe.log", "/tmp/vcamprobe.log", NULL };
    for (int i = 0; paths[i]; i++) {
        int fd = open(paths[i], O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) { write(fd, buf, strlen(buf)); close(fd); break; }
    }
}

__attribute__((constructor))
static void probe_ctor(void) {
    NSString *proc = [[NSProcessInfo processInfo] processName];
    FLOG("VCamProbe ctor: proc=%s pid=%d\n", [proc UTF8String] ?: "?", getpid());
}
