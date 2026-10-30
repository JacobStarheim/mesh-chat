import Foundation
import MeshCore

// Measures how far a public message gets on a random mesh for different TTLs.
//
//   swift run meshsim [--nodes 40] [--range 22] [--area 100] [--loss 0.1] [--trials 40] [--seed 7]
//
// Nodes are dropped at random in an area x area metre square; two nodes are linked
// when they're within `range` metres (roughly BLE indoors). Each trial sends one
// message from a random node and counts who received it and how many radio
// transmissions that cost.

struct Options {
    var nodes = 40
    var range = 22.0
    var area = 100.0
    var loss = 0.1
    var trials = 40
    var seed: UInt64 = 7

    init(arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let flag = iterator.next() {
            guard let value = iterator.next() else { break }
            switch flag {
            case "--nodes": nodes = Int(value) ?? nodes
            case "--range": range = Double(value) ?? range
            case "--area": area = Double(value) ?? area
            case "--loss": loss = Double(value) ?? loss
            case "--trials": trials = Int(value) ?? trials
            case "--seed": seed = UInt64(value) ?? seed
            default: print("unknown option \(flag)")
            }
        }
    }
}

final class Counter: MeshRouterDelegate {
    var received = 0

    func router(_ router: MeshRouter, didReceive message: ReceivedMessage) {
        received += 1
    }
}

struct TrialResult {
    var reached = 0
    var reachable = 0
    var transmissions = 0
}

func runTrial(ttl: UInt8, options: Options, random: inout SplitMix64) -> TrialResult {
    let positions = (0..<options.nodes).map { _ in
        (x: Double.random(in: 0..<options.area, using: &random), y: Double.random(in: 0..<options.area, using: &random))
    }
    var neighbours = Array(repeating: [Int](), count: options.nodes)
    for i in 0..<options.nodes {
        for j in (i + 1)..<options.nodes {
            let dx = positions[i].x - positions[j].x
            let dy = positions[i].y - positions[j].y
            if (dx * dx + dy * dy).squareRoot() <= options.range {
                neighbours[i].append(j)
                neighbours[j].append(i)
            }
        }
    }

    let network = SimulatedNetwork(lossRate: options.loss, seed: random.next())
    let transports = (0..<options.nodes).map { network.makeTransport(name: "n\($0)") }
    let counters = transports.map { _ in Counter() }
    let routers = transports.enumerated().map { index, transport in
        let router = MeshRouter(identity: Identity(nickname: "n\(index)"), transport: transport)
        router.delegate = counters[index]
        return router
    }
    for (i, list) in neighbours.enumerated() {
        for j in list where j > i { network.connect(transports[i], transports[j]) }
    }
    routers.forEach { $0.start() }
    network.run()

    let sender = Int.random(in: 0..<options.nodes, using: &random)
    let before = network.transmissions
    _ = try? routers[sender].sendPublic("hello", ttl: ttl)
    // Transports only hold their router weakly; keep the routers alive while frames are in flight.
    withExtendedLifetime(routers) { network.run() }

    var result = TrialResult()
    result.reached = counters.filter { $0.received > 0 }.count
    result.reachable = reachableCount(from: sender, neighbours: neighbours)
    result.transmissions = network.transmissions - before
    return result
}

/// Nodes connected to `start` by any path, at any hop count (excluding `start`).
func reachableCount(from start: Int, neighbours: [[Int]]) -> Int {
    var visited: Set<Int> = [start]
    var frontier = [start]
    while let node = frontier.popLast() {
        for next in neighbours[node] where visited.insert(next).inserted {
            frontier.append(next)
        }
    }
    return visited.count - 1
}

let options = Options(arguments: CommandLine.arguments)
print("nodes=\(options.nodes) range=\(Int(options.range))m area=\(Int(options.area))x\(Int(options.area))m loss=\(Int(options.loss * 100))% trials=\(options.trials)")
print("")
print("TTL  reached (all)  reached (connected)  radio tx per message")
print("---  -------------  -------------------  --------------------")

for ttl: UInt8 in [1, 2, 3, 5, 7] {
    var random = SplitMix64(seed: options.seed)
    var total = TrialResult()
    for _ in 0..<options.trials {
        let trial = runTrial(ttl: ttl, options: options, random: &random)
        total.reached += trial.reached
        total.reachable += trial.reachable
        total.transmissions += trial.transmissions
    }
    let others = Double(options.trials * (options.nodes - 1))
    let ofAll = Double(total.reached) / others * 100
    let ofReachable = total.reachable == 0 ? 0 : Double(total.reached) / Double(total.reachable) * 100
    let transmissions = Double(total.transmissions) / Double(options.trials)
    print(String(format: "%3d  %12.1f%%  %18.1f%%  %20.1f", Int(ttl), ofAll, ofReachable, transmissions))
}
