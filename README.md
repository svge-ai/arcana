# Arcana

Zig multi-provider LLM client library.

## Features

- Multi-provider support: Anthropic, OpenAI, OpenRouter, Ollama
- Structured message types (system, user, assistant, tool)
- Tool/function calling with JSON schema
- Agent abstraction with conversation management
- Streaming support (planned)

## Usage

```zig
const arcana = @import("arcana");

var provider = arcana.providers.anthropic.init(allocator, .{
    .api_key = key,
});
var model = try provider.languageModel("claude-sonnet-4-6");
var result = try model.generate(.{ .prompt = "Hello" });
```

## License

Apache-2.0
