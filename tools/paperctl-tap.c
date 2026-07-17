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

static void emit_position(int device, int x, int y)
{
    const int touch_x = (x * TOUCH_MAX_X) / SCREEN_MAX_X;
    const int touch_y = (y * TOUCH_MAX_Y) / SCREEN_MAX_Y;
    emit_event(device, EV_ABS, ABS_MT_POSITION_X, touch_x);
    emit_event(device, EV_ABS, ABS_MT_POSITION_Y, touch_y);
    emit_event(device, EV_SYN, SYN_REPORT, 0);
}

static int create_touchscreen(void)
{
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
    return device;
}

static void perform_gesture(int device, int start_x, int start_y, int end_x,
                            int end_y, long duration, bool is_swipe)
{

    emit_event(device, EV_ABS, ABS_MT_SLOT, 0);
    emit_event(device, EV_ABS, ABS_MT_TRACKING_ID, 1);
    emit_event(device, EV_ABS, ABS_MT_TOUCH_MAJOR, 10);
    emit_event(device, EV_ABS, ABS_MT_POSITION_X, (start_x * TOUCH_MAX_X) / SCREEN_MAX_X);
    emit_event(device, EV_ABS, ABS_MT_POSITION_Y, (start_y * TOUCH_MAX_Y) / SCREEN_MAX_Y);
    emit_event(device, EV_ABS, ABS_MT_TOOL_TYPE, MT_TOOL_FINGER);
    emit_event(device, EV_ABS, ABS_MT_PRESSURE, 100);
    emit_event(device, EV_ABS, ABS_MT_DISTANCE, 0);
    emit_event(device, EV_KEY, BTN_TOUCH, 1);
    emit_event(device, EV_SYN, SYN_REPORT, 0);

    if (is_swipe) {
        const int steps = 20;
        for (int step = 1; step <= steps; step++) {
            const int x = start_x + ((end_x - start_x) * step) / steps;
            const int y = start_y + ((end_y - start_y) * step) / steps;
            sleep_milliseconds(duration / steps);
            emit_position(device, x, y);
        }
    } else {
        sleep_milliseconds(duration);
    }

    emit_event(device, EV_ABS, ABS_MT_SLOT, 0);
    emit_event(device, EV_ABS, ABS_MT_PRESSURE, 0);
    emit_event(device, EV_ABS, ABS_MT_TOUCH_MAJOR, 0);
    emit_event(device, EV_ABS, ABS_MT_TRACKING_ID, -1);
    emit_event(device, EV_KEY, BTN_TOUCH, 0);
    emit_event(device, EV_SYN, SYN_REPORT, 0);

    /* Let the consumer observe release before acknowledging the command. */
    sleep_milliseconds(50);
}

static void destroy_touchscreen(int device)
{
    if (ioctl(device, UI_DEV_DESTROY) < 0) {
        fail("could not destroy virtual touchscreen");
    }
    close(device);
}

static int serve_commands(void)
{
    const int device = create_touchscreen();
    char line[256];
    puts("READY");
    fflush(stdout);

    while (fgets(line, sizeof(line), stdin) != NULL) {
        char *save = NULL;
        char *tokens[7] = {0};
        size_t count = 0;
        for (char *token = strtok_r(line, " \t\r\n", &save);
             token != NULL && count < 7;
             token = strtok_r(NULL, " \t\r\n", &save)) {
            tokens[count++] = token;
        }

        if (count == 3 && strcmp(tokens[0], "tap") == 0) {
            const int x = (int)parse_coordinate(tokens[1], SCREEN_MAX_X, "X");
            const int y = (int)parse_coordinate(tokens[2], SCREEN_MAX_Y, "Y");
            perform_gesture(device, x, y, x, y, 100, false);
        } else if (count == 6 && strcmp(tokens[0], "swipe") == 0) {
            const int x1 = (int)parse_coordinate(tokens[1], SCREEN_MAX_X, "X1");
            const int y1 = (int)parse_coordinate(tokens[2], SCREEN_MAX_Y, "Y1");
            const int x2 = (int)parse_coordinate(tokens[3], SCREEN_MAX_X, "X2");
            const int y2 = (int)parse_coordinate(tokens[4], SCREEN_MAX_Y, "Y2");
            const long duration = parse_coordinate(tokens[5], 5000, "DURATION_MS");
            if (duration < 100) {
                fprintf(stderr, "paperctl-tap: DURATION_MS must be between 100 and 5000\n");
                destroy_touchscreen(device);
                return EXIT_FAILURE;
            }
            perform_gesture(device, x1, y1, x2, y2, duration, true);
        } else {
            fprintf(stderr, "paperctl-tap: invalid serve command\n");
            destroy_touchscreen(device);
            return EXIT_FAILURE;
        }
        puts("OK");
        fflush(stdout);
    }

    destroy_touchscreen(device);
    return EXIT_SUCCESS;
}

int main(int argc, char **argv)
{
    if (argc == 2 && strcmp(argv[1], "--serve") == 0) {
        return serve_commands();
    }
    if (argc != 3 && argc != 6) {
        fprintf(stderr, "Usage: %s X Y\n", argv[0]);
        fprintf(stderr, "       %s X1 Y1 X2 Y2 DURATION_MS\n", argv[0]);
        fprintf(stderr, "       %s --serve\n", argv[0]);
        fprintf(stderr, "Coordinates use the 1404x1872 screenshot space.\n");
        return EXIT_FAILURE;
    }

    const int start_x = (int)parse_coordinate(argv[1], SCREEN_MAX_X, "X1");
    const int start_y = (int)parse_coordinate(argv[2], SCREEN_MAX_Y, "Y1");
    const bool is_swipe = argc == 6;
    const int end_x = is_swipe ? (int)parse_coordinate(argv[3], SCREEN_MAX_X, "X2") : start_x;
    const int end_y = is_swipe ? (int)parse_coordinate(argv[4], SCREEN_MAX_Y, "Y2") : start_y;
    const long duration = is_swipe ? parse_coordinate(argv[5], 5000, "DURATION_MS") : 100;
    if (is_swipe && duration < 100) {
        fprintf(stderr, "paperctl-tap: DURATION_MS must be between 100 and 5000\n");
        return EXIT_FAILURE;
    }

    const int device = create_touchscreen();
    perform_gesture(device, start_x, start_y, end_x, end_y, duration, is_swipe);

    /* Preserve the one-shot helper's conservative hot-unplug delay. */
    sleep_milliseconds(750);
    destroy_touchscreen(device);
    return EXIT_SUCCESS;
}
