import Vapor

public struct SlackCommand {
    /// Command name
    public let name: String

    /// Command usage instructions
    public let help: String

    /// Channels from which this command is allowed to be triggered.
    /// If empty the command will be allowed in all channels
    public let allowedChannels: Set<String>

    let run: (SlackCommandMetadata, Request) throws -> Future<SlackResponse>

    public init(
        name: String,
        help: String,
        allowedChannels: Set<String>,
        run: @escaping (SlackCommandMetadata, Request) throws -> Future<SlackResponse>
    ) {
        self.name = name
        self.allowedChannels = allowedChannels
        self.help = help
        self.run = run
    }
}

public struct SlackCommandMetadata: Content {
    public let token: String
    public let channelName: String
    public let text: String
    public let responseURL: String

    enum CodingKeys: String, CodingKey {
        case token
        case channelName = "channel_name"
        case text
        case responseURL = "response_url"
    }
}

public struct SlackResponse: Content {
    public let text: String
    public let visibility: Visibility

    public enum Visibility: String, Content {
        /// Response message visible only to the user who triggered the command
        case user = "ephemeral"
        /// Response message visible to all members of the channel where the command was triggered
        case channel = "in_channel"
    }

    enum CodingKeys: String, CodingKey {
        case text
        case visibility = "response_type"
    }

    public init(_ text: String, visibility: Visibility = .channel) {
        self.text = text
        self.visibility = visibility
    }
}

public struct SlackService {
    let token: String

    public init(token: String) {
        self.token = token
    }

    public func handle(command: SlackCommand, on request: Request) throws -> Future<Response> {
        let metadata: SlackCommandMetadata = try attempt {
            try request.content.syncDecode(SlackCommandMetadata.self)
        }

        guard metadata.token == token else {
            throw Error.invalidToken
        }

        guard command.allowedChannels.isEmpty || command.allowedChannels.contains(metadata.channelName) else {
            throw Error.invalidChannel(metadata.channelName, allowed: command.allowedChannels)
        }

        if metadata.text == "help" {
            return try SlackResponse(command.help)
                .encode(for: request)
        } else {
            return try command
                .run(metadata, request)
                .mapIfError { SlackResponse($0.localizedDescription, visibility: .user) }
                .encode(for: request)
        }
    }

}

extension Future where T == SlackResponse {
    public func replyLater(
        withImmediateResponse now: SlackResponse,
        responseURL: String,
        request: Request
    ) -> Future<SlackResponse> {
        _ = self
            .mapIfError { SlackResponse($0.localizedDescription, visibility: .user) }
            .flatMap { response in
                try request.client()
                    .post(responseURL, headers: ["Content-type": "application/json"]) {
                        try $0.content.encode(response)
                    }
                    .catchError(.capture())
        }

        return request.eventLoop.newSucceededFuture(result: now)
    }
}
