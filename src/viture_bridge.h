#ifndef VITURE_BRIDGE_H
#define VITURE_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Initializes the VITURE SDK, starts UDP broadcast server, and opens IMU
int viture_bridge_start(int product_id, int port);

// Closes streams, stops sockets, and shuts down the VITURE provider
void viture_bridge_stop(void);

#ifdef __cplusplus
}
#endif

#endif // VITURE_BRIDGE_H