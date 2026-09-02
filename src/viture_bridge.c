#include "viture_device.h"
#include "viture_glasses_provider.h"
#include <stdio.h>
#include <sys/socket.h>
#include <netinet/in.h>

int sockfd;
struct sockaddr_in servaddr;

// Raw IMU callback signature matching the header
void on_imu_raw(float* data, uint64_t timestamp, uint64_t vsync) {
    // Pack data into a socket payload and broadcast to localhost clients
    sendto(sockfd, data, sizeof(float) * 10, 0, (struct sockaddr*)&servaddr, sizeof(servaddr));
}

int main() {
    // 1. Setup UDP Socket broadcasting on local port 9000
    sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    servaddr.sin_family = AF_INET;
    servaddr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    servaddr.sin_port = htons(9000);

    // 2. Initialize provider (SDK handles low-level USB thread)
    XRDeviceProviderHandle handle = xr_device_provider_create(0x1301); // Pro 2
    xr_device_provider_initialize(handle, NULL, NULL);
    xr_device_provider_start(handle);

    // 3. Register raw callback & open IMU stream
    xr_device_provider_register_imu_raw_callback(handle, on_imu_raw);
    xr_device_provider_open_imu(handle, 0, 1); // Mode Raw (0), Frequency 60Hz (1)

    // Keep process alive as system service
    while(1) { sleep(1); }
    return 0;
}