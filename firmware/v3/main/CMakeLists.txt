# =============================================================================
# SHE V3 firmware — main/ CMakeLists.txt
# =============================================================================
# V3-FIRMWARE §2.2 — directory structure.
# Sources are conditionally compiled based on CONFIG_SHE_R4 / R8 / R16.
# =============================================================================

# Component-level CMake for the main application
idf_component_register(
    SRCS
        "main.c"
        "app_wifi.c"
        "mqtt_client.c"
        "ble_provisioning.c"
        "ota_handler.c"
        "local_ctrl.c"
        "relay_driver.c"
        "feedback_monitor.c"
        "energy_monitor.c"
        "device_profiles.c"
        "system_service.c"
        "button_task.c"
    INCLUDE_DIRS
        "."
    REQUIRES
        nvs_flash
        esp_wifi
        esp_event
        esp_http_client
        esp_https_ota
        esp_local_ctrl
        mdns
        mqtt
        protobuf-c
        protocomm
        wifi_provisioning
)

# R16-only: voice_control.c (Picovoice SDK)
if(CONFIG_SHE_R16)
    idf_component_get_property(picovoice_lib picovoice COMPONENT_LIB)
    target_link_libraries(${COMPONENT_LIB} PUBLIC ${picovoice_lib})
    target_sources(${COMPONENT_LIB} PRIVATE "voice_control.c")
endif()

# Embed CA certificate (root + intermediate bundle) at build time
# certs/ is at firmware/v3/certs/ (one level up from main/)
target_add_binary_data(${COMPONENT_LIB} "../certs/ca.pem" TEXT)
