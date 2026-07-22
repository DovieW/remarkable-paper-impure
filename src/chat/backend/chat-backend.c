#define _POSIX_C_SOURCE 200809L
#include <curl/curl.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
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
#define OUTBOX_PATH "/home/root/.local/share/chat/outbox"
#define MAX_CONFIG 16384U
#define MAX_JSON (8U * 1024U * 1024U)
#define MSG_SELECT 1U
#define MSG_ACTION 2U
#define MSG_SNAPSHOT 101U
#define MSG_STATUS 102U
#define MSG_ERROR 103U
#define MSG_SYSTEM_TERMINATE UINT32_MAX
#define MSG_SYSTEM_NEW_COORDINATOR (UINT32_MAX - 1U)

struct header { uint32_t type; uint32_t length; };
struct buffer { char *data; size_t length; size_t capacity; };
struct config { char relay[4096]; char device[80]; char token[512]; char proxy[256]; };
static struct config config;
static int socket_fd = -1;
static volatile int stopping = 0;
static volatile int refresh = 1;
static long long cursor = 0;
static char selected[241] = "";
static pthread_mutex_t state_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t send_lock = PTHREAD_MUTEX_INITIALIZER;

static int action_id(const char *body, char id[65]) {
    const char *key = strstr(body, "\"id\":\""); size_t length = 0;
    if (!key) return -1;
    key += 6;
    while (key[length] && key[length] != '"' && length < 64) {
        char value = key[length];
        if (!((value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z') ||
              (value >= '0' && value <= '9') || value == '-')) return -1;
        length++;
    }
    if (!length || key[length] != '"') return -1;
    memcpy(id, key, length); id[length] = '\0'; return 0;
}

static int persist_action(const char *body, char path[512]) {
    char id[65], temporary[544]; int fd; size_t length = strlen(body), written = 0;
    if (action_id(body, id) || (mkdir(OUTBOX_PATH, 0700) && errno != EEXIST)) return -1;
    snprintf(path, 512, "%s/%s.json", OUTBOX_PATH, id);
    snprintf(temporary, sizeof(temporary), "%s.tmp.%ld", path, (long)getpid());
    fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0600); if (fd < 0) return -1;
    while (written < length) { ssize_t count = write(fd, body + written, length - written); if (count <= 0) { close(fd); unlink(temporary); return -1; } written += (size_t)count; }
    if (fsync(fd)) { close(fd); unlink(temporary); return -1; }
    if (close(fd) || rename(temporary, path)) { unlink(temporary); return -1; }
    return 0;
}

static void send_message(uint32_t type, const char *text) {
    struct header value = { type, text == NULL ? 0U : (uint32_t)strlen(text) };
    pthread_mutex_lock(&send_lock);
    if (socket_fd >= 0 && send(socket_fd, &value, sizeof(value), MSG_NOSIGNAL) == (ssize_t)sizeof(value) && value.length)
        (void)send(socket_fd, text, value.length, MSG_NOSIGNAL);
    pthread_mutex_unlock(&send_lock);
}

static size_t append(void *contents, size_t size, size_t count, void *user) {
    struct buffer *target = user; size_t bytes = size * count, needed; char *next;
    if (count && bytes / count != size) return 0;
    needed = target->length + bytes + 1; if (needed > MAX_JSON) return 0;
    if (needed > target->capacity) { size_t capacity = target->capacity ? target->capacity : 4096; while (capacity < needed) capacity *= 2; next = realloc(target->data, capacity); if (!next) return 0; target->data = next; target->capacity = capacity; }
    memcpy(target->data + target->length, contents, bytes); target->length += bytes; target->data[target->length] = '\0'; return bytes;
}

static int read_config(void) {
    struct stat metadata; FILE *file; char text[MAX_CONFIG + 1], *line, *save = NULL; size_t count;
    if (lstat(CONFIG_PATH, &metadata) || !S_ISREG(metadata.st_mode) || metadata.st_uid != 0 || (metadata.st_mode & 077)) return -1;
    file = fopen(CONFIG_PATH, "r"); if (!file) return -1; count = fread(text, 1, MAX_CONFIG, file); fclose(file); text[count] = '\0';
    memset(&config, 0, sizeof(config));
    for (line = strtok_r(text, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        char *equals = strchr(line, '='); if (!equals || *line == '#') continue; *equals++ = '\0';
        if (!strcmp(line, "relay_url")) snprintf(config.relay, sizeof(config.relay), "%s", equals);
        else if (!strcmp(line, "device_id")) snprintf(config.device, sizeof(config.device), "%s", equals);
        else if (!strcmp(line, "device_token")) snprintf(config.token, sizeof(config.token), "%s", equals);
        else if (!strcmp(line, "proxy")) snprintf(config.proxy, sizeof(config.proxy), "%s", equals);
    }
    while (strlen(config.relay) && config.relay[strlen(config.relay)-1] == '/') config.relay[strlen(config.relay)-1] = '\0';
    return strncmp(config.relay, "https://", 8) || !config.device[0] || strlen(config.token) < 32 ? -1 : 0;
}

static int request(const char *url, const char *method, const char *body, struct buffer *response, long timeout) {
    CURL *curl = curl_easy_init(); struct curl_slist *headers = NULL; char authorization[560]; CURLcode result; long status = 0;
    if (!curl) return -1;
    snprintf(authorization, sizeof(authorization), "Authorization: Bearer %s", config.token);
    headers = curl_slist_append(headers, authorization); headers = curl_slist_append(headers, "Content-Type: application/json");
    curl_easy_setopt(curl, CURLOPT_URL, url); curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers); curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, append); curl_easy_setopt(curl, CURLOPT_WRITEDATA, response);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, timeout); curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 8L); curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 0L); curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "https");
    if (config.proxy[0]) curl_easy_setopt(curl, CURLOPT_PROXY, config.proxy);
    if (method) { curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method); curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body ? body : "{}"); }
    result = curl_easy_perform(curl); if (result == CURLE_OK) curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
    curl_slist_free_all(headers); curl_easy_cleanup(curl); return result == CURLE_OK && status >= 200 && status < 300 ? 0 : -1;
}

static int deliver_action(const char *body) {
    char url[4600]; struct buffer response = {0}; int result;
    snprintf(url, sizeof(url), "%s/v2/device/%s/chat/actions", config.relay, config.device);
    result = request(url, "POST", body, &response, 15L); free(response.data); return result;
}

static void retry_outbox(void) {
    DIR *directory = opendir(OUTBOX_PATH); struct dirent *entry;
    if (!directory) return;
    while (!stopping && (entry = readdir(directory))) {
        char path[512], *body; FILE *file; size_t length;
        if (entry->d_name[0] == '.' || !strstr(entry->d_name, ".json")) continue;
        snprintf(path, sizeof(path), "%s/%s", OUTBOX_PATH, entry->d_name);
        file = fopen(path, "r"); if (!file) continue;
        body = malloc(MAX_JSON + 1); if (!body) { fclose(file); break; }
        length = fread(body, 1, MAX_JSON, file); fclose(file); body[length] = '\0';
        if (length && !deliver_action(body)) { free(body); unlink(path); pthread_mutex_lock(&state_lock); refresh = 1; pthread_mutex_unlock(&state_lock); }
        else { free(body); break; }
    }
    closedir(directory);
}

static void *poll_loop(void *unused) {
    (void)unused;
    while (!stopping) {
        char url[4700], selection[241]; struct buffer response = {0}; CURL *escape_handle; char *escaped = NULL; long long local_cursor;
        pthread_mutex_lock(&state_lock); snprintf(selection, sizeof(selection), "%s", selected); local_cursor = refresh ? 0 : cursor; refresh = 0; pthread_mutex_unlock(&state_lock);
        escape_handle = curl_easy_init(); if (escape_handle && selection[0]) escaped = curl_easy_escape(escape_handle, selection, 0);
        snprintf(url, sizeof(url), "%s/v2/device/%s/chat/poll?cursor=%lld&wait=25%s%s", config.relay, config.device, local_cursor, escaped ? "&session=" : "", escaped ? escaped : "");
        if (escaped) curl_free(escaped);
        if (escape_handle) curl_easy_cleanup(escape_handle);
        if (request(url, NULL, NULL, &response, 35L) == 0 && response.data) {
            const char *found = strstr(response.data, "\"cursor\":"); if (found) cursor = strtoll(found + 9, NULL, 10);
            send_message(MSG_SNAPSHOT, response.data); send_message(MSG_STATUS, "CONNECTED");
        } else { send_message(MSG_ERROR, "Chat relay unavailable; cached conversation retained."); struct timespec delay = {2,0}; nanosleep(&delay, NULL); }
        free(response.data);
        retry_outbox();
    }
    return NULL;
}

static void post_action(const char *body) {
    char path[512];
    if (persist_action(body, path)) { send_message(MSG_ERROR, "Could not persist this action; it remains in the editor."); return; }
    if (deliver_action(body)) send_message(MSG_STATUS, "QUEUED OFFLINE");
    else { unlink(path); pthread_mutex_lock(&state_lock); refresh = 1; pthread_mutex_unlock(&state_lock); }
}

static int connect_appload(const char *path) {
    struct sockaddr_un address; int fd = socket(AF_UNIX, SOCK_SEQPACKET, 0); size_t length = strlen(path); if (fd < 0 || length >= sizeof(address.sun_path)) return -1;
    memset(&address, 0, sizeof(address)); address.sun_family = AF_UNIX; memcpy(address.sun_path, path, length + 1);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address))) { close(fd); return -1; } return fd;
}

int main(int argc, char **argv) {
    pthread_t thread; struct header header; char *body = NULL; int started = 0;
    if (argc != 2 || curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK || read_config() || (socket_fd = connect_appload(argv[1])) < 0) return 1;
    if (pthread_create(&thread, NULL, poll_loop, NULL) == 0) started = 1;
    while (recv(socket_fd, &header, sizeof(header), 0) == (ssize_t)sizeof(header) && header.length <= MAX_JSON) {
        free(body); body = calloc(header.length + 1U, 1); if (!body || (header.length && recv(socket_fd, body, header.length, 0) != (ssize_t)header.length)) break;
        if (header.type == MSG_SYSTEM_TERMINATE) break;
        if (header.type == MSG_SYSTEM_NEW_COORDINATOR) { pthread_mutex_lock(&state_lock); refresh = 1; pthread_mutex_unlock(&state_lock); }
        else if (header.type == MSG_SELECT) { pthread_mutex_lock(&state_lock); snprintf(selected, sizeof(selected), "%s", body); refresh = 1; pthread_mutex_unlock(&state_lock); }
        else if (header.type == MSG_ACTION) post_action(body);
    }
    stopping = 1; shutdown(socket_fd, SHUT_RDWR); close(socket_fd); if (started) pthread_join(thread, NULL); free(body); curl_global_cleanup(); return 0;
}
