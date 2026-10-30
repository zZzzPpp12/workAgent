import Foundation

struct UpdateIdentity: Equatable {
    var team: String?
    var identifier: String?
    static func parse(_ output: String) -> UpdateIdentity {
        var fields: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { fields[pair[0]] = pair[1] }
        }
        let team = fields["TeamIdentifier"].flatMap { $0 == "not set" || $0.isEmpty ? nil : $0 }
        return UpdateIdentity(team: team, identifier: fields["Identifier"])
    }
    func accepts(_ incoming: UpdateIdentity) -> Bool {
        guard let team, let identifier else { return false }
        return incoming.team == team && incoming.identifier == identifier
    }
}
