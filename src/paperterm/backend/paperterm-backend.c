#define _GNU_SOURCE
#define _XOPEN_SOURCE 600

#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <json-c/json.h>
#include <poll.h>
#include <pty.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <vterm.h>

#define CONFIG_PATH "/home/root/.config/paperterm/profiles.json"
#define TAILSCALE_ROOT "/home/root/.local/share/paperboard/tailscale"
#define TAILSCALE_SOCKET_ARGUMENT "--socket=/home/root/.local/share/paperboard/tailscale/runtime/tailscaled.sock"
#define DBCLIENT_PATH "/usr/bin/dbclient"
#define PAPERTERM_BACKEND_PATH "/home/root/xovi/exthome/appload/paperterm/backend/entry"
#define TAILSCALE_PROXY_COMMAND PAPERTERM_BACKEND_PATH " --tailscale-proxy-env"
#define TAILSCALE_PROXY_HOST_ENV "PAPERTERM_PROXY_HOST"
#define TAILSCALE_PROXY_PORT_ENV "PAPERTERM_PROXY_PORT"
#define MAX_CONFIG_SIZE (64U * 1024U)
#define MAX_MESSAGE_SIZE (256U * 1024U)
#define MAX_PROFILES 32
#define MAX_SCROLLBACK 400
#define DEFAULT_ROWS 30
#define DEFAULT_COLS 100

enum {
    MSG_START = 1,
    MSG_INPUT = 2,
    MSG_KEY = 3,
    MSG_RESIZE = 4,
    MSG_DISCONNECT = 5,
    MSG_REFRESH = 6,
    MSG_GET_PROFILES = 7,
    MSG_PROFILES = 101,
    MSG_SCREEN = 102,
    MSG_STATUS = 103,
    MSG_ERROR = 104,
    MSG_SESSION_ENDED = 106,
};

#define MSG_SYSTEM_TERMINATE UINT32_MAX
#define MSG_SYSTEM_NEW_COORDINATOR (UINT32_MAX - 1U)

struct message_header { uint32_t type; uint32_t length; };

enum profile_mode { PROFILE_TAILSCALE_SSH, PROFILE_TAILSCALE_KEY, PROFILE_SSH, PROFILE_LOCAL };
enum profile_session { PROFILE_SESSION_DEFAULT, PROFILE_SESSION_WINDOWS_POWERSHELL };

struct profile {
    char id[65];
    char label[97];
    enum profile_mode mode;
    enum profile_session session;
    char user[65];
    char host[256];
    char identity_file[512];
    int port;
};

struct app_config {
    int allow_local_shell;
    size_t count;
    struct profile profiles[MAX_PROFILES];
};

static int socket_fd = -1;
static int pty_fd = -1;
static pid_t child_pid = -1;
static int rows = DEFAULT_ROWS;
static int cols = DEFAULT_COLS;
static int stopping = 0;
static int screen_dirty = 1;
static int cursor_row = 0;
static int cursor_col = 0;
static int cursor_visible = 1;
static VTerm *terminal = NULL;
static VTermScreen *screen = NULL;
static struct app_config config;
static char *scrollback[MAX_SCROLLBACK];
static size_t scrollback_start = 0;
static size_t scrollback_count = 0;

static void send_message(uint32_t type, const char *contents) {
    struct message_header header;
    size_t length = contents == NULL ? 0 : strlen(contents);
    if (socket_fd < 0 || length > MAX_MESSAGE_SIZE) return;
    header.type = type;
    header.length = (uint32_t)length;
    if (send(socket_fd, &header, sizeof(header), MSG_NOSIGNAL) != (ssize_t)sizeof(header)) return;
    if (length > 0) (void)send(socket_fd, contents, length, MSG_NOSIGNAL);
}

static int valid_name(const char *value, size_t maximum) {
    size_t index, length;
    if (value == NULL) return 0;
    length = strlen(value);
    if (length == 0 || length > maximum) return 0;
    for (index = 0; index < length; index++) {
        unsigned char c = (unsigned char)value[index];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.')) return 0;
    }
    return 1;
}

static int valid_host(const char *value) {
    size_t index, length;
    if (value == NULL) return 0;
    length = strlen(value);
    if (length == 0 || length > 255) return 0;
    for (index = 0; index < length; index++) {
        unsigned char c = (unsigned char)value[index];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == ':')) return 0;
    }
    return 1;
}

static int valid_absolute_path(const char *value) {
    size_t index, length;
    if (value == NULL || value[0] != '/') return 0;
    length = strlen(value);
    if (length < 2 || length > 511 || strstr(value, "..") != NULL) return 0;
    for (index = 0; index < length; index++) {
        unsigned char c = (unsigned char)value[index];
        if (c <= 0x20 || c == 0x7f || c == '\\' || c == '"' || c == '\'') return 0;
    }
    return 1;
}

static int json_string(struct json_object *object, const char *key, const char **value) {
    struct json_object *field;
    if (!json_object_object_get_ex(object, key, &field) ||
        json_object_get_type(field) != json_type_string) return -1;
    *value = json_object_get_string(field);
    return 0;
}

static int read_config(char *error, size_t error_size) {
    struct stat metadata;
    FILE *file;
    char *contents;
    size_t count, index;
    struct json_object *root = NULL, *profiles = NULL, *allow = NULL;

    memset(&config, 0, sizeof(config));
    if (lstat(CONFIG_PATH, &metadata) != 0) {
        snprintf(error, error_size, "No profiles are installed. Configure PaperTerm from the trusted host.");
        return -1;
    }
    if (!S_ISREG(metadata.st_mode) || metadata.st_uid != 0 || (metadata.st_mode & 077) != 0 ||
        metadata.st_size <= 0 || metadata.st_size > (off_t)MAX_CONFIG_SIZE) {
        snprintf(error, error_size, "Profiles must be a root-owned regular file with mode 0600.");
        return -1;
    }
    contents = calloc(1, (size_t)metadata.st_size + 1);
    if (contents == NULL) return -1;
    file = fopen(CONFIG_PATH, "r");
    if (file == NULL) { free(contents); return -1; }
    count = fread(contents, 1, (size_t)metadata.st_size, file);
    fclose(file);
    contents[count] = '\0';
    root = json_tokener_parse(contents);
    free(contents);
    if (root == NULL || json_object_get_type(root) != json_type_object ||
        !json_object_object_get_ex(root, "profiles", &profiles) ||
        json_object_get_type(profiles) != json_type_array) {
        snprintf(error, error_size, "Profiles JSON is invalid.");
        if (root != NULL) json_object_put(root);
        return -1;
    }
    if (json_object_object_get_ex(root, "allow_local_shell", &allow))
        config.allow_local_shell = json_object_get_boolean(allow);
    config.count = json_object_array_length(profiles);
    if (config.count > MAX_PROFILES) config.count = MAX_PROFILES;
    for (index = 0; index < config.count; index++) {
        struct json_object *item = json_object_array_get_idx(profiles, index), *port = NULL, *session = NULL;
        const char *id = NULL, *label = NULL, *mode = NULL, *user = NULL, *host = NULL, *identity = NULL;
        struct profile *profile = &config.profiles[index];
        if (item == NULL || json_object_get_type(item) != json_type_object ||
            json_string(item, "id", &id) != 0 || json_string(item, "label", &label) != 0 ||
            json_string(item, "mode", &mode) != 0 || !valid_name(id, 64) ||
            strlen(label) == 0 || strlen(label) > 96) goto invalid;
        snprintf(profile->id, sizeof(profile->id), "%s", id);
        snprintf(profile->label, sizeof(profile->label), "%s", label);
        profile->port = 22;
        if (strcmp(mode, "local") == 0) {
            if (!config.allow_local_shell) goto invalid;
            profile->mode = PROFILE_LOCAL;
            continue;
        }
        if (json_string(item, "user", &user) != 0 || json_string(item, "host", &host) != 0 ||
            !valid_name(user, 64) || !valid_host(host)) goto invalid;
        snprintf(profile->user, sizeof(profile->user), "%s", user);
        snprintf(profile->host, sizeof(profile->host), "%s", host);
        if (json_object_object_get_ex(item, "session", &session)) {
            const char *session_name;
            if (json_object_get_type(session) != json_type_string) goto invalid;
            session_name = json_object_get_string(session);
            if (strcmp(session_name, "windows-powershell") == 0)
                profile->session = PROFILE_SESSION_WINDOWS_POWERSHELL;
            else goto invalid;
            if (strcmp(mode, "tailscale-ssh") != 0 && strcmp(mode, "tailscale-key") != 0) goto invalid;
        }
        if (strcmp(mode, "tailscale-ssh") == 0) profile->mode = PROFILE_TAILSCALE_SSH;
        else if (strcmp(mode, "tailscale-key") == 0) {
            profile->mode = PROFILE_TAILSCALE_KEY;
            if (json_string(item, "identity_file", &identity) != 0 || !valid_absolute_path(identity)) goto invalid;
            snprintf(profile->identity_file, sizeof(profile->identity_file), "%s", identity);
        }
        else if (strcmp(mode, "ssh") == 0) {
            profile->mode = PROFILE_SSH;
            if (json_string(item, "identity_file", &identity) != 0 || !valid_absolute_path(identity)) goto invalid;
            snprintf(profile->identity_file, sizeof(profile->identity_file), "%s", identity);
            if (json_object_object_get_ex(item, "port", &port)) profile->port = json_object_get_int(port);
            if (profile->port < 1 || profile->port > 65535) goto invalid;
        } else goto invalid;
    }
    json_object_put(root);
    return 0;

invalid:
    snprintf(error, error_size, "A profile contains an invalid or unsafe value.");
    json_object_put(root);
    memset(&config, 0, sizeof(config));
    return -1;
}

static void send_profiles(const char *config_error) {
    struct json_object *root = json_object_new_object();
    struct json_object *items = json_object_new_array();
    size_t index;
    json_object_object_add(root, "profiles", items);
    if (config_error != NULL && *config_error != '\0')
        json_object_object_add(root, "notice", json_object_new_string(config_error));
    for (index = 0; index < config.count; index++) {
        struct json_object *item = json_object_new_object();
        json_object_object_add(item, "id", json_object_new_string(config.profiles[index].id));
        json_object_object_add(item, "label", json_object_new_string(config.profiles[index].label));
        json_object_object_add(item, "mode", json_object_new_string(
            config.profiles[index].mode == PROFILE_LOCAL ? "local" :
            config.profiles[index].mode == PROFILE_SSH ? "ssh" :
            config.profiles[index].mode == PROFILE_TAILSCALE_KEY ? "tailscale-key" : "tailscale-ssh"));
        json_object_array_add(items, item);
    }
    send_message(MSG_PROFILES, json_object_to_json_string_ext(root, JSON_C_TO_STRING_PLAIN));
    json_object_put(root);
}

static size_t append_utf8(char *output, size_t offset, size_t capacity, uint32_t codepoint) {
    if (codepoint == 0) codepoint = ' ';
    if (codepoint <= 0x7f && offset + 1 < capacity) output[offset++] = (char)codepoint;
    else if (codepoint <= 0x7ff && offset + 2 < capacity) {
        output[offset++] = (char)(0xc0 | (codepoint >> 6)); output[offset++] = (char)(0x80 | (codepoint & 0x3f));
    } else if (codepoint <= 0xffff && offset + 3 < capacity) {
        output[offset++] = (char)(0xe0 | (codepoint >> 12)); output[offset++] = (char)(0x80 | ((codepoint >> 6) & 0x3f));
        output[offset++] = (char)(0x80 | (codepoint & 0x3f));
    } else if (codepoint <= 0x10ffff && offset + 4 < capacity) {
        output[offset++] = (char)(0xf0 | (codepoint >> 18)); output[offset++] = (char)(0x80 | ((codepoint >> 12) & 0x3f));
        output[offset++] = (char)(0x80 | ((codepoint >> 6) & 0x3f)); output[offset++] = (char)(0x80 | (codepoint & 0x3f));
    }
    return offset;
}

static char *cells_to_line(int cell_count, const VTermScreenCell *cells) {
    size_t capacity = (size_t)cell_count * VTERM_MAX_CHARS_PER_CELL * 4 + 1, offset = 0, trim;
    char *line = calloc(1, capacity);
    int column;
    if (line == NULL) return NULL;
    for (column = 0; column < cell_count; column++) {
        size_t character;
        if (cells[column].chars[0] == (uint32_t)-1) continue;
        if (cells[column].chars[0] == 0) offset = append_utf8(line, offset, capacity, ' ');
        else for (character = 0; character < VTERM_MAX_CHARS_PER_CELL && cells[column].chars[character] != 0; character++)
            offset = append_utf8(line, offset, capacity, cells[column].chars[character]);
    }
    trim = offset;
    while (trim > 0 && line[trim - 1] == ' ') trim--;
    line[trim] = '\0';
    return line;
}

static int on_damage(VTermRect rect, void *user) {
    (void)rect; (void)user; screen_dirty = 1; return 1;
}

static int on_cursor(VTermPos position, VTermPos old_position, int visible, void *user) {
    (void)old_position; (void)user;
    cursor_row = position.row; cursor_col = position.col; cursor_visible = visible; screen_dirty = 1; return 1;
}

static int on_scrollback_push(int cell_count, const VTermScreenCell *cells, void *user) {
    char *line;
    size_t slot;
    (void)user;
    line = cells_to_line(cell_count, cells);
    if (line == NULL) return 0;
    if (scrollback_count == MAX_SCROLLBACK) {
        free(scrollback[scrollback_start]);
        scrollback[scrollback_start] = NULL;
        scrollback_start = (scrollback_start + 1) % MAX_SCROLLBACK;
        scrollback_count--;
    }
    slot = (scrollback_start + scrollback_count) % MAX_SCROLLBACK;
    scrollback[slot] = line;
    scrollback_count++;
    screen_dirty = 1;
    return 1;
}

static int on_scrollback_pop(int cell_count, VTermScreenCell *cells, void *user) {
    (void)cell_count; (void)cells; (void)user; return 0;
}

static int on_scrollback_clear(void *user) {
    size_t index;
    (void)user;
    for (index = 0; index < scrollback_count; index++)
        free(scrollback[(scrollback_start + index) % MAX_SCROLLBACK]);
    memset(scrollback, 0, sizeof(scrollback));
    scrollback_start = scrollback_count = 0;
    screen_dirty = 1;
    return 1;
}

static int write_all(int descriptor, const char *bytes, size_t length) {
    size_t offset = 0;
    while (offset < length) {
        ssize_t written = write(descriptor, bytes + offset, length - offset);
        if (written > 0) offset += (size_t)written;
        else if (written < 0 && errno == EINTR) continue;
        else if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
        else return -1;
    }
    return 0;
}

static void terminal_output(const char *bytes, size_t length, void *user) {
    (void)user;
    if (pty_fd >= 0 && length > 0) (void)write_all(pty_fd, bytes, length);
}

static void free_terminal(void) {
    if (terminal != NULL) vterm_free(terminal);
    terminal = NULL; screen = NULL;
}

static int create_terminal(void) {
    static const VTermScreenCallbacks callbacks = {
        .damage = on_damage, .movecursor = on_cursor,
        .sb_pushline = on_scrollback_push, .sb_popline = on_scrollback_pop,
        .sb_clear = on_scrollback_clear,
    };
    free_terminal();
    terminal = vterm_new(rows, cols);
    if (terminal == NULL) return -1;
    vterm_set_utf8(terminal, 1);
    vterm_output_set_callback(terminal, terminal_output, NULL);
    screen = vterm_obtain_screen(terminal);
    vterm_screen_set_callbacks(screen, &callbacks, NULL);
    vterm_screen_enable_altscreen(screen, 1);
    vterm_screen_enable_reflow(screen, true);
    vterm_screen_set_damage_merge(screen, VTERM_DAMAGE_SCREEN);
    vterm_screen_reset(screen, 1);
    screen_dirty = 1;
    return 0;
}

static void send_screen(void) {
    struct json_object *root, *lines;
    int row, column;
    size_t index;
    if (screen == NULL) return;
    vterm_screen_flush_damage(screen);
    root = json_object_new_object();
    lines = json_object_new_array();
    for (index = 0; index < scrollback_count; index++) {
        json_object_array_add(lines, json_object_new_string(scrollback[(scrollback_start + index) % MAX_SCROLLBACK]));
    }
    for (row = 0; row < rows; row++) {
        VTermScreenCell *cells = calloc((size_t)cols, sizeof(*cells));
        char *line;
        if (cells == NULL) continue;
        for (column = 0; column < cols; column++)
            (void)vterm_screen_get_cell(screen, (VTermPos){ .row = row, .col = column }, &cells[column]);
        line = cells_to_line(cols, cells);
        if (line != NULL) { json_object_array_add(lines, json_object_new_string(line)); free(line); }
        free(cells);
    }
    json_object_object_add(root, "lines", lines);
    json_object_object_add(root, "rows", json_object_new_int(rows));
    json_object_object_add(root, "cols", json_object_new_int(cols));
    json_object_object_add(root, "cursor_row", json_object_new_int((int)scrollback_count + cursor_row));
    json_object_object_add(root, "cursor_col", json_object_new_int(cursor_col));
    json_object_object_add(root, "cursor_visible", json_object_new_boolean(cursor_visible));
    json_object_object_add(root, "connected", json_object_new_boolean(child_pid > 0));
    send_message(MSG_SCREEN, json_object_to_json_string_ext(root, JSON_C_TO_STRING_PLAIN));
    json_object_put(root);
    screen_dirty = 0;
}

static struct profile *find_profile(const char *id) {
    size_t index;
    for (index = 0; index < config.count; index++)
        if (strcmp(config.profiles[index].id, id) == 0) return &config.profiles[index];
    return NULL;
}

static int find_tailscale_path(char *output, size_t output_size) {
    DIR *directory;
    struct dirent *entry;
    char candidate[512], selected[512] = "";
    directory = opendir(TAILSCALE_ROOT);
    if (directory == NULL) return -1;
    while ((entry = readdir(directory)) != NULL) {
        size_t index;
        int valid = entry->d_name[0] != '\0' && entry->d_name[0] != '.';
        for (index = 0; valid && entry->d_name[index] != '\0'; index++) {
            char c = entry->d_name[index];
            if (!((c >= '0' && c <= '9') || c == '.')) valid = 0;
        }
        if (!valid || snprintf(candidate, sizeof(candidate), "%s/%s/tailscale", TAILSCALE_ROOT, entry->d_name) >= (int)sizeof(candidate)) continue;
        if (access(candidate, X_OK) == 0 && (selected[0] == '\0' || strcmp(candidate, selected) > 0))
            snprintf(selected, sizeof(selected), "%s", candidate);
    }
    closedir(directory);
    if (selected[0] == '\0' || strlen(selected) >= output_size) return -1;
    snprintf(output, output_size, "%s", selected);
    return 0;
}

static int start_profile(struct profile *profile) {
    struct winsize size = { .ws_row = (unsigned short)rows, .ws_col = (unsigned short)cols };
    char destination[322], port[8], tailscale_path[512];
    char *argv[24];
    int argc = 0;
    if (profile == NULL || child_pid > 0 || create_terminal() != 0) return -1;
    snprintf(destination, sizeof(destination), "%s@%s", profile->user, profile->host);
    if (profile->mode == PROFILE_TAILSCALE_SSH || profile->mode == PROFILE_TAILSCALE_KEY) {
        if (find_tailscale_path(tailscale_path, sizeof(tailscale_path)) != 0 ||
            access(DBCLIENT_PATH, X_OK) != 0) return -1;
        argv[argc++] = (char *)DBCLIENT_PATH; argv[argc++] = "-t";
        argv[argc++] = "-o"; argv[argc++] = "StrictHostKeyChecking=yes";
        argv[argc++] = "-J"; argv[argc++] = (char *)TAILSCALE_PROXY_COMMAND;
        if (profile->mode == PROFILE_TAILSCALE_KEY) {
            if (access(profile->identity_file, R_OK) != 0) return -1;
            argv[argc++] = "-o"; argv[argc++] = "PasswordAuthentication=no";
            argv[argc++] = "-i"; argv[argc++] = profile->identity_file;
        }
        argv[argc++] = "-l"; argv[argc++] = profile->user; argv[argc++] = profile->host;
    } else if (profile->mode == PROFILE_SSH) {
        if (access(DBCLIENT_PATH, X_OK) != 0 || access(profile->identity_file, R_OK) != 0) return -1;
        snprintf(port, sizeof(port), "%d", profile->port);
        argv[argc++] = (char *)DBCLIENT_PATH; argv[argc++] = "-t";
        argv[argc++] = "-o"; argv[argc++] = "StrictHostKeyChecking=yes";
        argv[argc++] = "-i"; argv[argc++] = profile->identity_file;
        argv[argc++] = "-p"; argv[argc++] = port; argv[argc++] = destination;
    } else {
        argv[argc++] = "/usr/bin/bash"; argv[argc++] = "--noprofile"; argv[argc++] = "--norc";
    }
    if (profile->session == PROFILE_SESSION_WINDOWS_POWERSHELL) {
        argv[argc++] = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe";
        argv[argc++] = "-NoLogo";
    }
    argv[argc] = NULL;
    child_pid = forkpty(&pty_fd, NULL, NULL, &size);
    if (child_pid < 0) { pty_fd = -1; return -1; }
    if (child_pid == 0) {
        if (profile->mode == PROFILE_TAILSCALE_SSH || profile->mode == PROFILE_TAILSCALE_KEY) {
            if (setenv(TAILSCALE_PROXY_HOST_ENV, profile->host, 1) != 0 ||
                setenv(TAILSCALE_PROXY_PORT_ENV, "22", 1) != 0) _exit(127);
        }
        setenv("TERM", "xterm-256color", 1);
        setenv("COLORTERM", "", 1);
        setenv("LANG", "C.UTF-8", 1);
        execv(argv[0], argv);
        _exit(127);
    }
    (void)fcntl(pty_fd, F_SETFL, fcntl(pty_fd, F_GETFL) | O_NONBLOCK);
    send_message(MSG_STATUS, profile->label);
    return 0;
}

static void finish_session_state(int notify) {
    if (pty_fd >= 0) close(pty_fd);
    child_pid = -1; pty_fd = -1;
    free_terminal();
    on_scrollback_clear(NULL);
    screen_dirty = 1;
    if (notify) send_message(MSG_SESSION_ENDED, "Session ended");
}

static void disconnect_child(void) {
    int status, attempt;
    int had_session = child_pid > 0 || pty_fd >= 0 || terminal != NULL;
    if (child_pid > 0) {
        kill(child_pid, SIGHUP);
        for (attempt = 0; attempt < 10; attempt++) {
            if (waitpid(child_pid, &status, WNOHANG) == child_pid) break;
            usleep(50000);
        }
        if (attempt == 10) {
            kill(child_pid, SIGKILL);
            (void)waitpid(child_pid, &status, 0);
        }
    }
    finish_session_state(had_session);
}

static VTermKey parse_key(const char *name) {
    if (strcmp(name, "enter") == 0) return VTERM_KEY_ENTER;
    if (strcmp(name, "tab") == 0) return VTERM_KEY_TAB;
    if (strcmp(name, "backspace") == 0) return VTERM_KEY_BACKSPACE;
    if (strcmp(name, "escape") == 0) return VTERM_KEY_ESCAPE;
    if (strcmp(name, "up") == 0) return VTERM_KEY_UP;
    if (strcmp(name, "down") == 0) return VTERM_KEY_DOWN;
    if (strcmp(name, "left") == 0) return VTERM_KEY_LEFT;
    if (strcmp(name, "right") == 0) return VTERM_KEY_RIGHT;
    if (strcmp(name, "home") == 0) return VTERM_KEY_HOME;
    if (strcmp(name, "end") == 0) return VTERM_KEY_END;
    if (strcmp(name, "pageup") == 0) return VTERM_KEY_PAGEUP;
    if (strcmp(name, "pagedown") == 0) return VTERM_KEY_PAGEDOWN;
    if (strcmp(name, "delete") == 0) return VTERM_KEY_DEL;
    return VTERM_KEY_NONE;
}

static void handle_message(uint32_t type, const char *contents) {
    struct json_object *root = NULL, *field = NULL;
    if (type == MSG_SYSTEM_TERMINATE) { stopping = 1; return; }
    if (type == MSG_SYSTEM_NEW_COORDINATOR) { send_profiles(NULL); screen_dirty = 1; return; }
    if (type == MSG_DISCONNECT) { disconnect_child(); return; }
    if (type == MSG_REFRESH) { screen_dirty = 1; return; }
    if (type == MSG_GET_PROFILES) { send_profiles(NULL); return; }
    if (contents == NULL) return;
    root = json_tokener_parse(contents);
    if (root == NULL || json_object_get_type(root) != json_type_object) goto done;
    if (type == MSG_START && json_object_object_get_ex(root, "id", &field)) {
        struct profile *profile = find_profile(json_object_get_string(field));
        if (profile == NULL || start_profile(profile) != 0) send_message(MSG_ERROR, "Could not start this profile.");
    } else if (type == MSG_INPUT && child_pid > 0 && json_object_object_get_ex(root, "text", &field)) {
        const char *text = json_object_get_string(field);
        if (text != NULL && strlen(text) <= 4096) (void)write_all(pty_fd, text, strlen(text));
    } else if (type == MSG_KEY && terminal != NULL && json_object_object_get_ex(root, "key", &field)) {
        VTermKey key = parse_key(json_object_get_string(field));
        VTermModifier modifiers = VTERM_MOD_NONE;
        struct json_object *mods;
        if (json_object_object_get_ex(root, "ctrl", &mods) && json_object_get_boolean(mods)) modifiers |= VTERM_MOD_CTRL;
        if (json_object_object_get_ex(root, "alt", &mods) && json_object_get_boolean(mods)) modifiers |= VTERM_MOD_ALT;
        if (json_object_object_get_ex(root, "shift", &mods) && json_object_get_boolean(mods)) modifiers |= VTERM_MOD_SHIFT;
        if (key != VTERM_KEY_NONE) vterm_keyboard_key(terminal, key, modifiers);
    } else if (type == MSG_RESIZE && json_object_object_get_ex(root, "rows", &field)) {
        int new_rows = json_object_get_int(field), new_cols = cols;
        struct winsize size;
        if (json_object_object_get_ex(root, "cols", &field)) new_cols = json_object_get_int(field);
        if (new_rows >= 10 && new_rows <= 60 && new_cols >= 40 && new_cols <= 160) {
            rows = new_rows; cols = new_cols;
            if (terminal != NULL) vterm_set_size(terminal, rows, cols);
            if (pty_fd >= 0) {
                memset(&size, 0, sizeof(size)); size.ws_row = (unsigned short)rows; size.ws_col = (unsigned short)cols;
                (void)ioctl(pty_fd, TIOCSWINSZ, &size);
                if (child_pid > 0) kill(child_pid, SIGWINCH);
            }
            screen_dirty = 1;
        }
    }
done:
    if (root != NULL) json_object_put(root);
}

static int receive_message(uint32_t *type, char **contents) {
    struct message_header header;
    ssize_t received = recv(socket_fd, &header, sizeof(header), 0);
    *contents = NULL;
    if (received <= 0) return -1;
    if (received != (ssize_t)sizeof(header) || header.length > MAX_MESSAGE_SIZE) return -1;
    *type = header.type;
    if (header.length == 0) return 0;
    *contents = calloc(1, (size_t)header.length + 1);
    if (*contents == NULL) return -1;
    received = recv(socket_fd, *contents, header.length, 0);
    if (received != (ssize_t)header.length) { free(*contents); *contents = NULL; return -1; }
    return 0;
}

static long long monotonic_milliseconds(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (long long)value.tv_sec * 1000LL + value.tv_nsec / 1000000LL;
}

int main(int argc, char **argv) {
    struct sockaddr_un address;
    char config_error[256] = "";
    long long last_screen = 0;
    if (argc == 2 && strcmp(argv[1], "--self-test") == 0) {
        printf("paperterm backend self-test: ok\n");
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "--tailscale-proxy-env") == 0) {
        char tailscale_path[512];
        const char *host = getenv(TAILSCALE_PROXY_HOST_ENV);
        const char *port_string = getenv(TAILSCALE_PROXY_PORT_ENV);
        char *end = NULL;
        long port;
        if (host == NULL || port_string == NULL || !valid_host(host)) return 2;
        errno = 0;
        port = strtol(port_string, &end, 10);
        if (errno != 0 || end == port_string || *end != '\0' || port < 1 || port > 65535) return 2;
        if (find_tailscale_path(tailscale_path, sizeof(tailscale_path)) != 0) return 2;
        execl(tailscale_path, tailscale_path, TAILSCALE_SOCKET_ARGUMENT, "nc", host, port_string, (char *)NULL);
        return 127;
    }
    if (argc != 2 || strlen(argv[1]) >= sizeof(address.sun_path)) return 2;
    signal(SIGPIPE, SIG_IGN);
    socket_fd = socket(AF_UNIX, SOCK_SEQPACKET, 0);
    if (socket_fd < 0) return 3;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    snprintf(address.sun_path, sizeof(address.sun_path), "%s", argv[1]);
    if (connect(socket_fd, (struct sockaddr *)&address, sizeof(address)) != 0) return 4;
    if (read_config(config_error, sizeof(config_error)) != 0) memset(&config, 0, sizeof(config));
    send_profiles(config_error);
    send_message(MSG_STATUS, "Ready");

    while (!stopping) {
        struct pollfd descriptors[2];
        int count = 1, result;
        int polled_pty_fd = pty_fd;
        descriptors[0] = (struct pollfd){ .fd = socket_fd, .events = POLLIN };
        if (pty_fd >= 0) descriptors[count++] = (struct pollfd){ .fd = pty_fd, .events = POLLIN | POLLHUP };
        result = poll(descriptors, (nfds_t)count, 50);
        if (result < 0 && errno != EINTR) break;
        if (descriptors[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            uint32_t type; char *contents = NULL;
            if (receive_message(&type, &contents) != 0) break;
            handle_message(type, contents);
            free(contents);
        }
        if (count > 1 && pty_fd == polled_pty_fd && descriptors[1].revents & POLLIN) {
            char buffer[8192]; ssize_t bytes;
            while ((bytes = read(pty_fd, buffer, sizeof(buffer))) > 0) {
                vterm_input_write(terminal, buffer, (size_t)bytes);
                screen_dirty = 1;
            }
        }
        if (count > 1 && pty_fd == polled_pty_fd && descriptors[1].revents & (POLLHUP | POLLERR)) disconnect_child();
        if (child_pid > 0) {
            int status; pid_t ended = waitpid(child_pid, &status, WNOHANG);
            if (ended == child_pid) finish_session_state(1);
        }
        if (screen_dirty && monotonic_milliseconds() - last_screen >= 120) {
            send_screen(); last_screen = monotonic_milliseconds();
        }
    }
    disconnect_child();
    free_terminal();
    on_scrollback_clear(NULL);
    close(socket_fd);
    return 0;
}
