#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define SCREEN_MAX_X 1403
#define SCREEN_MAX_Y 1871
#define TOUCH_MAX_X 1776
#define TOUCH_MAX_Y 2400

static void fail(const char *message)
{
    fprintf(stderr, "paperctl-tap: %s: %s\n", message, strerror(errno));
    exit(EXIT_FAILURE);
}

static void sleep_milliseconds(long milliseconds)
{
    struct timespec duration = {
        .tv_sec = milliseconds / 1000,
        .tv_nsec = (milliseconds % 1000) * 1000000L,
    };

    while (nanosleep(&duration, &duration) == -1 && errno == EINTR) {
    }
}

static void emit_event(int file_descriptor, unsigned short type,
                       unsigned short code, int value)
{
    struct input_event event = {
        .type = type,
        .code = code,
        .value = value,
    };

    if (write(file_descriptor, &event, sizeof(event)) != (ssize_t)sizeof(event)) {
        fail("could not emit input event");
    }
}

static void enable_event(int file_descriptor, unsigned long request, int value)
{
    if (ioctl(file_descriptor, request, value) < 0) {
        fail("could not configure uinput event capability");
    }
}

static void configure_axis(int file_descriptor, unsigned short code, int maximum)
{
    struct uinput_abs_setup setup = {
        .code = code,
        .absinfo = {
            .minimum = 0,
            .maximum = maximum,
            .resolution = 1,
        },
    };

    if (ioctl(file_descriptor, UI_ABS_SETUP, &setup) < 0) {
        fail("could not configure uinput axis");
    }
}

static long parse_coordinate(const char *text, int maximum, const char *name)
{
    char *end = NULL;
    errno = 0;
    const long value = strtol(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value < 0 || value > maximum) {
        fprintf(stderr, "paperctl-tap: %s must be between 0 and %d\n", name, maximum);
        exit(EXIT_FAILURE);
    }
    return value;
}

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "Usage: %s X Y\n", argv[0]);
        fprintf(stderr, "Coordinates use the 1404x1872 screenshot space.\n");
        return EXIT_FAILURE;
    }

    const int x = (int)parse_coordinate(argv[1], SCREEN_MAX_X, "X");
    const int y = (int)parse_coordinate(argv[2], SCREEN_MAX_Y, "Y");
    const int touch_x = (x * TOUCH_MAX_X) / SCREEN_MAX_X;
    const int touch_y = (y * TOUCH_MAX_Y) / SCREEN_MAX_Y;
    const int device = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (device < 0) {
        fail("could not open /dev/uinput");
    }

    enable_event(device, UI_SET_EVBIT, EV_SYN);
    enable_event(device, UI_SET_EVBIT, EV_KEY);
    enable_event(device, UI_SET_KEYBIT, BTN_TOUCH);
    enable_event(device, UI_SET_EVBIT, EV_ABS);
    enable_event(device, UI_SET_ABSBIT, ABS_MT_SLOT);
    enable_event(device, UI_SET_ABSBIT, ABS_MT_TOUCH_MAJOR);
    enable_event(device, UI_SET_ABSBIT, ABS_MT_TRACKING_ID);
    enable_event(device, UI_SET_ABSBIT, ABS_MT_POSITION_X);
    enable_event(device, UI_SET_ABSBIT, ABS_MT_POSITION_Y);
    enable_event(device, UI_SET_ABSBIT, ABS_MT_TOOL_TYPE);
    enable_event(device, UI_SET_ABSBIT, ABS_MT_PRESSURE);
    enable_event(device, UI_SET_ABSBIT, ABS_MT_DISTANCE);
    enable_event(device, UI_SET_PROPBIT, INPUT_PROP_DIRECT);

    configure_axis(device, ABS_MT_SLOT, 9);
    configure_axis(device, ABS_MT_TOUCH_MAJOR, 255);
    configure_axis(device, ABS_MT_TRACKING_ID, 65535);
    configure_axis(device, ABS_MT_POSITION_X, TOUCH_MAX_X);
    configure_axis(device, ABS_MT_POSITION_Y, TOUCH_MAX_Y);
    configure_axis(device, ABS_MT_TOOL_TYPE, 2);
    configure_axis(device, ABS_MT_PRESSURE, 255);
    configure_axis(device, ABS_MT_DISTANCE, 255);

    struct uinput_setup setup = {
        .id = {
            .bustype = BUS_VIRTUAL,
            .vendor = 0x2edd,
            .product = 0x5050,
            .version = 1,
        },
    };
    snprintf(setup.name, UINPUT_MAX_NAME_SIZE, "paperctl virtual touchscreen");

    if (ioctl(device, UI_DEV_SETUP, &setup) < 0) {
        fail("could not configure virtual touchscreen");
    }
    if (ioctl(device, UI_DEV_CREATE) < 0) {
        fail("could not create virtual touchscreen");
    }

    /* Allow Qt's input discovery enough time to observe this hotplug device. */
    sleep_milliseconds(2500);

    emit_event(device, EV_ABS, ABS_MT_SLOT, 0);
    emit_event(device, EV_ABS, ABS_MT_TRACKING_ID, 1);
    emit_event(device, EV_ABS, ABS_MT_TOUCH_MAJOR, 10);
    emit_event(device, EV_ABS, ABS_MT_POSITION_X, touch_x);
    emit_event(device, EV_ABS, ABS_MT_POSITION_Y, touch_y);
    emit_event(device, EV_ABS, ABS_MT_TOOL_TYPE, MT_TOOL_FINGER);
    emit_event(device, EV_ABS, ABS_MT_PRESSURE, 100);
    emit_event(device, EV_ABS, ABS_MT_DISTANCE, 0);
    emit_event(device, EV_KEY, BTN_TOUCH, 1);
    emit_event(device, EV_SYN, SYN_REPORT, 0);

    sleep_milliseconds(100);

    emit_event(device, EV_ABS, ABS_MT_SLOT, 0);
    emit_event(device, EV_ABS, ABS_MT_PRESSURE, 0);
    emit_event(device, EV_ABS, ABS_MT_TOUCH_MAJOR, 0);
    emit_event(device, EV_ABS, ABS_MT_TRACKING_ID, -1);
    emit_event(device, EV_KEY, BTN_TOUCH, 0);
    emit_event(device, EV_SYN, SYN_REPORT, 0);

    sleep_milliseconds(750);
    if (ioctl(device, UI_DEV_DESTROY) < 0) {
        fail("could not destroy virtual touchscreen");
    }
    close(device);
    return EXIT_SUCCESS;
}
