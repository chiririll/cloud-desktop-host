/*
 * cloud-desktop-host — dbus_input.cpp
 * D-Bus сервис org.gamescope.Input для KCM Cloud Mouse.
 *
 * Портировано из Cloud-Desktop/src/InputDeviceDBus.cpp с адаптацией
 * под wlroots-based compositor (без gamescope namespace/IWaitable).
 */
#define _POSIX_C_SOURCE 200809L

#include "dbus_input.h"
#include "server.h"

extern "C" {
#include <wlr/util/log.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_xdg_shell.h>
}

#include <cstring>
#include <fstream>
#include <sstream>
#include <filesystem>
#include <libudev.h>
#include <linux/input-event-codes.h>

static constexpr double kDefaultScrollFactor = 8.0;

/* ── Helpers ── */

static const char *sys_name_from_path(const char *path) {
    const char *prefix = "/org/gamescope/Input/Device/";
    if (strncmp(path, prefix, strlen(prefix)) != 0)
        return nullptr;
    return path + strlen(prefix);
}

/* ── Config persistence ── */

static std::string get_config_path() {
    const char *home = getenv("HOME");
    if (!home) home = "/tmp";
    std::string dir = std::string(home) + "/.config";
    std::filesystem::create_directories(dir);
    return dir + "/gamescope-input.conf";
}

using ConfigMap = std::map<std::string, std::map<std::string, std::string>>;

static ConfigMap read_config_file() {
    ConfigMap cfg;
    std::ifstream f(get_config_path());
    if (!f.is_open()) return cfg;

    std::string section, line;
    while (std::getline(f, line)) {
        while (!line.empty() && isspace(line.front())) line.erase(line.begin());
        while (!line.empty() && isspace(line.back())) line.pop_back();
        if (line.empty() || line[0] == '#') continue;

        if (line.front() == '[' && line.back() == ']') {
            section = line.substr(1, line.size() - 2);
            continue;
        }
        auto eq = line.find('=');
        if (eq == std::string::npos || section.empty()) continue;
        cfg[section][line.substr(0, eq)] = line.substr(eq + 1);
    }
    return cfg;
}

static void write_config_file(const ConfigMap &cfg) {
    std::ofstream f(get_config_path(), std::ios::trunc);
    if (!f.is_open()) return;
    f << "# Cloud Desktop Mouse settings — auto-generated\n";
    for (auto &[section, props] : cfg) {
        f << "\n[" << section << "]\n";
        for (auto &[key, val] : props)
            f << key << "=" << val << "\n";
    }
}

static void save_device_config(struct cd_dbus_input *dbus,
                                const char *sysname, libinput_device *dev) {
    ConfigMap cfg = read_config_file();
    auto &sec = cfg[sysname];

    sec["pointerAcceleration"] = std::to_string(
        libinput_device_config_accel_get_speed(dev));
    auto profile = libinput_device_config_accel_get_profile(dev);
    sec["accelProfile"] = (profile == LIBINPUT_CONFIG_ACCEL_PROFILE_FLAT)
        ? "flat" : "adaptive";
    sec["naturalScroll"] = std::to_string(
        (int)libinput_device_config_scroll_get_natural_scroll_enabled(dev));
    sec["leftHanded"] = std::to_string(
        (int)libinput_device_config_left_handed_get(dev));
    sec["middleEmulation"] = std::to_string(
        (int)(libinput_device_config_middle_emulation_get_enabled(dev)
              == LIBINPUT_CONFIG_MIDDLE_EMULATION_ENABLED));
    sec["scrollFactor"] = std::to_string(
        cd_dbus_input_get_scroll_factor(dbus, sysname));

    write_config_file(cfg);
    wlr_log(WLR_INFO, "[dbus-input] Config saved for %s", sysname);
}

static void load_device_config(struct cd_dbus_input *dbus,
                                const char *sysname, libinput_device *dev) {
    ConfigMap cfg = read_config_file();
    auto it = cfg.find(sysname);
    if (it == cfg.end()) {
        wlr_log(WLR_INFO, "[dbus-input] No saved config for %s", sysname);
        return;
    }

    auto &sec = it->second;
    auto find = [&](const char *key) -> const std::string* {
        auto vit = sec.find(key);
        return (vit != sec.end()) ? &vit->second : nullptr;
    };

    if (auto *v = find("pointerAcceleration")) {
        libinput_device_config_accel_set_speed(dev, std::stod(*v));
        wlr_log(WLR_INFO, "[dbus-input] %s: restored pointerAcceleration=%s",
                sysname, v->c_str());
    }
    if (auto *v = find("accelProfile")) {
        auto p = (*v == "flat") ? LIBINPUT_CONFIG_ACCEL_PROFILE_FLAT
                                : LIBINPUT_CONFIG_ACCEL_PROFILE_ADAPTIVE;
        libinput_device_config_accel_set_profile(dev, p);
    }
    if (auto *v = find("naturalScroll"))
        libinput_device_config_scroll_set_natural_scroll_enabled(
            dev, std::stoi(*v));
    if (auto *v = find("leftHanded"))
        libinput_device_config_left_handed_set(dev, std::stoi(*v));
    if (auto *v = find("middleEmulation")) {
        auto cfg_val = std::stoi(*v)
            ? LIBINPUT_CONFIG_MIDDLE_EMULATION_ENABLED
            : LIBINPUT_CONFIG_MIDDLE_EMULATION_DISABLED;
        libinput_device_config_middle_emulation_set_enabled(dev, cfg_val);
    }
    if (auto *v = find("scrollFactor"))
        cd_dbus_input_set_scroll_factor(dbus, sysname, std::stod(*v));

    wlr_log(WLR_INFO, "[dbus-input] Config loaded for %s", sysname);
}

/* ════════════════════════════════════════════════════════════════
   sd-bus vtable: org.gamescope.InputDevice (per-device properties)
   ════════════════════════════════════════════════════════════════ */

static int device_property_get(
    sd_bus *bus, const char *path, const char *interface,
    const char *property, sd_bus_message *reply,
    void *userdata, sd_bus_error *error)
{
    (void)bus; (void)interface;
    auto *dbus = static_cast<struct cd_dbus_input*>(userdata);
    const char *sysname = sys_name_from_path(path);
    if (!sysname)
        return sd_bus_error_setf(error, SD_BUS_ERROR_INVALID_ARGS,
                                  "Invalid path");

    libinput_device *dev = nullptr;
    {
        std::lock_guard<std::mutex> lock(dbus->mutex);
        auto it = dbus->devices.find(sysname);
        if (it != dbus->devices.end())
            dev = it->second.device;
    }
    if (!dev)
        return sd_bus_error_setf(error, SD_BUS_ERROR_UNKNOWN_OBJECT,
                                  "Device not found: %s", sysname);

    /* String properties */
    if (strcmp(property, "name") == 0)
        return sd_bus_message_append(reply, "s",
            libinput_device_get_name(dev) ?: "");
    if (strcmp(property, "sysName") == 0)
        return sd_bus_message_append(reply, "s", sysname);

    /* Bool: capabilities */
    if (strcmp(property, "pointer") == 0)
        return sd_bus_message_append(reply, "b",
            (int)libinput_device_has_capability(dev, LIBINPUT_DEVICE_CAP_POINTER));
    if (strcmp(property, "keyboard") == 0)
        return sd_bus_message_append(reply, "b",
            (int)libinput_device_has_capability(dev, LIBINPUT_DEVICE_CAP_KEYBOARD));
    if (strcmp(property, "touchpad") == 0) {
        bool tp = false;
        if (libinput_device_has_capability(dev, LIBINPUT_DEVICE_CAP_POINTER)) {
            struct udev_device *ud = libinput_device_get_udev_device(dev);
            if (ud) {
                tp = udev_device_get_property_value(ud, "ID_INPUT_TOUCHPAD") != nullptr;
                udev_device_unref(ud);
            }
        }
        return sd_bus_message_append(reply, "b", (int)tp);
    }
    if (strcmp(property, "touch") == 0)
        return sd_bus_message_append(reply, "b",
            (int)libinput_device_has_capability(dev, LIBINPUT_DEVICE_CAP_TOUCH));

    /* Acceleration */
    if (strcmp(property, "supportsPointerAcceleration") == 0)
        return sd_bus_message_append(reply, "b",
            (int)libinput_device_config_accel_is_available(dev));
    if (strcmp(property, "pointerAcceleration") == 0)
        return sd_bus_message_append(reply, "d",
            libinput_device_config_accel_get_speed(dev));
    if (strcmp(property, "defaultPointerAcceleration") == 0)
        return sd_bus_message_append(reply, "d",
            libinput_device_config_accel_get_default_speed(dev));

    /* Accel profiles */
    if (strcmp(property, "supportsPointerAccelerationProfileFlat") == 0)
        return sd_bus_message_append(reply, "b",
            (int)(libinput_device_config_accel_get_profiles(dev)
                  & LIBINPUT_CONFIG_ACCEL_PROFILE_FLAT));
    if (strcmp(property, "defaultPointerAccelerationProfileFlat") == 0)
        return sd_bus_message_append(reply, "b",
            (int)(libinput_device_config_accel_get_default_profile(dev)
                  == LIBINPUT_CONFIG_ACCEL_PROFILE_FLAT));
    if (strcmp(property, "pointerAccelerationProfileFlat") == 0)
        return sd_bus_message_append(reply, "b",
            (int)(libinput_device_config_accel_get_profile(dev)
                  == LIBINPUT_CONFIG_ACCEL_PROFILE_FLAT));

    if (strcmp(property, "supportsPointerAccelerationProfileAdaptive") == 0)
        return sd_bus_message_append(reply, "b",
            (int)(libinput_device_config_accel_get_profiles(dev)
                  & LIBINPUT_CONFIG_ACCEL_PROFILE_ADAPTIVE));
    if (strcmp(property, "defaultPointerAccelerationProfileAdaptive") == 0)
        return sd_bus_message_append(reply, "b",
            (int)(libinput_device_config_accel_get_default_profile(dev)
                  == LIBINPUT_CONFIG_ACCEL_PROFILE_ADAPTIVE));
    if (strcmp(property, "pointerAccelerationProfileAdaptive") == 0)
        return sd_bus_message_append(reply, "b",
            (int)(libinput_device_config_accel_get_profile(dev)
                  == LIBINPUT_CONFIG_ACCEL_PROFILE_ADAPTIVE));

    /* Natural scroll */
    if (strcmp(property, "supportsNaturalScroll") == 0)
        return sd_bus_message_append(reply, "b",
            (int)libinput_device_config_scroll_has_natural_scroll(dev));
    if (strcmp(property, "naturalScrollEnabledByDefault") == 0)
        return sd_bus_message_append(reply, "b",
            (int)libinput_device_config_scroll_get_default_natural_scroll_enabled(dev));
    if (strcmp(property, "naturalScroll") == 0)
        return sd_bus_message_append(reply, "b",
            (int)libinput_device_config_scroll_get_natural_scroll_enabled(dev));

    /* Scroll factor */
    if (strcmp(property, "scrollFactor") == 0)
        return sd_bus_message_append(reply, "d",
            cd_dbus_input_get_scroll_factor(dbus, sysname));

    /* Left-handed */
    if (strcmp(property, "supportsLeftHanded") == 0)
        return sd_bus_message_append(reply, "b",
            (int)libinput_device_config_left_handed_is_available(dev));
    if (strcmp(property, "leftHandedEnabledByDefault") == 0)
        return sd_bus_message_append(reply, "b",
            (int)libinput_device_config_left_handed_get_default(dev));
    if (strcmp(property, "leftHanded") == 0)
        return sd_bus_message_append(reply, "b",
            (int)libinput_device_config_left_handed_get(dev));

    /* Middle emulation */
    if (strcmp(property, "supportsMiddleEmulation") == 0)
        return sd_bus_message_append(reply, "b",
            (int)libinput_device_config_middle_emulation_is_available(dev));
    if (strcmp(property, "middleEmulationEnabledByDefault") == 0)
        return sd_bus_message_append(reply, "b",
            (int)(libinput_device_config_middle_emulation_get_default_enabled(dev)
                  == LIBINPUT_CONFIG_MIDDLE_EMULATION_ENABLED));
    if (strcmp(property, "middleEmulation") == 0)
        return sd_bus_message_append(reply, "b",
            (int)(libinput_device_config_middle_emulation_get_enabled(dev)
                  == LIBINPUT_CONFIG_MIDDLE_EMULATION_ENABLED));

    /* Disable events */
    if (strcmp(property, "supportsDisableEvents") == 0)
        return sd_bus_message_append(reply, "b",
            (int)(libinput_device_config_send_events_get_modes(dev)
                  & LIBINPUT_CONFIG_SEND_EVENTS_DISABLED));
    if (strcmp(property, "enabled") == 0)
        return sd_bus_message_append(reply, "b",
            (int)((libinput_device_config_send_events_get_mode(dev)
                   & LIBINPUT_CONFIG_SEND_EVENTS_DISABLED) == 0));

    /* Scroll on button down */
    if (strcmp(property, "supportsScrollOnButtonDown") == 0)
        return sd_bus_message_append(reply, "b",
            (int)(libinput_device_config_scroll_get_methods(dev)
                  & LIBINPUT_CONFIG_SCROLL_ON_BUTTON_DOWN));
    if (strcmp(property, "scrollOnButtonDownEnabledByDefault") == 0)
        return sd_bus_message_append(reply, "b",
            (int)(libinput_device_config_scroll_get_default_method(dev)
                  == LIBINPUT_CONFIG_SCROLL_ON_BUTTON_DOWN));
    if (strcmp(property, "scrollOnButtonDown") == 0)
        return sd_bus_message_append(reply, "b",
            (int)(libinput_device_config_scroll_get_method(dev)
                  == LIBINPUT_CONFIG_SCROLL_ON_BUTTON_DOWN));

    /* Supported buttons */
    if (strcmp(property, "supportedButtons") == 0) {
        int btn = 0;
        if (libinput_device_pointer_has_button(dev, BTN_LEFT))   btn |= 1;
        if (libinput_device_pointer_has_button(dev, BTN_RIGHT))  btn |= 2;
        if (libinput_device_pointer_has_button(dev, BTN_MIDDLE)) btn |= 4;
        return sd_bus_message_append(reply, "i", btn);
    }

    return sd_bus_error_setf(error, SD_BUS_ERROR_UNKNOWN_PROPERTY,
                              "Unknown property: %s", property);
}

/* ── Property SET ── */

static int device_property_set(
    sd_bus *bus, const char *path, const char *interface,
    const char *property, sd_bus_message *value,
    void *userdata, sd_bus_error *error)
{
    (void)bus; (void)interface;
    auto *dbus = static_cast<struct cd_dbus_input*>(userdata);
    const char *sysname = sys_name_from_path(path);
    if (!sysname)
        return sd_bus_error_setf(error, SD_BUS_ERROR_INVALID_ARGS, "Invalid path");

    libinput_device *dev = nullptr;
    {
        std::lock_guard<std::mutex> lock(dbus->mutex);
        auto it = dbus->devices.find(sysname);
        if (it != dbus->devices.end())
            dev = it->second.device;
    }
    if (!dev)
        return sd_bus_error_setf(error, SD_BUS_ERROR_UNKNOWN_OBJECT,
                                  "Device not found: %s", sysname);

    if (strcmp(property, "pointerAcceleration") == 0) {
        double val; int r = sd_bus_message_read(value, "d", &val);
        if (r < 0) return r;
        libinput_device_config_accel_set_speed(dev, val);
        wlr_log(WLR_INFO, "[dbus-input] %s: pointerAcceleration=%.3f", sysname, val);
        save_device_config(dbus, sysname, dev);
        return 0;
    }
    if (strcmp(property, "pointerAccelerationProfileFlat") == 0) {
        int val; int r = sd_bus_message_read(value, "b", &val);
        if (r < 0) return r;
        libinput_device_config_accel_set_profile(dev,
            val ? LIBINPUT_CONFIG_ACCEL_PROFILE_FLAT
                : LIBINPUT_CONFIG_ACCEL_PROFILE_ADAPTIVE);
        save_device_config(dbus, sysname, dev);
        return 0;
    }
    if (strcmp(property, "pointerAccelerationProfileAdaptive") == 0) {
        int val; int r = sd_bus_message_read(value, "b", &val);
        if (r < 0) return r;
        libinput_device_config_accel_set_profile(dev,
            val ? LIBINPUT_CONFIG_ACCEL_PROFILE_ADAPTIVE
                : LIBINPUT_CONFIG_ACCEL_PROFILE_FLAT);
        save_device_config(dbus, sysname, dev);
        return 0;
    }
    if (strcmp(property, "naturalScroll") == 0) {
        int val; int r = sd_bus_message_read(value, "b", &val);
        if (r < 0) return r;
        libinput_device_config_scroll_set_natural_scroll_enabled(dev, val);
        save_device_config(dbus, sysname, dev);
        return 0;
    }
    if (strcmp(property, "scrollFactor") == 0) {
        double val; int r = sd_bus_message_read(value, "d", &val);
        if (r < 0) return r;
        cd_dbus_input_set_scroll_factor(dbus, sysname, val);
        wlr_log(WLR_INFO, "[dbus-input] %s: scrollFactor=%.2f", sysname, val);
        save_device_config(dbus, sysname, dev);
        return 0;
    }
    if (strcmp(property, "leftHanded") == 0) {
        int val; int r = sd_bus_message_read(value, "b", &val);
        if (r < 0) return r;
        libinput_device_config_left_handed_set(dev, val);
        save_device_config(dbus, sysname, dev);
        return 0;
    }
    if (strcmp(property, "middleEmulation") == 0) {
        int val; int r = sd_bus_message_read(value, "b", &val);
        if (r < 0) return r;
        libinput_device_config_middle_emulation_set_enabled(dev,
            val ? LIBINPUT_CONFIG_MIDDLE_EMULATION_ENABLED
                : LIBINPUT_CONFIG_MIDDLE_EMULATION_DISABLED);
        save_device_config(dbus, sysname, dev);
        return 0;
    }
    if (strcmp(property, "enabled") == 0) {
        int val; int r = sd_bus_message_read(value, "b", &val);
        if (r < 0) return r;
        libinput_device_config_send_events_set_mode(dev,
            val ? LIBINPUT_CONFIG_SEND_EVENTS_ENABLED
                : LIBINPUT_CONFIG_SEND_EVENTS_DISABLED);
        return 0;
    }
    if (strcmp(property, "scrollOnButtonDown") == 0) {
        int val; int r = sd_bus_message_read(value, "b", &val);
        if (r < 0) return r;
        libinput_device_config_scroll_set_method(dev,
            val ? LIBINPUT_CONFIG_SCROLL_ON_BUTTON_DOWN
                : LIBINPUT_CONFIG_SCROLL_NO_SCROLL);
        save_device_config(dbus, sysname, dev);
        return 0;
    }

    return sd_bus_error_setf(error, SD_BUS_ERROR_PROPERTY_READ_ONLY,
                              "Property %s is read-only", property);
}

/* ── Manager property GET ── */

static int manager_property_get(
    sd_bus *bus, const char *path, const char *interface,
    const char *property, sd_bus_message *reply,
    void *userdata, sd_bus_error *error)
{
    (void)bus; (void)path; (void)interface;
    auto *dbus = static_cast<struct cd_dbus_input*>(userdata);

    if (strcmp(property, "devicesSysNames") == 0) {
        std::lock_guard<std::mutex> lock(dbus->mutex);
        int r = sd_bus_message_open_container(reply, 'a', "s");
        if (r < 0) return r;
        for (auto &[name, info] : dbus->devices) {
            r = sd_bus_message_append(reply, "s", name.c_str());
            if (r < 0) return r;
        }
        return sd_bus_message_close_container(reply);
    }

    return sd_bus_error_setf(error, SD_BUS_ERROR_UNKNOWN_PROPERTY,
                              "Unknown property: %s", property);
}

/* ── vtable definitions ── */

#define DEV_RO_S(n) SD_BUS_PROPERTY(n, "s", device_property_get, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE)
#define DEV_RO_B(n) SD_BUS_PROPERTY(n, "b", device_property_get, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE)
#define DEV_RO_D(n) SD_BUS_PROPERTY(n, "d", device_property_get, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE)
#define DEV_RO_I(n) SD_BUS_PROPERTY(n, "i", device_property_get, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE)
#define DEV_RW_B(n) SD_BUS_WRITABLE_PROPERTY(n, "b", device_property_get, device_property_set, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE)
#define DEV_RW_D(n) SD_BUS_WRITABLE_PROPERTY(n, "d", device_property_get, device_property_set, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE)

static const sd_bus_vtable s_device_vtable[] = {
    SD_BUS_VTABLE_START(0),
    DEV_RO_S("name"),
    DEV_RO_S("sysName"),
    DEV_RO_B("pointer"),
    DEV_RO_B("keyboard"),
    DEV_RO_B("touchpad"),
    DEV_RO_B("touch"),
    DEV_RO_B("supportsDisableEvents"),
    DEV_RW_B("enabled"),
    DEV_RO_I("supportedButtons"),
    DEV_RO_B("supportsPointerAcceleration"),
    DEV_RO_D("defaultPointerAcceleration"),
    DEV_RW_D("pointerAcceleration"),
    DEV_RO_B("supportsPointerAccelerationProfileFlat"),
    DEV_RO_B("defaultPointerAccelerationProfileFlat"),
    DEV_RW_B("pointerAccelerationProfileFlat"),
    DEV_RO_B("supportsPointerAccelerationProfileAdaptive"),
    DEV_RO_B("defaultPointerAccelerationProfileAdaptive"),
    DEV_RW_B("pointerAccelerationProfileAdaptive"),
    DEV_RO_B("supportsNaturalScroll"),
    DEV_RO_B("naturalScrollEnabledByDefault"),
    DEV_RW_B("naturalScroll"),
    DEV_RW_D("scrollFactor"),
    DEV_RO_B("supportsLeftHanded"),
    DEV_RO_B("leftHandedEnabledByDefault"),
    DEV_RW_B("leftHanded"),
    DEV_RO_B("supportsMiddleEmulation"),
    DEV_RO_B("middleEmulationEnabledByDefault"),
    DEV_RW_B("middleEmulation"),
    DEV_RO_B("supportsScrollOnButtonDown"),
    DEV_RO_B("scrollOnButtonDownEnabledByDefault"),
    DEV_RW_B("scrollOnButtonDown"),
    SD_BUS_VTABLE_END,
};

#undef DEV_RO_S
#undef DEV_RO_B
#undef DEV_RO_D
#undef DEV_RO_I
#undef DEV_RW_B
#undef DEV_RW_D

/* ════════════════════════════════════════════════════════════════
   D-Bus method: SetOutputMode(width, height, fps)
   Вызывается Sunshine prep-cmd скриптом при подключении Moonlight.
   ════════════════════════════════════════════════════════════════ */

static int method_set_output_mode(
    sd_bus_message *msg, void *userdata, sd_bus_error *error)
{
    auto *dbus = static_cast<struct cd_dbus_input*>(userdata);
    struct cd_server *server = dbus->server;
    if (!server)
        return sd_bus_error_setf(error, SD_BUS_ERROR_FAILED,
                                  "Server not initialized");

    uint32_t width = 0, height = 0, fps = 0;
    int r = sd_bus_message_read(msg, "uuu", &width, &height, &fps);
    if (r < 0) return r;

    /* Валидация */
    if (width == 0 || height == 0 || width > 7680 || height > 4320)
        return sd_bus_error_setf(error, SD_BUS_ERROR_INVALID_ARGS,
                                  "Invalid resolution %ux%u", width, height);
    if (fps == 0 || fps > 360)
        return sd_bus_error_setf(error, SD_BUS_ERROR_INVALID_ARGS,
                                  "Invalid fps %u", fps);

    uint32_t refresh_mhz = fps * 1000;

    /* Без изменений? */
    if ((int)width == server->cur_width &&
        (int)height == server->cur_height &&
        (int)refresh_mhz == server->cur_refresh) {
        wlr_log(WLR_INFO, "[SetOutputMode] Mode unchanged %ux%u@%uHz",
                width, height, fps);
        /* Prep-скрипт = начинается стрим: выходим из idle в любом случае */
        cd_idle_exit(server, "SetOutputMode");
        return sd_bus_reply_method_return(msg, "b", 1);
    }

    wlr_log(WLR_INFO, "[SetOutputMode] %ux%u@%uHz (refresh=%u mHz)",
            width, height, fps, refresh_mhz);

    /* 1. wlr_output commit с новым mode */
    if (server->output) {
        struct wlr_output_state state;
        wlr_output_state_init(&state);
        wlr_output_state_set_custom_mode(&state, width, height, refresh_mhz);
        if (!wlr_output_commit_state(server->output, &state)) {
            wlr_log(WLR_ERROR, "[SetOutputMode] wlr_output commit failed");
            wlr_output_state_finish(&state);
            return sd_bus_error_setf(error, SD_BUS_ERROR_FAILED,
                                      "wlr_output commit failed");
        }
        wlr_output_state_finish(&state);
    }

    /* 2. Обновляем runtime поля */
    server->cur_width = width;
    server->cur_height = height;
    server->cur_refresh = refresh_mhz;
    server->abs_synced = false;  /* re-sync absolute mouse origin after mode change */

    /* 3. xdg_toplevel resize для KWin */
    if (server->desktop_toplevel) {
        wlr_xdg_toplevel_set_size(server->desktop_toplevel, width, height);
        /* Повторно подтверждаем fullscreen — при смене режима KWin
         * должен переинициализировать геометрию и нотифицировать Plasma. */
        wlr_xdg_toplevel_set_fullscreen(server->desktop_toplevel, server->output);
        wlr_log(WLR_INFO, "[SetOutputMode] xdg_toplevel resized + fullscreen → %ux%u",
                width, height);
    }

    /* 4. Перерисовка */
    if (server->output)
        wlr_output_schedule_frame(server->output);

    cd_idle_exit(server, "SetOutputMode");

    wlr_log(WLR_INFO, "[SetOutputMode] Done. target=%dHz",
            refresh_mhz / 1000);

    return sd_bus_reply_method_return(msg, "b", 1);
}

/* ════════════════════════════════════════════════════════════════
   D-Bus method: SetIdle(idle)
   true  — сразу в idle (undo-скрипты после «Stop» в Moonlight).
   false — выйти из idle; если захвата так и не будет, авто-idle
           вернёт его через idle_timeout_sec.
   ════════════════════════════════════════════════════════════════ */

static int method_set_idle(
    sd_bus_message *msg, void *userdata, sd_bus_error *error)
{
    auto *dbus = static_cast<struct cd_dbus_input*>(userdata);
    struct cd_server *server = dbus->server;
    if (!server)
        return sd_bus_error_setf(error, SD_BUS_ERROR_FAILED,
                                  "Server not initialized");

    int idle = 0;
    int r = sd_bus_message_read(msg, "b", &idle);
    if (r < 0) return r;

    if (idle) cd_idle_enter(server, "D-Bus SetIdle");
    else      cd_idle_exit(server, "D-Bus SetIdle");

    return sd_bus_reply_method_return(msg, "b", server->idle ? 1 : 0);
}

static int manager_property_get_idle(
    sd_bus *bus, const char *path, const char *interface,
    const char *property, sd_bus_message *reply,
    void *userdata, sd_bus_error *error)
{
    (void)bus; (void)path; (void)interface; (void)property; (void)error;
    auto *dbus = static_cast<struct cd_dbus_input*>(userdata);
    int idle = dbus->server && dbus->server->idle;
    return sd_bus_message_append(reply, "b", idle);
}

/* ── Manager vtable ── */

static const sd_bus_vtable s_manager_vtable[] = {
    SD_BUS_VTABLE_START(0),
    SD_BUS_PROPERTY("devicesSysNames", "as", manager_property_get, 0,
                     SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_SIGNAL("deviceAdded", "s", 0),
    SD_BUS_SIGNAL("deviceRemoved", "s", 0),
    SD_BUS_METHOD("SetOutputMode", "uuu", "b", method_set_output_mode,
                   SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("SetIdle", "b", "b", method_set_idle,
                   SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_PROPERTY("Idle", "b", manager_property_get_idle, 0, 0),
    SD_BUS_VTABLE_END,
};

/* ════════════════════════════════════════════════════════════════
   Public API
   ════════════════════════════════════════════════════════════════ */

bool cd_dbus_input_init(struct cd_dbus_input *dbus) {
    int r = sd_bus_open_user(&dbus->bus);
    if (r < 0) {
        wlr_log(WLR_ERROR, "[dbus-input] Failed to connect to session bus: %s",
                strerror(-r));
        return false;
    }

    r = sd_bus_add_object_vtable(dbus->bus, &dbus->manager_slot,
        "/org/gamescope/Input",
        "org.gamescope.InputDeviceManager",
        s_manager_vtable, dbus);
    if (r < 0) {
        wlr_log(WLR_ERROR, "[dbus-input] Failed to register manager: %s",
                strerror(-r));
        return false;
    }

    r = sd_bus_request_name(dbus->bus, "org.gamescope.Input", 0);
    if (r < 0) {
        wlr_log(WLR_ERROR, "[dbus-input] Failed to acquire bus name: %s",
                strerror(-r));
        return false;
    }

    dbus->bus_fd = sd_bus_get_fd(dbus->bus);

    wlr_log(WLR_INFO, "[dbus-input] D-Bus service org.gamescope.Input registered");
    return true;
}

void cd_dbus_input_shutdown(struct cd_dbus_input *dbus) {
    if (!dbus->bus) return;

    sd_bus_release_name(dbus->bus, "org.gamescope.Input");

    {
        std::lock_guard<std::mutex> lock(dbus->mutex);
        for (auto &[name, info] : dbus->devices) {
            if (info.slot) sd_bus_slot_unref(info.slot);
            if (info.device) libinput_device_unref(info.device);
        }
        dbus->devices.clear();
    }

    if (dbus->manager_slot) {
        sd_bus_slot_unref(dbus->manager_slot);
        dbus->manager_slot = nullptr;
    }
    sd_bus_unref(dbus->bus);
    dbus->bus = nullptr;
}

void cd_dbus_input_process(struct cd_dbus_input *dbus) {
    if (!dbus->bus) return;
    for (;;) {
        int r = sd_bus_process(dbus->bus, nullptr);
        if (r <= 0) break;
    }
}

void cd_dbus_input_device_added(struct cd_dbus_input *dbus,
                                 struct libinput_device *dev) {
    const char *sysname = libinput_device_get_sysname(dev);
    const char *name = libinput_device_get_name(dev);
    if (!sysname) return;

    std::string path = "/org/gamescope/Input/Device/" + std::string(sysname);
    sd_bus_slot *slot = nullptr;

    int r = sd_bus_add_object_vtable(dbus->bus, &slot,
        path.c_str(), "org.gamescope.InputDevice",
        s_device_vtable, dbus);
    if (r < 0) {
        wlr_log(WLR_ERROR, "[dbus-input] Failed to register %s: %s",
                sysname, strerror(-r));
        return;
    }

    libinput_device_ref(dev);
    {
        std::lock_guard<std::mutex> lock(dbus->mutex);
        dbus->devices[sysname] = {dev, slot, kDefaultScrollFactor};
    }

    load_device_config(dbus, sysname, dev);

    /* D-Bus signal */
    sd_bus_emit_signal(dbus->bus,
        "/org/gamescope/Input",
        "org.gamescope.InputDeviceManager",
        "deviceAdded", "s", sysname);

    wlr_log(WLR_INFO, "[dbus-input] Device registered: %s (%s)",
            name ? name : "unknown", sysname);
}

void cd_dbus_input_device_removed(struct cd_dbus_input *dbus,
                                   struct libinput_device *dev) {
    const char *sysname = libinput_device_get_sysname(dev);
    if (!sysname) return;

    std::string key(sysname);
    {
        std::lock_guard<std::mutex> lock(dbus->mutex);
        auto it = dbus->devices.find(key);
        if (it == dbus->devices.end()) return;
        if (it->second.slot) sd_bus_slot_unref(it->second.slot);
        if (it->second.device) libinput_device_unref(it->second.device);
        dbus->devices.erase(it);
    }

    sd_bus_emit_signal(dbus->bus,
        "/org/gamescope/Input",
        "org.gamescope.InputDeviceManager",
        "deviceRemoved", "s", sysname);

    wlr_log(WLR_INFO, "[dbus-input] Device unregistered: %s", sysname);
}

double cd_dbus_input_get_scroll_factor(struct cd_dbus_input *dbus,
                                        const char *sysname) {
    std::lock_guard<std::mutex> lock(dbus->mutex);
    auto it = dbus->devices.find(sysname);
    if (it == dbus->devices.end()) return 1.0;
    return it->second.scroll_factor;
}

void cd_dbus_input_set_scroll_factor(struct cd_dbus_input *dbus,
                                      const char *sysname, double factor) {
    std::lock_guard<std::mutex> lock(dbus->mutex);
    auto it = dbus->devices.find(sysname);
    if (it != dbus->devices.end())
        it->second.scroll_factor = factor;
}
