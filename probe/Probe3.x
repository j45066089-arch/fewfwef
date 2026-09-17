// VCamProbe3 — Socket-basierte ctor-Diagnose (sandbox-freundlicher als Datei-write).
// Bindet einen Loopback-TCP-Server auf Port 8799 im ctor. Wenn der Port nach
// opainject offen ist, HAT der ctor gelebt. Pure C, kein Foundation/objc.
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

__attribute__((constructor))
static void probe3_ctor(void) {
    // 1) Datei-Log versuchen (falls Sandbox es erlaubt)
    const char *msg = "VCamProbe3 ctor RAN\n";
    int fd = open("/var/tmp/vcamprobe3.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) { write(fd, msg, strlen(msg)); close(fd); }

    // 2) Socket-Server binden (das ist der wasserdichte Test)
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) return;
    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(8799);
    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
        listen(srv, 4);
        // offen halten: accept-Schleife
        while (1) {
            int c = accept(srv, NULL, NULL);
            if (c < 0) break;
            const char *resp = "ctor ran\n";
            send(c, resp, strlen(resp), 0);
            close(c);
        }
    }
}