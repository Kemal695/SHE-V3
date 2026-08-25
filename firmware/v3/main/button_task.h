/* =============================================================================
 * SHE V3 firmware — button_task.h
 * =============================================================================
 * BOOT button handler. V3-FIRMWARE §2.2 + §3 (button_task: priority 2, 2048 stack).
 * Short press = cycle relays. Long press (5s) = factory reset.
 * ==========================================================================*/

#ifndef SHE_BUTTON_TASK_H
#define SHE_BUTTON_TASK_H

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

esp_err_t button_task_start(void);

#ifdef __cplusplus
}
#endif

#endif /* SHE_BUTTON_TASK_H */
