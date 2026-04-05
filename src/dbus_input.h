/*
 * cloud-desktop-host — dbus_input.h
 * D-Bus сервис org.gamescope.Input для KCM Cloud Mouse.
 * Экспонирует libinput устройства через sd-bus.
 */
#ifndef CD_DBUS_INPUT_H
#define CD_DBUS_INPUT_H

#include <systemd/sd-bus.h>
#include <libinput.h>
#include <map>
#include <string>
#include <vector>
#include <mutex>

struct cd_server;  /* forward declaration */

struct cd_dbus_input {
    struct cd_server *server = nullptr;  /* back-pointer для SetOutputMode */
    sd_bus *bus = nullptr;
    sd_bus_slot *manager_slot = nullptr;
    int bus_fd = -1;

    struct device_info {
        libinput_device *device;
        sd_bus_slot *slot;
        double scroll_factor;
    };

    std::map<std::string, device_info> devices;
    std::mutex mutex;
};

/* API */
bool cd_dbus_input_init(struct cd_dbus_input *dbus);
void cd_dbus_input_shutdown(struct cd_dbus_input *dbus);
void cd_dbus_input_process(struct cd_dbus_input *dbus);

void cd_dbus_input_device_added(struct cd_dbus_input *dbus,
                                 struct libinput_device *dev);
void cd_dbus_input_device_removed(struct cd_dbus_input *dbus,
                                   struct libinput_device *dev);

/* Scroll factor (in-memory, нет в libinput API) */
double cd_dbus_input_get_scroll_factor(struct cd_dbus_input *dbus,
                                        const char *sysname);
void cd_dbus_input_set_scroll_factor(struct cd_dbus_input *dbus,
                                      const char *sysname, double factor);

#endif /* CD_DBUS_INPUT_H */
