// vcam_frame_listener.m
// On-device root tool. Polls Darwin notifications and reads the cameracaptured
// hook's current signature string via task_for_pid + mach_vm_read.

#import <notify.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#include <stdio.h>
#include <unistd.h>
#include <string.h>

extern int proc_listallpids(void *buffer, int buffersize);
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

static pid_t find_cameracaptured(void) {
    int n = proc_listallpids(NULL, 0);
    if (n <= 0) return 0;
    pid_t *pids = (pid_t *)malloc((size_t)(n + 32) * sizeof(pid_t));
    if (!pids) return 0;
    int count = proc_listallpids(pids, (n + 32) * (int)sizeof(pid_t));
    pid_t match = 0;
    for (int i = 0; i < count; i++) {
        char path[4096] = {0};
        if (proc_pidpath(pids[i], path, sizeof(path)) > 0 &&
            strcmp(path, "/usr/libexec/cameracaptured") == 0) {
            match = pids[i];
            break;
        }
    }
    free(pids);
    return match;
}

int main(void) {
    int sigtoken = -1;
    int addrtoken = -1;
    if (notify_register_check("com.codex.vcam.ios18.signew", &sigtoken) != NOTIFY_STATUS_OK ||
        notify_register_check("com.codex.vcam.ios18.sigaddr", &addrtoken) != NOTIFY_STATUS_OK) {
        printf("notify_register_check failed\n");
        return 1;
    }
    printf("sig listener ready pid=%d\n", getpid());
    fflush(stdout);
    while (1) {
        int check = 0;
        if (notify_check(sigtoken, &check) == NOTIFY_STATUS_OK && check != 0) {
            uint64_t addr = 0;
            notify_get_state(addrtoken, &addr);
            if (addr != 0) {
                pid_t pid = find_cameracaptured();
                mach_port_t task = MACH_PORT_NULL;
                if (pid > 0 && task_for_pid(mach_task_self(), pid, &task) == KERN_SUCCESS) {
                    char buf[768] = {0};
                    vm_size_t size = (vm_size_t)sizeof(buf) - 1;
                    if (vm_read_overwrite(task, (vm_address_t)addr,
                                               size, (vm_address_t)buf, &size) == KERN_SUCCESS) {
                        buf[sizeof(buf) - 1] = '\0';
                        FILE *f = fopen("/var/tmp/vcam-ios18-sigs.log", "a");
                        if (f) {
                            fprintf(f, "%s\n", buf);
                            fclose(f);
                        }
                    }
                    mach_port_deallocate(mach_task_self(), task);
                }
            }
        }
        usleep(100000);
    }
    return 0;
}
