#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <curl/curl.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#define CONFIG_PATH "/home/root/.config/paperboard/config"
#define STATE_DIR "/home/root/.local/share/paperboard"
#define CANDIDATE_PATH STATE_DIR "/candidate.png"
#define LAST_GOOD_PATH STATE_DIR "/dashboard.png"
#define MAX_CONFIG_SIZE 4096
#define MAX_IMAGE_SIZE (8U * 1024U * 1024U)
#define MAX_MESSAGE_SIZE 10485760U

enum {
    MSG_REFRESH = 1,
    MSG_ACCEPT = 2,
    MSG_REJECT = 3,
    MSG_STATUS = 101,
    MSG_CANDIDATE = 102,
    MSG_ERROR = 103,
    MSG_LAST_GOOD = 104,
};

#define MSG_SYSTEM_TERMINATE UINT32_MAX
#define MSG_SYSTEM_NEW_COORDINATOR (UINT32_MAX - 1U)

struct message_header {
    uint32_t type;
    uint32_t length;
};

static int socket_fd = -1;
static CURLcode last_download_result = CURLE_OK;
static char last_download_error[CURL_ERROR_SIZE];

static void send_message(uint32_t type, const char *contents) {
    struct message_header header;
    size_t length = contents == NULL ? 0 : strlen(contents);

    if (length > MAX_MESSAGE_SIZE) return;
    header.type = type;
    header.length = (uint32_t)length;
    if (send(socket_fd, &header, sizeof(header), MSG_NOSIGNAL) != (ssize_t)sizeof(header)) return;
    if (length > 0) (void)send(socket_fd, contents, length, MSG_NOSIGNAL);
}

static int make_state_directory(void) {
    struct stat metadata;

    if (mkdir("/home/root/.local", 0700) != 0 && errno != EEXIST) return -1;
    if (mkdir("/home/root/.local/share", 0700) != 0 && errno != EEXIST) return -1;
    if (mkdir(STATE_DIR, 0700) != 0 && errno != EEXIST) return -1;
    if (lstat(STATE_DIR, &metadata) != 0 || !S_ISDIR(metadata.st_mode) || metadata.st_uid != 0) return -1;
    return chmod(STATE_DIR, 0700);
}

static int valid_https_url(const char *url) {
    const char *authority;
    const char *cursor;

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

static int read_url(char *url, size_t capacity, char *error, size_t error_capacity) {
    struct stat metadata;
    FILE *file;
    char config[MAX_CONFIG_SIZE + 1];
    size_t count;
    char *newline;
    const char prefix[] = "url=";

    if (lstat(CONFIG_PATH, &metadata) != 0) {
        snprintf(error, error_capacity, "No config. Add %s with mode 0600.", CONFIG_PATH);
        return -1;
    }
    if (!S_ISREG(metadata.st_mode) || metadata.st_uid != 0 || (metadata.st_mode & 077) != 0) {
        snprintf(error, error_capacity, "Config must be a root-owned regular file with mode 0600.");
        return -1;
    }
    if (metadata.st_size <= 0 || metadata.st_size > MAX_CONFIG_SIZE) {
        snprintf(error, error_capacity, "Config size is invalid.");
        return -1;
    }
    file = fopen(CONFIG_PATH, "r");
    if (file == NULL) {
        snprintf(error, error_capacity, "Cannot read config.");
        return -1;
    }
    count = fread(config, 1, sizeof(config) - 1, file);
    fclose(file);
    config[count] = '\0';
    newline = strchr(config, '\n');
    if (newline != NULL) *newline = '\0';
    if (strncmp(config, prefix, sizeof(prefix) - 1) != 0) {
        snprintf(error, error_capacity, "Config must contain one url=https://... line.");
        return -1;
    }
    if (strlen(config + sizeof(prefix) - 1) >= capacity) {
        snprintf(error, error_capacity, "URL is too long.");
        return -1;
    }
    strcpy(url, config + sizeof(prefix) - 1);
    if (!valid_https_url(url)) {
        snprintf(error, error_capacity, "Only HTTPS URLs without embedded user info are allowed.");
        return -1;
    }
    return 0;
}

struct download_target {
    FILE *file;
    size_t received;
};

static size_t write_download(void *contents, size_t size, size_t count, void *user_data) {
    struct download_target *target = user_data;
    size_t bytes;

    if (count != 0 && size > SIZE_MAX / count) return 0;
    bytes = size * count;
    if (bytes > MAX_IMAGE_SIZE - target->received) return 0;
    if (fwrite(contents, 1, bytes, target->file) != bytes) return 0;
    target->received += bytes;
    return bytes;
}

static int download_candidate(const char *url) {
    struct download_target target = { 0 };
    CURL *curl;
    CURLcode result;
    int descriptor;

    last_download_result = CURLE_OK;
    last_download_error[0] = '\0';
    unlink(CANDIDATE_PATH);
    descriptor = open(CANDIDATE_PATH, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (descriptor < 0) return -1;
    target.file = fdopen(descriptor, "wb");
    if (target.file == NULL) {
        close(descriptor);
        unlink(CANDIDATE_PATH);
        return -1;
    }
    curl = curl_easy_init();
    if (curl == NULL) {
        fclose(target.file);
        unlink(CANDIDATE_PATH);
        return -1;
    }
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, last_download_error);
    curl_easy_setopt(curl, CURLOPT_PROXY, "");
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "https");
    curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS_STR, "https");
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 3L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 10L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 30L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
    curl_easy_setopt(curl, CURLOPT_CAINFO, "/etc/ssl/certs/ca-certificates.crt");
    curl_easy_setopt(curl, CURLOPT_FAILONERROR, 1L);
    curl_easy_setopt(curl, CURLOPT_MAXFILESIZE_LARGE, (curl_off_t)MAX_IMAGE_SIZE);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "Paperboard/0.2");
    curl_easy_setopt(curl, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_download);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &target);
    result = curl_easy_perform(curl);
    curl_easy_cleanup(curl);
    if (fclose(target.file) != 0 && result == CURLE_OK) result = CURLE_WRITE_ERROR;
    last_download_result = result;
    if (result != CURLE_OK) {
        unlink(CANDIDATE_PATH);
        errno = result == CURLE_OPERATION_TIMEDOUT ? ETIMEDOUT : EIO;
        return -1;
    }
    return 0;
}

static int validate_png(char *error, size_t error_capacity) {
    static const unsigned char signature[8] = { 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };
    unsigned char header[24];
    struct stat metadata;
    FILE *file;
    uint32_t width;
    uint32_t height;

    if (stat(CANDIDATE_PATH, &metadata) != 0 || !S_ISREG(metadata.st_mode)) {
        snprintf(error, error_capacity, "Download did not produce a regular file.");
        return -1;
    }
    if (metadata.st_size < (off_t)sizeof(header) || metadata.st_size > (off_t)MAX_IMAGE_SIZE) {
        snprintf(error, error_capacity, "Image must be a PNG no larger than 8 MiB.");
        return -1;
    }
    file = fopen(CANDIDATE_PATH, "rb");
    if (file == NULL || fread(header, 1, sizeof(header), file) != sizeof(header)) {
        if (file != NULL) fclose(file);
        snprintf(error, error_capacity, "Cannot inspect downloaded image.");
        return -1;
    }
    fclose(file);
    if (memcmp(header, signature, sizeof(signature)) != 0 || memcmp(header + 12, "IHDR", 4) != 0) {
        snprintf(error, error_capacity, "Downloaded file is not a PNG.");
        return -1;
    }
    memcpy(&width, header + 16, sizeof(width));
    memcpy(&height, header + 20, sizeof(height));
    width = ntohl(width);
    height = ntohl(height);
    if (width == 0 || height == 0 || width > 8192 || height > 8192 || (uint64_t)width * height > 40000000ULL) {
        snprintf(error, error_capacity, "PNG dimensions exceed the safe decode limit.");
        return -1;
    }
    return 0;
}

static void refresh(void) {
    char url[MAX_CONFIG_SIZE];
    char error[256];

    send_message(MSG_STATUS, "FETCHING");
    if (make_state_directory() != 0) {
        send_message(MSG_ERROR, "Cannot prepare the private state directory.");
        return;
    }
    if (read_url(url, sizeof(url), error, sizeof(error)) != 0) {
        send_message(MSG_ERROR, error);
        return;
    }
    if (download_candidate(url) != 0) {
        unlink(CANDIDATE_PATH);
        if (last_download_result == CURLE_PEER_FAILED_VERIFICATION ||
            last_download_result == CURLE_SSL_CONNECT_ERROR) {
            fprintf(stderr, "paperboard backend: TLS verification failed (%d: %s)\n",
                    (int)last_download_result, last_download_error);
            send_message(MSG_ERROR, "TLS verification failed; last-good image retained.");
        } else if (errno == ETIMEDOUT) {
            send_message(MSG_ERROR, "Download timed out; last-good image retained.");
        } else {
            send_message(MSG_ERROR, "HTTPS download failed; last-good image retained.");
        }
        return;
    }
    if (validate_png(error, sizeof(error)) != 0) {
        unlink(CANDIDATE_PATH);
        send_message(MSG_ERROR, error);
        return;
    }
    send_message(MSG_CANDIDATE, CANDIDATE_PATH);
}

static void accept_candidate(void) {
    if (rename(CANDIDATE_PATH, LAST_GOOD_PATH) != 0) {
        send_message(MSG_ERROR, "Could not atomically promote the decoded image.");
        return;
    }
    (void)chmod(LAST_GOOD_PATH, 0600);
    send_message(MSG_LAST_GOOD, LAST_GOOD_PATH);
}

static int connect_to_appload(const char *path) {
    struct sockaddr_un address;
    size_t path_length = strlen(path);
    int fd;

    if (path_length == 0 || path_length >= sizeof(address.sun_path)) return -1;
    fd = socket(AF_UNIX, SOCK_SEQPACKET, 0);
    if (fd < 0) return -1;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path, path, path_length + 1);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

int main(int argc, char **argv) {
    struct message_header header;
    char *contents = NULL;

    if (argc != 2 || curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK ||
        (socket_fd = connect_to_appload(argv[1])) < 0) return 1;
    for (;;) {
        ssize_t count = recv(socket_fd, &header, sizeof(header), 0);
        if (count != (ssize_t)sizeof(header) || header.length > MAX_MESSAGE_SIZE) break;
        free(contents);
        contents = calloc((size_t)header.length + 1, 1);
        if (contents == NULL) break;
        if (header.length > 0 && recv(socket_fd, contents, header.length, 0) != (ssize_t)header.length) break;
        if (header.type == MSG_SYSTEM_TERMINATE) {
            break;
        } else if (header.type == MSG_SYSTEM_NEW_COORDINATOR) {
            if (access(LAST_GOOD_PATH, R_OK) == 0) send_message(MSG_LAST_GOOD, LAST_GOOD_PATH);
            else send_message(MSG_STATUS, "OFFLINE");
        } else if (header.type == MSG_REFRESH) {
            refresh();
        } else if (header.type == MSG_ACCEPT) {
            accept_candidate();
        } else if (header.type == MSG_REJECT) {
            unlink(CANDIDATE_PATH);
            send_message(MSG_ERROR, "Qt rejected the candidate image; last-good image retained.");
        }
    }
    free(contents);
    close(socket_fd);
    curl_global_cleanup();
    return 0;
}
