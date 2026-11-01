#include <yaml-cpp/yaml.h>

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace {

int bech32Value(const char character) {
    static constexpr std::string_view alphabet = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
    const auto position = alphabet.find(static_cast<char>(std::tolower(static_cast<unsigned char>(character))));
    if (position == std::string_view::npos) {
        throw std::runtime_error("invalid Bech32 character");
    }
    return static_cast<int>(position);
}

std::vector<std::uint8_t> convertFiveToEight(const std::vector<int>& values) {
    std::vector<std::uint8_t> output;
    std::uint32_t accumulator = 0;
    int bits = 0;
    constexpr std::uint32_t mask = (1U << 12U) - 1U;

    for (const int value : values) {
        if (value < 0 || value > 31) {
            throw std::runtime_error("Bech32 value is outside the five-bit range");
        }
        accumulator = ((accumulator << 5U) | static_cast<std::uint32_t>(value)) & mask;
        bits += 5;
        while (bits >= 8) {
            bits -= 8;
            output.push_back(static_cast<std::uint8_t>((accumulator >> bits) & 0xffU));
        }
    }

    if (bits >= 5 || ((accumulator << (8 - bits)) & 0xffU) != 0U) {
        throw std::runtime_error("invalid Bech32 padding");
    }
    return output;
}

std::vector<std::uint8_t> decodePuzzleHash(const std::string& address) {
    const auto separator = address.rfind('1');
    if (separator == std::string::npos || separator == 0 || separator + 7 >= address.size()) {
        throw std::runtime_error("invalid Chia address");
    }

    std::vector<int> values;
    values.reserve(address.size() - separator - 7);
    for (std::size_t index = separator + 1; index + 6 < address.size(); ++index) {
        values.push_back(bech32Value(address[index]));
    }

    auto bytes = convertFiveToEight(values);
    if (bytes.size() != 32) {
        throw std::runtime_error("Chia address did not decode to a 32-byte puzzle hash");
    }
    return bytes;
}

std::string hexEncode(const std::vector<std::uint8_t>& bytes) {
    static constexpr char digits[] = "0123456789abcdef";
    std::string output;
    output.reserve(bytes.size() * 2);
    for (const std::uint8_t byte : bytes) {
        output.push_back(digits[(byte >> 4U) & 0x0fU]);
        output.push_back(digits[byte & 0x0fU]);
    }
    return output;
}

YAML::Node stringSequence(const std::vector<std::string>& values) {
    YAML::Node sequence(YAML::NodeType::Sequence);
    for (const auto& value : values) {
        sequence.push_back(value);
    }
    return sequence;
}

YAML::Node integerSequence(const std::vector<int>& values) {
    YAML::Node sequence(YAML::NodeType::Sequence);
    for (const int value : values) {
        sequence.push_back(value);
    }
    return sequence;
}

YAML::Node peerList(const std::vector<std::string>& hosts, const int port = 8444) {
    YAML::Node peers(YAML::NodeType::Sequence);
    for (const auto& host : hosts) {
        YAML::Node peer(YAML::NodeType::Map);
        peer["host"] = host;
        peer["port"] = port;
        peers.push_back(peer);
    }
    return peers;
}

std::vector<std::string> fullNodePeers(const std::string& nodeId) {
    std::vector<std::string> peers;
    for (const std::string& farmer : {"node01", "node02", "node03", "node04"}) {
        if (farmer != "node" + nodeId) {
            peers.push_back(farmer);
        }
    }
    return peers;
}

std::string timelordHost(const std::string& nodeId) {
    if (nodeId == "06" || nodeId == "07") {
        return "127.0.0.1";
    }
    if (nodeId == "08") {
        return "node06";
    }
    if (nodeId == "09") {
        return "node07";
    }
    return "node06";
}

std::vector<std::string> vdfClientIps(const std::string& nodeId) {
    if (nodeId == "07" || nodeId == "09") {
        return {"127.0.0.1", "172.28.0.19"};
    }
    return {"127.0.0.1", "172.28.0.18"};
}

void configureConsensus(YAML::Node& root, const std::string& prefarmPuzzleHash) {
    YAML::Node constants(YAML::NodeType::Map);
    const std::string genesis = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    constants["GENESIS_CHALLENGE"] = genesis;
    constants["GENESIS_PRE_FARM_POOL_PUZZLE_HASH"] = prefarmPuzzleHash;
    constants["GENESIS_PRE_FARM_FARMER_PUZZLE_HASH"] = prefarmPuzzleHash;
    constants["AGG_SIG_ME_ADDITIONAL_DATA"] = genesis;
    constants["MIN_PLOT_SIZE_V1"] = 18;
    constants["PLOT_SIZE_V2"] = 20;
    constants["MIN_BLOCKS_PER_CHALLENGE_BLOCK"] = 12;
    // Use a low initial difficulty for fast private-chain bootstrap.
    constants["DIFFICULTY_STARTING"] = 128;
    // Use production-size VDF discriminants so the configured 150k IPS
    // estimate is meaningful and the two-second signage-point cadence holds.
    constants["DISCRIMINANT_SIZE_BITS"] = 1024;
    constants["SUB_EPOCH_BLOCKS"] = 170;
    constants["WEIGHT_PROOF_THRESHOLD"] = 2;
    constants["WEIGHT_PROOF_RECENT_BLOCKS"] = 500;
    // Keep K25 farming inexpensive on the private network.
    constants["DIFFICULTY_CONSTANT_FACTOR"] = 1;
    constants["NUM_SPS_SUB_SLOT"] = 16;
    constants["MAX_SUB_SLOT_BLOCKS"] = 50;
    constants["EPOCH_BLOCKS"] = 340;
    constants["BLOCKS_CACHE_SIZE"] = 1020;
    // Space signage points two seconds apart for bootstrap monitoring and
    // repeatable farming activity during the contention measurements.
    constants["SUB_SLOT_TIME_TARGET"] = 32;
    constants["SUB_SLOT_ITERS_STARTING"] = 4800000;
    constants["NUMBER_ZERO_BITS_PLOT_FILTER_V1"] = 0;
    constants["NUMBER_ZERO_BITS_PLOT_FILTER_V2"] = 0;
    constants["MAX_FUTURE_TIME2"] = 864000;
    constants["MEMPOOL_BLOCK_BUFFER"] = 6;
    constants["PLOT_V1_PHASE_OUT_EPOCH_BITS"] = 3;
    constants["TESTNET"] = true;

    root["network_overrides"]["constants"]["private200"] = constants;
    root["network_overrides"]["config"]["private200"]["address_prefix"] = "txch";
    root["network_overrides"]["config"]["private200"]["default_full_node_port"] = 8444;
    root["selected_network"] = "private200";
    root["min_mainnet_k_size"] = 18;
}

void configureCommonServices(YAML::Node& root) {
    root["self_hostname"] = "127.0.0.1";
    root["daemon_port"] = 55400;
    root["prefer_ipv6"] = false;
    root["logging"]["log_stdout"] = false;
    root["logging"]["log_filename"] = "log/debug.log";
    root["logging"]["log_level"] = "INFO";
    root["logging"]["log_backcompat"] = false;

    const std::vector<std::string> services = {
        "full_node", "wallet", "farmer", "harvester", "timelord", "pool"
    };
    for (const auto& service : services) {
        root[service]["selected_network"] = "private200";
        root[service]["network_overrides"] = root["network_overrides"];
        root[service]["logging"] = root["logging"];
    }
    root["timelord_launcher"]["logging"] = root["logging"];
}

void configureFullNode(YAML::Node& root, const std::string& nodeId) {
    auto node = root["full_node"];
    node["port"] = 8444;
    node["rpc_port"] = 8555;
    node["start_rpc_server"] = true;
    node["database_path"] = "db/blockchain_v2_CHALLENGE.sqlite";
    node["db_sync"] = "off";
    node["db_readers"] = 1;
    node["single_threaded"] = true;
    node["reserved_cores"] = 0;
    node["enable_upnp"] = false;
    node["peer_connect_interval"] = 2;
    node["peer_connect_timeout"] = 5;
    node["target_peer_count"] = 12;
    node["target_outbound_peer_count"] = 4;
    node["max_sync_wait"] = 5;
    node["sync_blocks_behind_threshold"] = 20;
    node["short_sync_blocks_behind_threshold"] = 10;
    node["full_node_peers"] = peerList(fullNodePeers(nodeId));
    node["dns_servers"] = YAML::Node(YAML::NodeType::Sequence);
    node["introducer_peer"] = YAML::Node(YAML::NodeType::Null);
    node["trusted_peers"] = YAML::Node(YAML::NodeType::Map);
    // Chia rejects inbound timelord connections unless they originate from
    // localhost or an exempt network. The timelords run in separate
    // containers, so exempt only their fixed addresses instead of the whole
    // Docker subnet.
    node["exempt_peer_networks"] = stringSequence({"172.28.0.16/32", "172.28.0.17/32"});
}

void configureWallet(YAML::Node& root) {
    auto wallet = root["wallet"];
    wallet["rpc_port"] = 9256;
    wallet["start_rpc_server"] = true;
    wallet["db_sync"] = "off";
    wallet["db_readers"] = 1;
    wallet["connect_to_unknown_peers"] = false;
    wallet["target_peer_count"] = 1;
    wallet["peer_connect_interval"] = 2;
    wallet["full_node_peers"] = peerList({"127.0.0.1"});
    wallet["dns_servers"] = YAML::Node(YAML::NodeType::Sequence);
    wallet["introducer_peer"] = YAML::Node(YAML::NodeType::Null);
    wallet["trusted_peers"] = YAML::Node(YAML::NodeType::Map);
}

void configureFarmerAndHarvester(YAML::Node& root, const std::string& rewardAddress) {
    root["farmer"]["full_node_peers"] = peerList({"127.0.0.1"});
    root["farmer"]["xch_target_address"] = rewardAddress;
    root["pool"]["xch_target_address"] = rewardAddress;
    root["farmer"]["solver_peers"] = YAML::Node(YAML::NodeType::Sequence);
    root["farmer"]["rpc_port"] = 8559;
    root["farmer"]["start_rpc_server"] = true;

    root["harvester"]["farmer_peers"] = peerList({"127.0.0.1"}, 8447);
    root["harvester"]["rpc_port"] = 8560;
    root["harvester"]["start_rpc_server"] = true;
    root["harvester"]["num_threads"] = 2;
    root["harvester"]["plot_directories"] = stringSequence({"/run/chia/plots"});
    root["harvester"]["plots_refresh_parameter"]["interval_seconds"] = 5;
    root["harvester"]["plots_refresh_parameter"]["retry_invalid_seconds"] = 30;
    root["harvester"]["plots_refresh_parameter"]["batch_size"] = 20;
}

void configureTimelord(YAML::Node& root, const std::string& nodeId) {
    root["timelord"]["full_node_peers"] = peerList({"node01", "node02", "node03", "node04"});
    root["timelord"]["vdf_server"]["host"] = "0.0.0.0";
    root["timelord"]["vdf_server"]["port"] = 8000;
    root["timelord"]["vdf_clients"]["ip"] = stringSequence(vdfClientIps(nodeId));
    root["timelord"]["vdf_clients"]["ips_estimate"] = integerSequence({150000, 150000, 150000});
    root["timelord"]["max_connection_time"] = 300;
    root["timelord"]["rpc_port"] = 8557;
    root["timelord"]["start_rpc_server"] = true;
    root["timelord"]["bluebox_mode"] = false;
    root["timelord"]["slow_bluebox"] = false;

    root["timelord_launcher"]["host"] = timelordHost(nodeId);
    root["timelord_launcher"]["port"] = 8000;
    // Each timelord needs clients for the challenge, reward, and infused
    // challenge chains. Run two locally and one in the paired VDF container.
    root["timelord_launcher"]["process_count"] = (nodeId == "06" || nodeId == "07") ? 2 : 1;
}

void clearUnusedDiscovery(YAML::Node& root) {
    if (root["seeder"]) {
        root["seeder"]["bootstrap_peers"] = YAML::Node(YAML::NodeType::Sequence);
        root["seeder"]["static_peers"] = YAML::Node(YAML::NodeType::Sequence);
    }
}

void writeConfiguration(const std::filesystem::path& path, const YAML::Node& root) {
    YAML::Emitter emitter;
    emitter.SetIndent(2);
    emitter << root;
    if (!emitter.good()) {
        throw std::runtime_error(std::string("failed to emit YAML: ") + emitter.GetLastError());
    }

    const auto temporary = path.string() + ".tmp";
    std::ofstream stream(temporary, std::ios::trunc);
    if (!stream) {
        throw std::runtime_error("unable to open temporary configuration file");
    }
    stream << emitter.c_str() << '\n';
    stream.close();
    if (!stream) {
        throw std::runtime_error("unable to write configuration file");
    }
    std::filesystem::rename(temporary, path);
}

void validateRole(const std::string& role) {
    if (role != "farmer" && role != "timelord" && role != "vdf") {
        throw std::runtime_error("role must be farmer, timelord, or vdf");
    }
}

}
int main(const int argc, char* argv[]) {
    try {
        if (argc != 5) {
            std::cerr << "Usage: chia-config CONFIG_PATH NODE_ID ROLE PREFARM_ADDRESS\n";
            return 64;
        }

        const std::filesystem::path configPath = argv[1];
        const std::string nodeId = argv[2];
        const std::string role = argv[3];
        const std::string address = argv[4];

        if (nodeId.size() != 2 || nodeId[0] != '0' || nodeId[1] < '1' || nodeId[1] > '9') {
            throw std::runtime_error("node ID must be in the range 01..09");
        }
        validateRole(role);

        YAML::Node root = YAML::LoadFile(configPath.string());
        const std::string prefarmPuzzleHash = hexEncode(decodePuzzleHash(address));

        configureConsensus(root, prefarmPuzzleHash);
        configureCommonServices(root);
        configureFullNode(root, nodeId);
        configureWallet(root);
        configureFarmerAndHarvester(root, address);
        configureTimelord(root, nodeId);
        clearUnusedDiscovery(root);
        writeConfiguration(configPath, root);

        return 0;
    } catch (const std::exception& error) {
        std::cerr << "[config][ERROR] " << error.what() << '\n';
        return 1;
    }
}
