#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <curl/curl.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <json-c/json.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define CONFIG_PATH "/home/root/.config/paperboard/config"
#define STATE_DIR "/home/root/.local/share/paperboard"
#define ASSET_DIR STATE_DIR "/assets"
#define CANDIDATE_PATH STATE_DIR "/candidate.png"
#define LAST_GOOD_PATH STATE_DIR "/dashboard.png"
#define SNAPSHOT_PATH STATE_DIR "/snapshot.json"
#define UI_STATE_PATH STATE_DIR "/ui-state.json"
#define MAX_CONFIG_SIZE 16384U
#define MAX_IMAGE_SIZE (8U * 1024U * 1024U)
#define MAX_JSON_SIZE (1024U * 1024U)
#define MAX_MESSAGE_SIZE (2U * 1024U * 1024U)
#define MAX_CARDS 32

enum {
    MSG_REFRESH = 1, MSG_ACCEPT = 2, MSG_REJECT = 3, MSG_DISMISS = 4, MSG_PIN = 5,
    MSG_UI_STATE = 6, MSG_COMMAND_RESULT = 7, MSG_CANVAS_EVENT = 8, MSG_READER_OPEN = 9,
    MSG_READER_BOOKMARK = 10,
    MSG_STATUS = 101, MSG_CANDIDATE = 102, MSG_ERROR = 103, MSG_LAST_GOOD = 104,
    MSG_SNAPSHOT = 105, MSG_COMMAND = 106, MSG_ACTION_RESULT = 107, MSG_READER = 108,
    MSG_READER_BOOKMARKS = 109,
};

#define MSG_SYSTEM_TERMINATE UINT32_MAX
#define MSG_SYSTEM_NEW_COORDINATOR (UINT32_MAX - 1U)

struct message_header { uint32_t type; uint32_t length; };

struct app_config {
    int relay_mode;
    char url[4096];
    char relay_url[4096];
    char device_id[80];
    char device_token[512];
    char proxy[256];
    long poll_wait;
};

struct buffer { char *data; size_t length; size_t capacity; };
struct file_target { FILE *file; size_t received; };

static int socket_fd = -1;
static pthread_mutex_t send_lock = PTHREAD_MUTEX_INITIALIZER;
static volatile int stopping = 0;
static volatile int force_refresh = 0;
static long long relay_cursor = 0;
static struct app_config config;
static CURLcode last_download_result = CURLE_OK;
static char last_download_error[CURL_ERROR_SIZE];

static void send_message(uint32_t type, const char *contents) {
    struct message_header header;
    size_t length = contents == NULL ? 0 : strlen(contents);
    if (length > MAX_MESSAGE_SIZE || socket_fd < 0) return;
    header.type = type;
    header.length = (uint32_t)length;
    pthread_mutex_lock(&send_lock);
    if (send(socket_fd, &header, sizeof(header), MSG_NOSIGNAL) == (ssize_t)sizeof(header) && length > 0)
        (void)send(socket_fd, contents, length, MSG_NOSIGNAL);
    pthread_mutex_unlock(&send_lock);
}

static int make_private_directory(const char *path) {
    struct stat metadata;
    if (mkdir(path, 0700) != 0 && errno != EEXIST) return -1;
    if (lstat(path, &metadata) != 0 || !S_ISDIR(metadata.st_mode) || metadata.st_uid != 0) return -1;
    return chmod(path, 0700);
}

static int make_state_directories(void) {
    return (make_private_directory("/home/root/.local") == 0 &&
            make_private_directory("/home/root/.local/share") == 0 &&
            make_private_directory(STATE_DIR) == 0 &&
            make_private_directory(ASSET_DIR) == 0) ? 0 : -1;
}

static int valid_https_url(const char *url) {
    const char *authority, *cursor;
    if (strncmp(url, "https://", 8) != 0) return 0;
    authority = url + 8;
    if (*authority == '\0') return 0;
    for (cursor = authority; *cursor != '\0'; cursor++) {
        unsigned char value = (unsigned char)*cursor;
        if (value <= 0x20 || value == 0x7f || value == '\\') return 0;
        if (*cursor == '/' || *cursor == '?' || *cursor == '#') break;
        if (*cursor == '@') return 0;
    }
    return cursor != authority;
}

static int valid_id(const char *value) {
    size_t index, length = strlen(value);
    if (length == 0 || length > 64) return 0;
    for (index = 0; index < length; index++) {
        char character = value[index];
        if (!((character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') ||
              (character >= '0' && character <= '9') || character == '-' || character == '_')) return 0;
    }
    return 1;
}

static int read_config(char *error, size_t error_capacity) {
    struct stat metadata;
    FILE *file;
    char text[MAX_CONFIG_SIZE + 1], *line, *save = NULL;
    size_t count;
    memset(&config, 0, sizeof(config));
    config.poll_wait = 25;
    if (lstat(CONFIG_PATH, &metadata) != 0 || !S_ISREG(metadata.st_mode) || metadata.st_uid != 0 || (metadata.st_mode & 077) != 0) {
        snprintf(error, error_capacity, "Config must be a root-owned regular file with mode 0600.");
        return -1;
    }
    if (metadata.st_size <= 0 || metadata.st_size > (off_t)MAX_CONFIG_SIZE) {
        snprintf(error, error_capacity, "Config size is invalid.");
        return -1;
    }
    file = fopen(CONFIG_PATH, "r");
    if (file == NULL) { snprintf(error, error_capacity, "Cannot read config."); return -1; }
    count = fread(text, 1, sizeof(text) - 1, file);
    fclose(file);
    text[count] = '\0';
    for (line = strtok_r(text, "\n", &save); line != NULL; line = strtok_r(NULL, "\n", &save)) {
        char *equals;
        if (*line == '\0' || *line == '#') continue;
        equals = strchr(line, '=');
        if (equals == NULL) { snprintf(error, error_capacity, "Config contains a malformed line."); return -1; }
        *equals++ = '\0';
        if (strcmp(line, "mode") == 0) config.relay_mode = strcmp(equals, "relay") == 0;
        else if (strcmp(line, "url") == 0) snprintf(config.url, sizeof(config.url), "%s", equals);
        else if (strcmp(line, "relay_url") == 0) snprintf(config.relay_url, sizeof(config.relay_url), "%s", equals);
        else if (strcmp(line, "device_id") == 0) snprintf(config.device_id, sizeof(config.device_id), "%s", equals);
        else if (strcmp(line, "device_token") == 0) snprintf(config.device_token, sizeof(config.device_token), "%s", equals);
        else if (strcmp(line, "proxy") == 0) snprintf(config.proxy, sizeof(config.proxy), "%s", equals);
        else if (strcmp(line, "poll_wait") == 0) config.poll_wait = strtol(equals, NULL, 10);
        else { snprintf(error, error_capacity, "Config contains an unknown key."); return -1; }
    }
    if (!config.relay_mode && valid_https_url(config.url)) return 0;
    if (!config.relay_mode) { snprintf(error, error_capacity, "Set mode=relay or provide url=https://... for legacy mode."); return -1; }
    if (!valid_https_url(config.relay_url) || !valid_id(config.device_id) || strlen(config.device_token) < 32) {
        snprintf(error, error_capacity, "Relay URL, device ID, or device token is invalid."); return -1;
    }
    if (config.proxy[0] != '\0' && strncmp(config.proxy, "socks5h://127.0.0.1:", 20) != 0 &&
        strncmp(config.proxy, "socks5h://[::1]:", 16) != 0) {
        snprintf(error, error_capacity, "Proxy must be a loopback SOCKS5 hostname proxy."); return -1;
    }
    if (config.poll_wait < 0 || config.poll_wait > 25) config.poll_wait = 25;
    while (strlen(config.relay_url) > 8 && config.relay_url[strlen(config.relay_url) - 1] == '/')
        config.relay_url[strlen(config.relay_url) - 1] = '\0';
    return 0;
}

static size_t write_buffer(void *contents, size_t size, size_t count, void *user_data) {
    struct buffer *target = user_data;
    size_t bytes;
    char *expanded;
    if (count != 0 && size > SIZE_MAX / count) return 0;
    bytes = size * count;
    if (bytes > MAX_JSON_SIZE - target->length) return 0;
    if (target->length + bytes + 1 > target->capacity) {
        size_t capacity = target->capacity == 0 ? 4096 : target->capacity;
        while (capacity < target->length + bytes + 1) capacity *= 2;
        expanded = realloc(target->data, capacity);
        if (expanded == NULL) return 0;
        target->data = expanded; target->capacity = capacity;
    }
    memcpy(target->data + target->length, contents, bytes);
    target->length += bytes; target->data[target->length] = '\0';
    return bytes;
}

static size_t write_file(void *contents, size_t size, size_t count, void *user_data) {
    struct file_target *target = user_data;
    size_t bytes;
    if (count != 0 && size > SIZE_MAX / count) return 0;
    bytes = size * count;
    if (bytes > MAX_IMAGE_SIZE - target->received) return 0;
    if (fwrite(contents, 1, bytes, target->file) != bytes) return 0;
    target->received += bytes;
    return bytes;
}

static void configure_curl(CURL *curl, const char *url, struct curl_slist *headers, long timeout) {
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, last_download_error);
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "https");
    curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS_STR, "https");
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 10L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, timeout);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
    curl_easy_setopt(curl, CURLOPT_CAINFO, "/etc/ssl/certs/ca-certificates.crt");
    curl_easy_setopt(curl, CURLOPT_FAILONERROR, 1L);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "Paperboard/2.0");
    curl_easy_setopt(curl, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_PROXY, config.proxy);
}

static struct curl_slist *authorization_headers(int json) {
    struct curl_slist *headers = NULL;
    char authorization[600];
    snprintf(authorization, sizeof(authorization), "Authorization: Bearer %s", config.device_token);
    headers = curl_slist_append(headers, authorization);
    headers = curl_slist_append(headers, json ? "Content-Type: application/json" : "Accept: application/json, image/png");
    return headers;
}

static int http_json_method(const char *url, const char *method, const char *data, struct buffer *response, long timeout) {
    CURL *curl = curl_easy_init();
    struct curl_slist *headers = authorization_headers(data != NULL);
    CURLcode result;
    if (curl == NULL || headers == NULL) { curl_easy_cleanup(curl); curl_slist_free_all(headers); return -1; }
    configure_curl(curl, url, headers, timeout);
    if (method != NULL) curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method);
    if (data != NULL) {
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, data);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)strlen(data));
    }
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_buffer);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, response);
    result = curl_easy_perform(curl);
    last_download_result = result;
    curl_easy_cleanup(curl); curl_slist_free_all(headers);
    return result == CURLE_OK ? 0 : -1;
}

static int http_json(const char *url, const char *post_data, struct buffer *response, long timeout) {
    return http_json_method(url, post_data == NULL ? NULL : "POST", post_data, response, timeout);
}

static int validate_png_path(const char *path, char *error, size_t error_capacity) {
    static const unsigned char signature[8] = { 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };
    unsigned char header[24]; struct stat metadata; FILE *file; uint32_t width, height;
    if (stat(path, &metadata) != 0 || !S_ISREG(metadata.st_mode) || metadata.st_size < 24 || metadata.st_size > (off_t)MAX_IMAGE_SIZE) {
        snprintf(error, error_capacity, "Image must be a regular PNG no larger than 8 MiB."); return -1;
    }
    file = fopen(path, "rb");
    if (file == NULL || fread(header, 1, sizeof(header), file) != sizeof(header)) {
        if (file != NULL) fclose(file);
        snprintf(error, error_capacity, "Cannot inspect downloaded image.");
        return -1;
    }
    fclose(file);
    if (memcmp(header, signature, 8) != 0 || memcmp(header + 12, "IHDR", 4) != 0) {
        snprintf(error, error_capacity, "Downloaded file is not a PNG."); return -1;
    }
    memcpy(&width, header + 16, 4); memcpy(&height, header + 20, 4);
    width = ntohl(width); height = ntohl(height);
    if (width == 0 || height == 0 || width > 8192 || height > 8192 || (uint64_t)width * height > 40000000ULL) {
        snprintf(error, error_capacity, "PNG dimensions exceed the safe decode limit."); return -1;
    }
    return 0;
}

static int download_file(const char *url, const char *path, int authenticated) {
    char temporary[512], error[160];
    struct file_target target = { 0 };
    struct curl_slist *headers = authenticated ? authorization_headers(0) : NULL;
    CURL *curl; CURLcode result; int descriptor;
    snprintf(temporary, sizeof(temporary), "%s.tmp", path);
    unlink(temporary);
    descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (descriptor < 0) { curl_slist_free_all(headers); return -1; }
    target.file = fdopen(descriptor, "wb");
    if (target.file == NULL) { close(descriptor); unlink(temporary); curl_slist_free_all(headers); return -1; }
    curl = curl_easy_init();
    if (curl == NULL) { fclose(target.file); unlink(temporary); curl_slist_free_all(headers); return -1; }
    configure_curl(curl, url, headers, 30L);
    curl_easy_setopt(curl, CURLOPT_MAXFILESIZE_LARGE, (curl_off_t)MAX_IMAGE_SIZE);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_file);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &target);
    result = curl_easy_perform(curl);
    curl_easy_cleanup(curl); curl_slist_free_all(headers);
    if (fclose(target.file) != 0 && result == CURLE_OK) result = CURLE_WRITE_ERROR;
    last_download_result = result;
    if (result != CURLE_OK || validate_png_path(temporary, error, sizeof(error)) != 0 || rename(temporary, path) != 0) {
        unlink(temporary); return -1;
    }
    (void)chmod(path, 0600);
    return 0;
}

static void legacy_refresh(void) {
    char error[256];
    send_message(MSG_STATUS, "FETCHING");
    if (make_state_directories() != 0) { send_message(MSG_ERROR, "Cannot prepare private state directory."); return; }
    if (download_file(config.url, CANDIDATE_PATH, 0) != 0) {
        unlink(CANDIDATE_PATH); send_message(MSG_ERROR, "HTTPS download failed; last-good image retained."); return;
    }
    if (validate_png_path(CANDIDATE_PATH, error, sizeof(error)) != 0) {
        unlink(CANDIDATE_PATH); send_message(MSG_ERROR, error); return;
    }
    send_message(MSG_CANDIDATE, CANDIDATE_PATH);
}

static int relay_asset_allowed(const char *url) {
    size_t prefix = strlen(config.relay_url);
    return valid_https_url(url) && strncmp(url, config.relay_url, prefix) == 0 &&
           (url[prefix] == '/' || url[prefix] == '?' || url[prefix] == '\0');
}

static void attach_assets(struct json_object *root) {
    struct json_object *cards;
    size_t index, count;
    if (!json_object_object_get_ex(root, "cards", &cards) || !json_object_is_type(cards, json_type_array)) return;
    count = json_object_array_length(cards);
    if (count > MAX_CARDS) count = MAX_CARDS;
    for (index = 0; index < count; index++) {
        struct json_object *card = json_object_array_get_idx(cards, index), *id_object, *url_object;
        const char *id, *url; char path[512];
        if (!json_object_object_get_ex(card, "id", &id_object) || !json_object_object_get_ex(card, "asset_url", &url_object)) continue;
        id = json_object_get_string(id_object); url = json_object_get_string(url_object);
        if (!valid_id(id) || !relay_asset_allowed(url)) continue;
        snprintf(path, sizeof(path), ASSET_DIR "/%s.png", id);
        if (access(path, R_OK) != 0 && download_file(url, path, 1) != 0) {
            send_message(MSG_ERROR, "A card image could not be securely downloaded; text remains available."); continue;
        }
        json_object_object_add(card, "asset_path", json_object_new_string(path));
    }
}

static void attach_screen_assets(struct json_object *root) {
    struct json_object *screen, *messages, *wrapper;
    if (!json_object_object_get_ex(root, "screen", &screen) || json_object_is_type(screen, json_type_null) ||
        !json_object_object_get_ex(screen, "messages", &messages) || !json_object_is_type(messages, json_type_array)) return;
    wrapper = json_object_new_object();
    json_object_get(messages);
    json_object_object_add(wrapper, "cards", messages);
    attach_assets(wrapper);
    json_object_put(wrapper);
}

static void cleanup_assets(struct json_object *root) {
    struct json_object *cards;
    struct dirent *entry;
    DIR *directory;
    if (!json_object_object_get_ex(root, "cards", &cards) || !json_object_is_type(cards, json_type_array)) return;
    directory = opendir(ASSET_DIR);
    if (directory == NULL) return;
    while ((entry = readdir(directory)) != NULL) {
        size_t length = strlen(entry->d_name), index, count;
        int keep = 0;
        char id[80], path[512];
        if (length < 5 || length >= sizeof(id) || strcmp(entry->d_name + length - 4, ".png") != 0) continue;
        memcpy(id, entry->d_name, length - 4); id[length - 4] = '\0';
        count = json_object_array_length(cards);
        for (index = 0; index < count; index++) {
            struct json_object *card = json_object_array_get_idx(cards, index), *id_object;
            if (json_object_object_get_ex(card, "id", &id_object) && strcmp(id, json_object_get_string(id_object)) == 0) { keep = 1; break; }
        }
        if (!keep) { snprintf(path, sizeof(path), ASSET_DIR "/%s", entry->d_name); (void)unlink(path); }
    }
    closedir(directory);
}

static void persist_ui_state(const char *json) {
    char temporary[] = UI_STATE_PATH ".tmp";
    int descriptor, ok; size_t length = strlen(json); ssize_t written;
    if (length == 0 || length > 16384U) return;
    unlink(temporary);
    descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (descriptor < 0) return;
    written = write(descriptor, json, length);
    ok = written == (ssize_t)length && fsync(descriptor) == 0 && close(descriptor) == 0;
    if (ok) { if (rename(temporary, UI_STATE_PATH) != 0) unlink(temporary); }
    else { (void)close(descriptor); unlink(temporary); }
}

static void attach_saved_ui_state(struct json_object *root) {
    struct stat metadata; FILE *file; char *contents; struct json_object *state;
    if (stat(UI_STATE_PATH, &metadata) != 0 || metadata.st_size <= 0 || metadata.st_size > 16384) return;
    file = fopen(UI_STATE_PATH, "rb"); if (file == NULL) return;
    contents = malloc((size_t)metadata.st_size + 1); if (contents == NULL) { fclose(file); return; }
    if (fread(contents, 1, (size_t)metadata.st_size, file) != (size_t)metadata.st_size) { free(contents); fclose(file); return; }
    fclose(file); contents[metadata.st_size] = '\0'; state = json_tokener_parse(contents); free(contents);
    if (state != NULL && json_object_is_type(state, json_type_object)) json_object_object_add(root, "ui_state", state);
    else if (state != NULL) json_object_put(state);
}

static void persist_snapshot(const char *json) {
    char temporary[] = SNAPSHOT_PATH ".tmp";
    int descriptor, ok; size_t length = strlen(json); ssize_t written;
    unlink(temporary);
    descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (descriptor < 0) return;
    written = write(descriptor, json, length);
    ok = written == (ssize_t)length;
    if (fsync(descriptor) != 0) ok = 0;
    if (close(descriptor) != 0) ok = 0;
    if (ok) {
        if (rename(temporary, SNAPSHOT_PATH) == 0) (void)chmod(SNAPSHOT_PATH, 0600);
        else unlink(temporary);
    } else unlink(temporary);
}

static void send_cached_snapshot(void) {
    struct stat metadata; struct buffer buffer = { 0 }; FILE *file;
    if (stat(SNAPSHOT_PATH, &metadata) != 0 || metadata.st_size <= 0 || metadata.st_size > (off_t)MAX_JSON_SIZE) return;
    file = fopen(SNAPSHOT_PATH, "rb"); if (file == NULL) return;
    buffer.data = malloc((size_t)metadata.st_size + 1); if (buffer.data == NULL) { fclose(file); return; }
    buffer.length = fread(buffer.data, 1, (size_t)metadata.st_size, file); fclose(file);
    buffer.data[buffer.length] = '\0'; send_message(MSG_SNAPSHOT, buffer.data); free(buffer.data);
}

static void relay_ack(long long cursor) {
    char url[4600], body[80]; struct buffer response = { 0 };
    snprintf(url, sizeof(url), "%s/v2/device/%s/ack", config.relay_url, config.device_id);
    snprintf(body, sizeof(body), "{\"cursor\":%lld}", cursor);
    (void)http_json(url, body, &response, 10L); free(response.data);
}

static int relay_poll_once(long long cursor) {
    char url[4600]; struct buffer response = { 0 }; struct json_object *root, *cursor_object, *commands;
    long timeout = config.poll_wait + 15;
    snprintf(url, sizeof(url), "%s/v2/device/%s/poll?cursor=%lld&wait=%ld", config.relay_url, config.device_id, cursor, config.poll_wait);
    if (http_json(url, NULL, &response, timeout) != 0) { free(response.data); return -1; }
    root = json_tokener_parse(response.data == NULL ? "" : response.data);
    free(response.data);
    if (root == NULL || !json_object_is_type(root, json_type_object) ||
        !json_object_object_get_ex(root, "cursor", &cursor_object)) { json_object_put(root); return -1; }
    relay_cursor = json_object_get_int64(cursor_object);
    attach_assets(root);
    attach_screen_assets(root);
    cleanup_assets(root);
    attach_saved_ui_state(root);
    {
        const char *serialized = json_object_to_json_string_ext(root, JSON_C_TO_STRING_PLAIN);
        persist_snapshot(serialized);
        send_message(MSG_SNAPSHOT, serialized);
    }
    /* A foreground command can target content introduced by this poll. Send
     * the complete snapshot first so QML can resolve the target immediately,
     * rather than racing a navigation command against stale history. */
    if (json_object_object_get_ex(root, "commands", &commands) && json_object_is_type(commands, json_type_array)) {
        size_t index, count = json_object_array_length(commands);
        for (index = 0; index < count; index++) {
            struct json_object *command = json_object_array_get_idx(commands, index);
            send_message(MSG_COMMAND, json_object_to_json_string_ext(command, JSON_C_TO_STRING_PLAIN));
        }
    }
    relay_ack(relay_cursor);
    json_object_put(root);
    return 0;
}

static void *relay_loop(void *unused) {
    struct timespec delay = { .tv_sec = 2, .tv_nsec = 0 };
    (void)unused;
    while (!stopping) {
        long long cursor = force_refresh ? 0 : relay_cursor;
        force_refresh = 0;
        if (relay_poll_once(cursor) != 0) {
            send_message(MSG_ERROR, last_download_result == CURLE_PEER_FAILED_VERIFICATION ?
                         "Relay TLS verification failed; cached cards retained." : "Relay unavailable; cached cards retained.");
            nanosleep(&delay, NULL);
        }
    }
    return NULL;
}

static void relay_action(const char *card_id, const char *action) {
    char url[4700]; struct buffer response = { 0 };
    if (!valid_id(card_id)) { send_message(MSG_ERROR, "Card identifier is invalid."); return; }
    snprintf(url, sizeof(url), "%s/v2/device/%s/dashboard/cards/%s/%s", config.relay_url, config.device_id, card_id, action);
    if (http_json(url, "{}", &response, 15L) != 0) send_message(MSG_ERROR, "Card action failed; queue retained.");
    else { send_message(MSG_ACTION_RESULT, action); force_refresh = 1; }
    free(response.data);
}

static void relay_ui_state(const char *body) {
    char url[4600]; struct buffer response = { 0 };
    persist_ui_state(body);
    snprintf(url, sizeof(url), "%s/v2/device/%s/ui-state", config.relay_url, config.device_id);
    if (http_json_method(url, "PUT", body, &response, 10L) != 0)
        send_message(MSG_ERROR, "Could not report visible tablet state.");
    free(response.data);
}

static void relay_command_result(const char *body) {
    struct json_object *root = json_tokener_parse(body), *id_object;
    const char *id; char url[4700]; struct buffer response = { 0 };
    if (root == NULL || !json_object_object_get_ex(root, "id", &id_object) ||
        !valid_id(id = json_object_get_string(id_object))) { json_object_put(root); return; }
    snprintf(url, sizeof(url), "%s/v2/device/%s/commands/%s/result", config.relay_url, config.device_id, id);
    (void)http_json(url, body, &response, 10L);
    free(response.data); json_object_put(root);
}

static void relay_canvas_event(const char *body) {
    struct json_object *root = json_tokener_parse(body), *session_object;
    const char *session; char url[4700]; struct buffer response = { 0 };
    if (root == NULL || !json_object_object_get_ex(root, "session_id", &session_object) ||
        !valid_id(session = json_object_get_string(session_object))) { json_object_put(root); return; }
    json_object_object_del(root, "session_id");
    snprintf(url, sizeof(url), "%s/v2/device/%s/screen/sessions/%s/events", config.relay_url, config.device_id, session);
    if (http_json(url, json_object_to_json_string_ext(root, JSON_C_TO_STRING_PLAIN), &response, 10L) == 0)
        send_message(MSG_ACTION_RESULT, "Response sent");
    else send_message(MSG_ERROR, "Response could not be sent");
    free(response.data); json_object_put(root);
}

static void relay_reader_open(const char *body) {
    char url[4600]; struct buffer response = { 0 };
    snprintf(url, sizeof(url), "%s/v2/device/%s/reader", config.relay_url, config.device_id);
    if (http_json(url, body, &response, 15L) == 0 && response.data != NULL) send_message(MSG_READER, response.data);
    else send_message(MSG_ERROR, "Reader could not safely open this page");
    free(response.data);
}

static void relay_reader_bookmarks(void) {
    char url[4600]; struct buffer response = { 0 };
    snprintf(url, sizeof(url), "%s/v2/device/%s/reader/bookmarks", config.relay_url, config.device_id);
    if (http_json(url, NULL, &response, 10L) == 0 && response.data != NULL)
        send_message(MSG_READER_BOOKMARKS, response.data);
    free(response.data);
}

static void relay_reader_bookmark(const char *body) {
    char url[4600]; struct buffer response = { 0 };
    snprintf(url, sizeof(url), "%s/v2/device/%s/reader/bookmarks", config.relay_url, config.device_id);
    if (http_json(url, body, &response, 10L) == 0 && response.data != NULL)
        send_message(MSG_READER_BOOKMARKS, response.data);
    else send_message(MSG_ERROR, "Reader bookmark could not be updated");
    free(response.data);
}

static void accept_candidate(void) {
    if (rename(CANDIDATE_PATH, LAST_GOOD_PATH) != 0) { send_message(MSG_ERROR, "Could not atomically promote decoded image."); return; }
    (void)chmod(LAST_GOOD_PATH, 0600); send_message(MSG_LAST_GOOD, LAST_GOOD_PATH);
}

static int connect_to_appload(const char *path) {
    struct sockaddr_un address; size_t length = strlen(path); int fd;
    if (length == 0 || length >= sizeof(address.sun_path)) return -1;
    fd = socket(AF_UNIX, SOCK_SEQPACKET, 0); if (fd < 0) return -1;
    memset(&address, 0, sizeof(address)); address.sun_family = AF_UNIX; memcpy(address.sun_path, path, length + 1);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) { close(fd); return -1; }
    return fd;
}

int main(int argc, char **argv) {
    struct message_header header; char *contents = NULL, error[256] = { 0 }; pthread_t polling_thread; int thread_started = 0;
    int config_valid;
    if (argc != 2 || curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK || make_state_directories() != 0 ||
        (socket_fd = connect_to_appload(argv[1])) < 0) {
        fprintf(stderr, "paperboard backend: %s\n", error[0] ? error : "startup failed"); return 1;
    }
    config_valid = read_config(error, sizeof(error)) == 0;
    if (config_valid && config.relay_mode && pthread_create(&polling_thread, NULL, relay_loop, NULL) == 0) thread_started = 1;
    for (;;) {
        ssize_t count = recv(socket_fd, &header, sizeof(header), 0);
        if (count != (ssize_t)sizeof(header) || header.length > MAX_MESSAGE_SIZE) break;
        free(contents); contents = calloc((size_t)header.length + 1, 1); if (contents == NULL) break;
        if (header.length > 0 && recv(socket_fd, contents, header.length, 0) != (ssize_t)header.length) break;
        if (header.type == MSG_SYSTEM_TERMINATE) break;
        if (header.type == MSG_SYSTEM_NEW_COORDINATOR) {
            if (!config_valid) send_message(MSG_ERROR, error);
            else if (config.relay_mode) { send_cached_snapshot(); relay_reader_bookmarks(); send_message(MSG_STATUS, "CONNECTED"); }
            else if (access(LAST_GOOD_PATH, R_OK) == 0) send_message(MSG_LAST_GOOD, LAST_GOOD_PATH);
            else send_message(MSG_STATUS, "OFFLINE");
        } else if (header.type == MSG_REFRESH) {
            if (!config_valid) send_message(MSG_ERROR, error);
            else if (config.relay_mode) force_refresh = 1; else legacy_refresh();
        } else if (header.type == MSG_ACCEPT && !config.relay_mode) accept_candidate();
        else if (header.type == MSG_REJECT && !config.relay_mode) { unlink(CANDIDATE_PATH); send_message(MSG_ERROR, "Qt rejected candidate; last-good retained."); }
        else if (header.type == MSG_DISMISS && config.relay_mode) relay_action(contents, "dismiss");
        else if (header.type == MSG_PIN && config.relay_mode) relay_action(contents, "pin");
        else if (header.type == MSG_UI_STATE && config.relay_mode) relay_ui_state(contents);
        else if (header.type == MSG_COMMAND_RESULT && config.relay_mode) relay_command_result(contents);
        else if (header.type == MSG_CANVAS_EVENT && config.relay_mode) relay_canvas_event(contents);
        else if (header.type == MSG_READER_OPEN && config.relay_mode) relay_reader_open(contents);
        else if (header.type == MSG_READER_BOOKMARK && config.relay_mode) relay_reader_bookmark(contents);
    }
    stopping = 1; free(contents); close(socket_fd);
    if (!thread_started) curl_global_cleanup();
    return 0;
}
