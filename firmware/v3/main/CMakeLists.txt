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
        "she_mqtt.c"
        "ble_provisioning.c"
        "ota_handler.c"
        "local_ctrl.c"
        "relay_driver.c"
        "feedback_monitor.c"
        "input_monitor.c"
        "sensors.c"
        "energy_monitor.c"
        "device_profiles.c"
        "system_service.c"
        "schedule_store.c"
        "button_task.c"
        # Vendored Ed25519 verifier (see third_party/README.md for why and for checksums)
        "third_party/tweetnacl.c"
        "third_party/tweetnacl_port.c"
        # Vendored QR generator (Espressif esp_qrcode + Nayuki qrcodegen) — prints
        # the provisioning QR payload on the console. See third_party/README.md.
        "third_party/qrcode/qrcodegen.c"
        "third_party/qrcode/esp_qrcode_main.c"
        "third_party/qrcode/esp_qrcode_wrapper.c"
    INCLUDE_DIRS
        "."
        "third_party"
        # Holds qrcode.h, and the esp_rmaker_utils.h shim that esp_qrcode_main.c
        # includes by name (angle brackets, so it resolves from here).
        "third_party/qrcode"
    REQUIRES
        nvs_flash
        esp_wifi
        esp_event
        esp_http_client
        esp_http_server
        esp_https_server
        esp_https_ota
        esp_local_ctrl
        mqtt
        protobuf-c
        protocomm
        wifi_provisioning
        json
        driver
        app_update
        bt
        # esp_random.h for tweetnacl_port.c (hardware RNG backing randombytes)
        esp_hw_support
        # esp_efuse.h for the OTA anti-rollback SECURE_VERSION read
        efuse
)

# ---- mDNS (local control discovery) -----------------------------------------
# local_ctrl.c advertises _she_ctrl._tcp so the app can find the device by name.
#
# OPTIONAL on purpose. `idf_component.yml` declares espressif/mdns, but the
# component only lands in managed_components/ after a reconfigure — and a hard
# `REQUIRES mdns` would turn "the registry component has not been fetched yet"
# into a configure error that stops the whole build. This helper adds the
# dependency only when the component is actually part of the build, which is the
# same thing esp_local_ctrl does:
#     idf_component_optional_requires(PRIVATE espressif__mdns mdns)
#
# When it is absent, local_ctrl.c falls back to its `__has_include("mdns.h")`
# stub: no advertisement, but the HTTPS endpoint still works by IP.
#
# ⚠ The old guard in local_ctrl.c was `#ifdef CONFIG_MDNS`, which is a phantom
# symbol — the component defines only MDNS_* options and has no bare enable flag.
# Both spellings are listed below because the component answers to `espressif__mdns`
# (registry name) and `mdns` (the historical IDF name).
idf_component_optional_requires(PRIVATE espressif__mdns mdns)

# R16-only: voice_control.c is a Phase-1 stub with no third-party SDK includes
# (full Picovoice integration lands in Phase 4C). Link no external SDK here —
# the old idf_component_get_property(picovoice ...) block broke R16 builds
# because no `picovoice` component is declared (F9 fix).
if(CONFIG_SHE_R16)
    target_sources(${COMPONENT_LIB} PRIVATE "voice_control.c")
endif()

# Embed CA certificate (root + intermediate bundle) at build time
# certs/ is at firmware/v3/certs/ (one level up from main/)
target_add_binary_data(${COMPONENT_LIB} "../certs/ca.pem" TEXT)
