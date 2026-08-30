#include <arpa/inet.h>
#include <netdb.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>
#include <cstring>
#include <iostream>
#include <set>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;

class FileDescriptor {
public:
        explicit FileDescriptor(const int descriptor = -1) : descriptor_(descriptor) {}

        ~FileDescriptor() {
        if (descriptor_ >= 0) {
            ::close(descriptor_);
        }
    }

        FileDescriptor(const FileDescriptor&) = delete;

        FileDescriptor& operator=(const FileDescriptor&) = delete;

        FileDescriptor(FileDescriptor&& other) noexcept : descriptor_(other.descriptor_) {
        other.descriptor_ = -1;
    }

        FileDescriptor& operator=(FileDescriptor&& other) noexcept {
        if (this != &other) {
            if (descriptor_ >= 0) {
                ::close(descriptor_);
            }
            descriptor_ = other.descriptor_;
            other.descriptor_ = -1;
        }
        return *this;
    }

        int get() const {
        return descriptor_;
    }

private:
    int descriptor_;
};

int parsePositive(const std::string& text, const std::string& name, const int maximum) {
    std::size_t consumed = 0;
    const long value = std::stol(text, &consumed, 10);
    if (consumed != text.size() || value < 1 || value > maximum) {
        throw std::runtime_error(name + " is outside the supported range");
    }
    return static_cast<int>(value);
}

int pollTimeout(const Clock::time_point deadline) {
    const auto now = Clock::now();
    if (now >= deadline) {
        return 0;
    }
    const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count();
    return static_cast<int>(std::min<long long>(1000, std::max<long long>(1, remaining)));
}

bool waitForDescriptor(const int descriptor, const short events, const Clock::time_point deadline) {
    while (Clock::now() < deadline) {
        pollfd item{descriptor, events, 0};
        const int result = ::poll(&item, 1, pollTimeout(deadline));
        if (result > 0) {
            if ((item.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0 && (item.revents & events) == 0) {
                return false;
            }
            return (item.revents & events) != 0;
        }
        if (result < 0 && errno != EINTR) {
            throw std::runtime_error(std::string("poll failed: ") + std::strerror(errno));
        }
    }
    return false;
}

void writeAll(const int descriptor, const std::string& data, const Clock::time_point deadline) {
    std::size_t offset = 0;
    while (offset < data.size()) {
        if (!waitForDescriptor(descriptor, POLLOUT, deadline)) {
            throw std::runtime_error("socket write timed out");
        }
        const ssize_t written = ::send(descriptor, data.data() + offset, data.size() - offset, MSG_NOSIGNAL);
        if (written > 0) {
            offset += static_cast<std::size_t>(written);
            continue;
        }
        if (written < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) {
            continue;
        }
        throw std::runtime_error(std::string("socket write failed: ") + std::strerror(errno));
    }
}

std::string readLine(const int descriptor, const Clock::time_point deadline) {
    std::string line;
    while (line.size() < 4096) {
        if (!waitForDescriptor(descriptor, POLLIN, deadline)) {
            throw std::runtime_error("socket read timed out");
        }
        char character = '\0';
        const ssize_t received = ::recv(descriptor, &character, 1, 0);
        if (received == 1) {
            if (character == '\n') {
                return line;
            }
            if (character != '\r') {
                line.push_back(character);
            }
            continue;
        }
        if (received == 0) {
            return line;
        }
        if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
            continue;
        }
        throw std::runtime_error(std::string("socket read failed: ") + std::strerror(errno));
    }
    throw std::runtime_error("received signal line is too long");
}

FileDescriptor createListener(const int port) {
    FileDescriptor listener(::socket(AF_INET, SOCK_STREAM, 0));
    if (listener.get() < 0) {
        throw std::runtime_error(std::string("socket failed: ") + std::strerror(errno));
    }

    int enabled = 1;
    if (::setsockopt(listener.get(), SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled)) != 0) {
        throw std::runtime_error(std::string("setsockopt failed: ") + std::strerror(errno));
    }

    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    address.sin_port = htons(static_cast<std::uint16_t>(port));
    if (::bind(listener.get(), reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
        throw std::runtime_error(std::string("bind failed: ") + std::strerror(errno));
    }
    if (::listen(listener.get(), 32) != 0) {
        throw std::runtime_error(std::string("listen failed: ") + std::strerror(errno));
    }
    return listener;
}

FileDescriptor connectOnce(const std::string& host, const int port) {
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    addrinfo* rawResults = nullptr;
    const std::string service = std::to_string(port);
    const int lookup = ::getaddrinfo(host.c_str(), service.c_str(), &hints, &rawResults);
    if (lookup != 0) {
        return FileDescriptor();
    }

    FileDescriptor connected;
    for (addrinfo* current = rawResults; current != nullptr; current = current->ai_next) {
        FileDescriptor candidate(::socket(current->ai_family, current->ai_socktype, current->ai_protocol));
        if (candidate.get() < 0) {
            continue;
        }
        if (::connect(candidate.get(), current->ai_addr, current->ai_addrlen) == 0) {
            connected = std::move(candidate);
            break;
        }
    }
    ::freeaddrinfo(rawResults);
    return connected;
}

int serve(const int port, const int expected, const std::string& message, const int timeoutSeconds) {
    FileDescriptor listener = createListener(port);
    const auto deadline = Clock::now() + std::chrono::seconds(timeoutSeconds);
    std::set<std::string> seen;
    std::vector<FileDescriptor> connections;
    connections.reserve(static_cast<std::size_t>(expected));

    while (static_cast<int>(connections.size()) < expected) {
        if (!waitForDescriptor(listener.get(), POLLIN, deadline)) {
            throw std::runtime_error("signal server timed out after receiving " + std::to_string(connections.size()) +
                                     "/" + std::to_string(expected) + " unique clients");
        }

        sockaddr_storage peer{};
        socklen_t peerLength = sizeof(peer);
        FileDescriptor connection(::accept(listener.get(), reinterpret_cast<sockaddr*>(&peer), &peerLength));
        if (connection.get() < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                continue;
            }
            throw std::runtime_error(std::string("accept failed: ") + std::strerror(errno));
        }

        const std::string node = readLine(connection.get(), deadline);
        if (node.empty() || !seen.insert(node).second) {
            continue;
        }
        connections.push_back(std::move(connection));
    }

    for (const auto& connection : connections) {
        writeAll(connection.get(), message + "\n", deadline);
    }
    return 0;
}

int waitForMessage(const std::string& host, const int port, const std::string& nodeName, const int timeoutSeconds) {
    const auto deadline = Clock::now() + std::chrono::seconds(timeoutSeconds);
    while (Clock::now() < deadline) {
        FileDescriptor connection = connectOnce(host, port);
        if (connection.get() >= 0) {
            try {
                writeAll(connection.get(), nodeName + "\n", deadline);
                const std::string message = readLine(connection.get(), deadline);
                if (!message.empty()) {
                    std::cout << message << '\n';
                    return 0;
                }
            } catch (const std::exception&) {
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
    }
    throw std::runtime_error("timed out waiting for signal from " + host + ':' + std::to_string(port));
}

void printUsage() {
    std::cerr << "Usage:\n"
              << "  sia-signal serve PORT EXPECTED MESSAGE TIMEOUT_SECONDS\n"
              << "  sia-signal wait HOST PORT NODE_NAME TIMEOUT_SECONDS\n";
}

}
int main(const int argc, char* argv[]) {
    try {
        if (argc < 2) {
            printUsage();
            return 64;
        }
        const std::string mode = argv[1];
        if (mode == "serve" && argc == 6) {
            return serve(parsePositive(argv[2], "port", 65535), parsePositive(argv[3], "expected", 1000), argv[4],
                         parsePositive(argv[5], "timeout", 86400));
        }
        if (mode == "wait" && argc == 6) {
            return waitForMessage(argv[2], parsePositive(argv[3], "port", 65535), argv[4],
                                  parsePositive(argv[5], "timeout", 86400));
        }
        printUsage();
        return 64;
    } catch (const std::exception& error) {
        std::cerr << "[signal][ERROR] " << error.what() << '\n';
        return 1;
    }
}
