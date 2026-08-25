# =============================================================================
# SHE V3 firmware — CMakeLists.txt
# =============================================================================
# ESP-IDF v5.1.x (LTS) per V3-FIRMWARE §2.1.
# Builds for SHE-R4 (ESP32-C3), SHE-R8 (ESP32-S3), SHE-R16 (ESP32-S3 + mic).
# =============================================================================
cmake_minimum_required(VERSION 3.16)

# Include the ESP-IDF build system
include($ENV{IDF_PATH}/tools/cmake/project.cmake)

# SKU-specific defines are set via sdkconfig.<sku> files.
# Default build = SHE-R8 (the volume SKU per V3-UNIT-ECONOMICS).
project(she-firmware)
