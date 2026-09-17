// VCamProbe2 — REINE C-Diagnose, kein Foundation/objc.
// Schreibt SOFORT am ctor-Anfang nach /var/tmp. Beantwortet definitiv:
// läuft der ctor nach opainject/ElleKit überhaupt?
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

__attribute__((constructor))
static void probe2_ctor(void) {
    const char *msg = "VCamProbe2 ctor RAN\n";
    // direkt /var/tmp (mobile-writable, verifiziert)
    int fd = open("/var/tmp/vcamprobe2.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        write(fd, msg, strlen(msg));
        close(fd);
    }
    // auch /tmp (symlink zu var/tmp)
    fd = open("/tmp/vcamprobe2.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        write(fd, msg, strlen(msg));
        close(fd);
    }
}
