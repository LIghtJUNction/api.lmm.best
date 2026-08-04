//! Typed conversions for OpenAI Chat Completions and OpenAI Responses.
//!
//! Legacy provenance:
//! - `relaykit/relayconvert/internal/oai_chat/to_oai_responses_{req,resp,stream_resp}.go`
//! - `relaykit/relayconvert/internal/oai_responses/to_oai_chat_{req,resp,stream_resp}.go`
//! - `relaykit/relayconvert/{request_registry,response_registry}.go`

use std::{
    collections::{BTreeMap, BTreeSet},
    error::Error,
    fmt,
};

use super::{
    CanonicalContent, CanonicalMessage, CanonicalRequest, CanonicalResponse, CanonicalStreamEvent,
    CanonicalTool, CanonicalToolChoice, ClaudeRequest, ClaudeResponse, ClaudeStreamSnapshot,
    Converted, FinishReason, FixtureKind, GeminiRequest, GeminiResponse, GeminiStreamSnapshot,
    JsonData, LossReport, OpenAiChatContentPart, OpenAiChatMessage, OpenAiChatRequest,
    OpenAiChatResponse, OpenAiChatTool, OpenAiChoice, OpenAiFunction, OpenAiResponsesRequest,
    OpenAiStreamChunk, OpenAiStreamDelta, OpenAiStreamSnapshot, OpenAiToolCall, Protocol,
    ReasoningConfig, RequestOptions, ResponsesContentPart, ResponsesInput, ResponsesInputItem,
    ResponsesOutputContent, ResponsesOutputItem, ResponsesResponse, ResponsesStreamEvent,
    ResponsesStreamSnapshot, ResponsesTool, Role, StreamContentKind, StringOrParts, TokenDetails,
    TokenUsage, WireError, WireUsage,
};

#[derive(Debug)]
pub enum RelayConvertError {
    Json(serde_json::Error),
    Missing(&'static str),
    Unsupported(String),
}

impl fmt::Display for RelayConvertError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Json(error) => write!(formatter, "invalid relay JSON: {error}"),
            Self::Missing(field) => write!(formatter, "missing required relay field: {field}"),
            Self::Unsupported(message) => formatter.write_str(message),
        }
    }
}

impl Error for RelayConvertError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Json(error) => Some(error),
            Self::Missing(_) | Self::Unsupported(_) => None,
        }
    }
}

impl From<serde_json::Error> for RelayConvertError {
    fn from(value: serde_json::Error) -> Self {
        Self::Json(value)
    }
}

pub fn openai_chat_request_to_canonical(
    request: OpenAiChatRequest,
) -> Result<Converted<CanonicalRequest>, RelayConvertError> {
    if request.model.trim().is_empty() {
        return Err(RelayConvertError::Missing("model"));
    }

    if request.n.unwrap_or(1) > 1 {
        return Err(RelayConvertError::Unsupported(
            "Chat n > 1 cannot be represented by Responses".to_owned(),
        ));
    }

    let mut instructions = Vec::new();
    let mut messages = Vec::new();
    let mut loss = LossReport::default();
    for message in request.messages {
        if message.name.is_some() {
            record_dropped(&mut loss, "messages[].name");
        }
        let role = role_from_wire(&message.role)?;
        if matches!(role, Role::System | Role::Developer) {
            for part in chat_content_to_canonical(message.content)? {
                match part {
                    CanonicalContent::Text { text } => instructions.push(text),
                    _ => record_dropped(&mut loss, "system/developer message non-text content"),
                }
            }
            if message.reasoning_content.is_some() {
                record_dropped(&mut loss, "system/developer reasoning_content");
            }
            if !message.tool_calls.is_empty() {
                record_dropped(&mut loss, "system/developer tool_calls");
            }
            continue;
        }

        if role == Role::Tool {
            let id = message.tool_call_id.unwrap_or_default();
            let output = match message.content {
                Some(StringOrParts::String(value)) => JsonData::String(value),
                Some(StringOrParts::Parts(parts)) => JsonData::Array(
                    parts
                        .into_iter()
                        .map(|part| JsonData::String(part.text.unwrap_or_default()))
                        .collect(),
                ),
                None => JsonData::String(String::new()),
            };
            messages.push(CanonicalMessage {
                role,
                parts: vec![CanonicalContent::ToolResult { id, output }],
            });
            continue;
        }

        let mut parts = chat_content_to_canonical(message.content)?;
        if let Some(reasoning) = message.reasoning_content {
            parts.push(CanonicalContent::Reasoning { text: reasoning });
        }
        parts.extend(
            message
                .tool_calls
                .into_iter()
                .map(|call| CanonicalContent::ToolCall {
                    id: call.id,
                    name: call.function.name,
                    arguments: call.function.arguments,
                }),
        );
        messages.push(CanonicalMessage { role, parts });
    }

    let tools = request
        .tools
        .into_iter()
        .map(|tool| CanonicalTool {
            name: tool.function.name,
            description: tool.function.description,
            input_schema: tool.function.parameters.unwrap_or(JsonData::Null),
            strict: tool.function.strict,
        })
        .collect();
    let tool_choice = request
        .tool_choice
        .as_ref()
        .map(parse_tool_choice)
        .transpose()?;

    Ok(Converted {
        value: CanonicalRequest {
            model: request.model,
            instructions,
            messages,
            max_output_tokens: request.max_completion_tokens.or(request.max_tokens),
            temperature: request.temperature,
            stream: request.stream,
            tools,
            tool_choice,
            options: RequestOptions {
                top_p: request.top_p,
                reasoning_effort: request.reasoning_effort,
                response_format: request.response_format,
                parallel_tool_calls: request.parallel_tool_calls,
                user: request.user,
                store: request.store,
                metadata: request.metadata,
                stream_options: request.stream_options,
                top_logprobs: request.top_logprobs,
                safety_identifier: request.safety_identifier,
                prompt_cache_retention: request.prompt_cache_retention,
                prompt_cache_key: request.prompt_cache_key,
                service_tier: request.service_tier,
                enable_thinking: request.enable_thinking,
                thinking_budget: request.thinking_budget,
            },
        },
        loss,
    })
}

pub fn canonical_request_to_openai_chat(
    request: CanonicalRequest,
) -> Result<Converted<OpenAiChatRequest>, RelayConvertError> {
    let options = request.options;
    let mut loss = LossReport::default();
    let mut messages = request
        .instructions
        .into_iter()
        .map(|content| OpenAiChatMessage {
            role: "system".to_owned(),
            content: Some(StringOrParts::String(content)),
            reasoning_content: None,
            name: None,
            tool_call_id: None,
            tool_calls: Vec::new(),
        })
        .collect::<Vec<_>>();

    for message in request.messages {
        if message.role == Role::Model {
            loss.normalized_fields.push("messages[].role model -> user");
        }
        if message.role == Role::Tool {
            for part in &message.parts {
                match part {
                    CanonicalContent::Text { .. } => {
                        record_dropped(&mut loss, "messages[].tool.text")
                    }
                    CanonicalContent::Image { .. } => {
                        record_dropped(&mut loss, "messages[].tool.image")
                    }
                    CanonicalContent::ToolCall { .. } => {
                        record_dropped(&mut loss, "messages[].tool.tool_call")
                    }
                    CanonicalContent::Reasoning { .. } => {
                        record_dropped(&mut loss, "messages[].tool.reasoning")
                    }
                    CanonicalContent::ToolResult { .. } => {}
                }
            }
        }
        let mut text = Vec::new();
        let mut tool_calls = Vec::new();
        let mut reasoning = Vec::new();
        for part in message.parts {
            match part {
                CanonicalContent::Text { text: value } => text.push(OpenAiChatContentPart {
                    kind: "text".to_owned(),
                    text: Some(value),
                    image_url: None,
                }),
                CanonicalContent::Image { url, detail } => text.push(OpenAiChatContentPart {
                    kind: "image_url".to_owned(),
                    text: None,
                    image_url: Some(match detail {
                        Some(detail) => JsonData::Object(
                            [
                                ("url".to_owned(), JsonData::String(url)),
                                ("detail".to_owned(), JsonData::String(detail)),
                            ]
                            .into_iter()
                            .collect(),
                        ),
                        None => JsonData::String(url),
                    }),
                }),
                CanonicalContent::ToolCall {
                    id,
                    name,
                    arguments,
                } => tool_calls.push(OpenAiToolCall {
                    id,
                    kind: "function".to_owned(),
                    function: OpenAiFunction {
                        name,
                        arguments,
                        description: None,
                        parameters: None,
                        strict: None,
                    },
                }),
                CanonicalContent::ToolResult { id, output } => {
                    messages.push(OpenAiChatMessage {
                        role: "tool".to_owned(),
                        content: Some(StringOrParts::String(output.compact_string()?)),
                        reasoning_content: None,
                        name: None,
                        tool_call_id: Some(id),
                        tool_calls: Vec::new(),
                    });
                }
                CanonicalContent::Reasoning { text } => reasoning.push(text),
            }
        }
        if message.role == Role::Tool {
            continue;
        }
        let content = if text.is_empty() {
            None
        } else if text.len() == 1 && text[0].kind == "text" {
            Some(StringOrParts::String(
                text[0].text.clone().unwrap_or_default(),
            ))
        } else {
            Some(StringOrParts::Parts(text))
        };
        messages.push(OpenAiChatMessage {
            role: role_to_chat(message.role).to_owned(),
            content,
            reasoning_content: (!reasoning.is_empty()).then(|| reasoning.join("\n")),
            name: None,
            tool_call_id: None,
            tool_calls,
        });
    }

    let tools = request
        .tools
        .into_iter()
        .map(|tool| OpenAiChatTool {
            kind: "function".to_owned(),
            function: OpenAiFunction {
                name: tool.name,
                arguments: String::new(),
                description: tool.description,
                parameters: Some(tool.input_schema),
                strict: tool.strict,
            },
        })
        .collect();
    Ok(Converted {
        value: OpenAiChatRequest {
            model: request.model,
            messages,
            stream: request.stream,
            max_tokens: None,
            max_completion_tokens: request.max_output_tokens,
            temperature: request.temperature,
            tools,
            tool_choice: request.tool_choice.map(tool_choice_to_chat),
            top_p: options.top_p,
            n: None,
            reasoning_effort: options.reasoning_effort,
            response_format: options.response_format,
            parallel_tool_calls: options.parallel_tool_calls,
            user: options.user,
            store: options.store,
            metadata: options.metadata,
            stream_options: options.stream_options,
            top_logprobs: options.top_logprobs,
            safety_identifier: options.safety_identifier,
            prompt_cache_retention: options.prompt_cache_retention,
            prompt_cache_key: options.prompt_cache_key,
            service_tier: options.service_tier,
            enable_thinking: options.enable_thinking,
            thinking_budget: options.thinking_budget,
        },
        loss,
    })
}

pub fn openai_responses_request_to_canonical(
    request: OpenAiResponsesRequest,
) -> Result<Converted<CanonicalRequest>, RelayConvertError> {
    if request.model.trim().is_empty() {
        return Err(RelayConvertError::Missing("model"));
    }
    if request.conversation.is_some()
        || request.previous_response_id.is_some()
        || request.prompt.is_some()
        || request.context_management.is_some()
    {
        return Err(RelayConvertError::Unsupported(
            "stateful Responses fields (conversation, previous_response_id, prompt, context_management) cannot be converted to Chat".to_owned(),
        ));
    }
    if request.include.is_some()
        || request.moderation.is_some()
        || request.max_tool_calls.is_some()
        || request.client_metadata.is_some()
    {
        return Err(RelayConvertError::Unsupported(
            "Responses include, moderation, max_tool_calls, and client_metadata have no Chat equivalent".to_owned(),
        ));
    }

    let mut messages = Vec::new();
    let input = match request.input {
        None => Vec::new(),
        Some(ResponsesInput::String(text)) => {
            messages.push(CanonicalMessage {
                role: Role::User,
                parts: vec![CanonicalContent::Text { text }],
            });
            Vec::new()
        }
        Some(ResponsesInput::Items(items)) => items,
    };
    for item in input {
        match item.kind.as_deref() {
            Some("function_call" | "custom_tool_call") => messages.push(CanonicalMessage {
                role: Role::Assistant,
                parts: vec![CanonicalContent::ToolCall {
                    id: item.call_id.unwrap_or_default(),
                    name: item
                        .name
                        .ok_or(RelayConvertError::Missing("input[].name"))?,
                    arguments: item.arguments.unwrap_or_default(),
                }],
            }),
            Some("function_call_output" | "custom_tool_call_output") => {
                messages.push(CanonicalMessage {
                    role: Role::Tool,
                    parts: vec![CanonicalContent::ToolResult {
                        id: item.call_id.unwrap_or_default(),
                        output: item.output.unwrap_or(JsonData::String(String::new())),
                    }],
                });
            }
            Some(kind) if kind != "message" => {
                return Err(RelayConvertError::Unsupported(format!(
                    "unsupported Responses input item type {kind:?}"
                )));
            }
            _ => messages.push(CanonicalMessage {
                role: role_from_wire(item.role.as_deref().unwrap_or("user"))?,
                parts: responses_content_to_canonical(item.content)?,
            }),
        }
    }
    let tools = request
        .tools
        .into_iter()
        .map(|tool| CanonicalTool {
            name: tool.name,
            description: tool.description,
            input_schema: tool.parameters.unwrap_or(JsonData::Null),
            strict: tool.strict,
        })
        .collect();
    let tool_choice = request
        .tool_choice
        .as_ref()
        .map(parse_tool_choice)
        .transpose()?;
    let mut loss = LossReport::default();
    let reasoning_effort = request
        .reasoning
        .as_ref()
        .and_then(|value| value.effort.clone());
    if request.reasoning.as_ref().is_some_and(|value| {
        value.summary.is_some() || value.mode.is_some() || value.context.is_some()
    }) {
        loss.dropped_fields.push("reasoning.summary/mode/context");
    }
    let prompt_cache_key = match request.prompt_cache_key {
        Some(JsonData::String(value)) => Some(value),
        Some(_) => {
            return Err(RelayConvertError::Unsupported(
                "prompt_cache_key must be a string when converting Responses to Chat".to_owned(),
            ));
        }
        None => None,
    };

    Ok(Converted {
        value: CanonicalRequest {
            model: request.model,
            instructions: request.instructions.into_iter().collect(),
            messages,
            max_output_tokens: request.max_output_tokens,
            temperature: request.temperature,
            stream: request.stream,
            tools,
            tool_choice,
            options: RequestOptions {
                top_p: request.top_p,
                reasoning_effort,
                response_format: responses_text_to_chat_format(request.text),
                parallel_tool_calls: request.parallel_tool_calls,
                user: request.user,
                store: request.store,
                metadata: request.metadata,
                stream_options: request.stream_options,
                top_logprobs: request.top_logprobs,
                safety_identifier: request.safety_identifier,
                prompt_cache_retention: request.prompt_cache_retention,
                prompt_cache_key,
                service_tier: request.service_tier,
                enable_thinking: request.enable_thinking,
                thinking_budget: request.thinking_budget,
            },
        },
        loss,
    })
}

pub fn canonical_request_to_openai_responses(
    request: CanonicalRequest,
) -> Result<Converted<OpenAiResponsesRequest>, RelayConvertError> {
    let options = request.options;
    let mut loss = LossReport::default();
    if !request.instructions.is_empty() {
        loss.normalized_fields
            .push("messages.system -> instructions");
    }
    let mut input = Vec::new();
    for message in request.messages {
        if message.role == Role::Model {
            loss.normalized_fields
                .push("messages[].role model -> assistant");
        }
        let tool_call_count = message
            .parts
            .iter()
            .filter(|part| matches!(part, CanonicalContent::ToolCall { .. }))
            .count();
        let mut content = Vec::new();
        for part in message.parts {
            match part {
                CanonicalContent::Text { text } => content.push(ResponsesContentPart {
                    kind: if message.role == Role::Assistant {
                        "output_text"
                    } else {
                        "input_text"
                    }
                    .to_owned(),
                    text: Some(text),
                    image_url: None,
                }),
                CanonicalContent::Image { url, detail } => {
                    if detail.is_some() {
                        record_dropped(&mut loss, "messages[].image.detail");
                    }
                    content.push(ResponsesContentPart {
                        kind: "input_image".to_owned(),
                        text: None,
                        image_url: Some(url),
                    });
                }
                CanonicalContent::ToolCall {
                    id,
                    name,
                    arguments,
                } => input.push(ResponsesInputItem {
                    kind: Some("function_call".to_owned()),
                    role: None,
                    content: None,
                    call_id: Some(id),
                    name: Some(name),
                    arguments: Some(arguments),
                    output: None,
                }),
                CanonicalContent::ToolResult { id, output } => {
                    input.push(ResponsesInputItem {
                        kind: Some("function_call_output".to_owned()),
                        role: None,
                        content: None,
                        call_id: Some(id),
                        name: None,
                        arguments: None,
                        output: Some(output),
                    });
                }
                CanonicalContent::Reasoning { .. } => {
                    record_dropped(&mut loss, "messages[].reasoning_content");
                }
            }
        }
        if message.role != Role::Tool || !content.is_empty() {
            input.insert(
                input.len().saturating_sub(tool_call_count),
                ResponsesInputItem {
                    kind: None,
                    role: Some(role_to_responses(message.role).to_owned()),
                    content: Some(
                        if content.is_empty()
                            || (content.len() == 1 && content[0].kind == "input_text")
                        {
                            StringOrParts::String(
                                content
                                    .first()
                                    .and_then(|part| part.text.clone())
                                    .unwrap_or_default(),
                            )
                        } else {
                            StringOrParts::Parts(content)
                        },
                    ),
                    call_id: None,
                    name: None,
                    arguments: None,
                    output: None,
                },
            );
        }
    }
    let tools = request
        .tools
        .into_iter()
        .map(|tool| ResponsesTool {
            kind: "function".to_owned(),
            name: tool.name,
            description: tool.description,
            parameters: Some(tool.input_schema),
            strict: tool.strict,
        })
        .collect();
    Ok(Converted {
        value: OpenAiResponsesRequest {
            model: request.model,
            input: Some(ResponsesInput::Items(input)),
            instructions: (!request.instructions.is_empty())
                .then(|| request.instructions.join("\n\n")),
            max_output_tokens: request.max_output_tokens,
            stream: request.stream,
            temperature: request.temperature,
            tools,
            tool_choice: request.tool_choice.map(tool_choice_to_responses),
            top_p: options.top_p,
            reasoning: options.reasoning_effort.map(|effort| ReasoningConfig {
                effort: Some(effort),
                summary: None,
                mode: None,
                context: None,
            }),
            text: chat_format_to_responses_text(options.response_format),
            parallel_tool_calls: options.parallel_tool_calls,
            user: options.user,
            store: options.store,
            metadata: options.metadata,
            stream_options: options.stream_options,
            top_logprobs: options.top_logprobs,
            safety_identifier: options.safety_identifier,
            prompt_cache_retention: options.prompt_cache_retention,
            prompt_cache_key: options.prompt_cache_key.map(JsonData::String),
            service_tier: options.service_tier,
            enable_thinking: options.enable_thinking,
            thinking_budget: options.thinking_budget,
            conversation: None,
            previous_response_id: None,
            prompt: None,
            context_management: None,
            include: None,
            moderation: None,
            max_tool_calls: None,
            client_metadata: None,
        },
        loss,
    })
}

pub fn openai_chat_response_to_canonical(
    response: OpenAiChatResponse,
) -> Result<Converted<CanonicalResponse>, RelayConvertError> {
    let choice = response
        .choices
        .into_iter()
        .next()
        .ok_or(RelayConvertError::Missing("choices[0]"))?;
    let mut output = chat_content_to_canonical(choice.message.content)?;
    if let Some(reasoning) = choice.message.reasoning_content {
        output.push(CanonicalContent::Reasoning { text: reasoning });
    }
    output.extend(
        choice
            .message
            .tool_calls
            .into_iter()
            .map(|call| CanonicalContent::ToolCall {
                id: call.id,
                name: call.function.name,
                arguments: call.function.arguments,
            }),
    );
    Ok(Converted {
        value: CanonicalResponse {
            id: response.id,
            model: response.model,
            created_at: response.created,
            output,
            finish_reason: choice.finish_reason.as_deref().map(finish_reason),
            usage: response.usage.as_ref().map(wire_usage),
        },
        loss: LossReport::default(),
    })
}

pub fn openai_responses_response_to_canonical(
    response: ResponsesResponse,
) -> Result<Converted<CanonicalResponse>, RelayConvertError> {
    let mut output = Vec::new();
    for item in &response.output {
        match item.kind.as_str() {
            "message" => {
                output.extend(
                    item.content
                        .iter()
                        .flatten()
                        .map(|part| CanonicalContent::Text {
                            text: part.text.clone(),
                        }),
                )
            }
            "reasoning" => output.extend(
                item.summary
                    .iter()
                    .chain(item.content.iter())
                    .flatten()
                    .map(|part| CanonicalContent::Reasoning {
                        text: part.text.clone(),
                    }),
            ),
            "function_call" | "custom_tool_call" => output.push(CanonicalContent::ToolCall {
                id: item.call_id.clone().unwrap_or_else(|| item.id.clone()),
                name: item.name.clone().unwrap_or_default(),
                arguments: item.arguments.clone().unwrap_or_default(),
            }),
            kind => {
                return Err(RelayConvertError::Unsupported(format!(
                    "unsupported Responses output item type {kind:?}"
                )));
            }
        }
    }
    let reason = match response.status.as_str() {
        "incomplete" => match response
            .incomplete_details
            .as_ref()
            .map(|details| details.reason.as_str())
        {
            Some("content_filter") => FinishReason::ContentFilter,
            Some("max_output_tokens") => FinishReason::Length,
            _ => FinishReason::Other,
        },
        "cancelled" => FinishReason::Cancelled,
        "failed" => FinishReason::Error,
        _ if output
            .iter()
            .any(|part| matches!(part, CanonicalContent::ToolCall { .. })) =>
        {
            FinishReason::ToolCalls
        }
        _ => FinishReason::Stop,
    };
    Ok(Converted {
        value: CanonicalResponse {
            id: response.id,
            model: response.model,
            created_at: response.created_at,
            output,
            finish_reason: Some(reason),
            usage: response.usage.as_ref().map(wire_usage),
        },
        loss: LossReport::default(),
    })
}

pub fn canonical_response_to_openai_chat(
    response: CanonicalResponse,
) -> Converted<OpenAiChatResponse> {
    let mut text = String::new();
    let mut reasoning = Vec::new();
    let mut tool_calls = Vec::new();
    let mut loss = LossReport::default();
    for part in response.output {
        match part {
            CanonicalContent::Text { text: part } => text.push_str(&part),
            CanonicalContent::Reasoning { text } => reasoning.push(text),
            CanonicalContent::ToolCall {
                id,
                name,
                arguments,
            } => tool_calls.push(OpenAiToolCall {
                id,
                kind: "function".to_owned(),
                function: OpenAiFunction {
                    name,
                    arguments,
                    description: None,
                    parameters: None,
                    strict: None,
                },
            }),
            CanonicalContent::Image { .. } => {
                record_dropped(&mut loss, "output[].image");
            }
            CanonicalContent::ToolResult { .. } => {
                record_dropped(&mut loss, "output[].tool_result");
            }
        }
    }
    Converted {
        value: OpenAiChatResponse {
            id: response.id,
            model: response.model,
            object: "chat.completion".to_owned(),
            created: response.created_at,
            choices: vec![OpenAiChoice {
                index: 0,
                message: OpenAiChatMessage {
                    role: "assistant".to_owned(),
                    content: Some(StringOrParts::String(text)),
                    reasoning_content: (!reasoning.is_empty()).then(|| reasoning.join("\n")),
                    name: None,
                    tool_call_id: None,
                    tool_calls,
                },
                finish_reason: response.finish_reason.map(finish_reason_to_chat),
            }],
            usage: response.usage.as_ref().map(token_usage_to_wire),
        },
        loss,
    }
}

pub fn canonical_response_to_openai_responses(
    response: CanonicalResponse,
) -> Converted<ResponsesResponse> {
    let finish_reason = response.finish_reason;
    let item_status = if matches!(
        finish_reason,
        Some(FinishReason::Length | FinishReason::ContentFilter)
    ) {
        "incomplete"
    } else {
        "completed"
    };
    let mut output = Vec::new();
    let mut loss = LossReport::default();
    let mut message_index = 0_usize;
    let mut reasoning_index = 0_usize;
    for part in response.output {
        match part {
            CanonicalContent::Text { text } => {
                output.push(ResponsesOutputItem {
                    kind: "message".to_owned(),
                    id: format!("{}_msg_{message_index}", response.id),
                    status: item_status.to_owned(),
                    role: "assistant".to_owned(),
                    content: Some(vec![ResponsesOutputContent {
                        kind: "output_text".to_owned(),
                        text,
                        annotations: Some(Vec::new()),
                    }]),
                    summary: None,
                    quality: String::new(),
                    size: String::new(),
                    call_id: None,
                    name: None,
                    arguments: None,
                });
                message_index += 1;
            }
            CanonicalContent::Reasoning { text } => {
                output.push(ResponsesOutputItem {
                    kind: "reasoning".to_owned(),
                    id: format!("{}_reasoning_{reasoning_index}", response.id),
                    status: item_status.to_owned(),
                    role: String::new(),
                    content: Some(vec![ResponsesOutputContent {
                        kind: "summary_text".to_owned(),
                        text,
                        annotations: None,
                    }]),
                    summary: None,
                    quality: String::new(),
                    size: String::new(),
                    call_id: None,
                    name: None,
                    arguments: None,
                });
                reasoning_index += 1;
            }
            CanonicalContent::ToolCall {
                id,
                name,
                arguments,
            } => output.push(ResponsesOutputItem {
                kind: "function_call".to_owned(),
                id: id.clone(),
                status: item_status.to_owned(),
                role: String::new(),
                content: None,
                summary: None,
                quality: String::new(),
                size: String::new(),
                call_id: Some(id),
                name: Some(name),
                arguments: Some(arguments),
            }),
            CanonicalContent::Image { .. } => {
                record_dropped(&mut loss, "output[].image");
            }
            CanonicalContent::ToolResult { .. } => {
                record_dropped(&mut loss, "output[].tool_result");
            }
        }
    }
    Converted {
        value: ResponsesResponse {
            id: response.id,
            object: "response".to_owned(),
            created_at: response.created_at,
            status: match finish_reason {
                Some(FinishReason::Cancelled) => "cancelled",
                Some(FinishReason::Error) => "failed",
                Some(FinishReason::Length | FinishReason::ContentFilter) => "incomplete",
                _ => "completed",
            }
            .to_owned(),
            instructions: None,
            max_output_tokens: 0,
            model: response.model,
            output,
            parallel_tool_calls: false,
            previous_response_id: None,
            reasoning: None,
            store: false,
            temperature: 0.0,
            tool_choice: None,
            tools: None,
            top_p: 0.0,
            truncation: None,
            usage: response.usage.as_ref().map(token_usage_to_wire),
            user: None,
            metadata: None,
            incomplete_details: match finish_reason {
                Some(FinishReason::Length) => Some(super::IncompleteDetails {
                    reason: "max_output_tokens".to_owned(),
                }),
                Some(FinishReason::ContentFilter) => Some(super::IncompleteDetails {
                    reason: "content_filter".to_owned(),
                }),
                _ => None,
            },
            error: None,
        },
        loss,
    }
}

pub fn openai_chat_response_to_responses(
    response: OpenAiChatResponse,
) -> Result<Converted<ResponsesResponse>, RelayConvertError> {
    let canonical = openai_chat_response_to_canonical(response)?;
    let mut target = canonical_response_to_openai_responses(canonical.value);
    // The legacy Chat -> Responses converter did not propagate Chat's
    // `created` timestamp into the Responses DTO.
    target.value.created_at = 0;
    Ok(Converted {
        value: target.value,
        loss: merge_loss(canonical.loss, target.loss),
    })
}

pub fn openai_responses_response_to_chat(
    response: ResponsesResponse,
) -> Result<Converted<OpenAiChatResponse>, RelayConvertError> {
    let canonical = openai_responses_response_to_canonical(response)?;
    let target = canonical_response_to_openai_chat(canonical.value);
    Ok(Converted {
        value: target.value,
        loss: merge_loss(canonical.loss, target.loss),
    })
}

pub fn openai_stream_to_canonical(snapshot: &OpenAiStreamSnapshot) -> Vec<CanonicalStreamEvent> {
    let mut out = Vec::new();
    let mut started = false;
    let mut response_id = String::new();
    let mut next_output_index = 0_usize;
    let mut text_output_index = None;
    let mut reasoning_output_index = None;
    let mut tool_output_indices = BTreeMap::new();
    let mut closed = BTreeSet::new();
    let mut response_ended = false;
    for chunk in &snapshot.events {
        if !started && (!chunk.id.is_empty() || !chunk.model.is_empty()) {
            response_id.clone_from(&chunk.id);
            out.push(CanonicalStreamEvent::ResponseStart {
                id: chunk.id.clone(),
                model: chunk.model.clone(),
            });
            started = true;
        }
        if let Some(error) = &chunk.error {
            out.push(CanonicalStreamEvent::Error {
                code: error.code.clone(),
                message: error.message.clone(),
            });
        }
        if chunk.cancelled {
            out.push(CanonicalStreamEvent::Cancelled);
        }
        for choice in &chunk.choices {
            if let Some(reasoning) = &choice.delta.reasoning_content
                && !reasoning.is_empty()
            {
                let index = *reasoning_output_index.get_or_insert_with(|| {
                    let index = next_output_index;
                    next_output_index += 1;
                    out.push(CanonicalStreamEvent::ContentStart {
                        index,
                        kind: StreamContentKind::Reasoning,
                    });
                    index
                });
                out.push(CanonicalStreamEvent::ReasoningDelta {
                    index,
                    delta: reasoning.clone(),
                });
            }
            if let Some(content) = &choice.delta.content
                && !content.is_empty()
            {
                let index = *text_output_index.get_or_insert_with(|| {
                    let index = next_output_index;
                    next_output_index += 1;
                    out.push(CanonicalStreamEvent::ContentStart {
                        index,
                        kind: StreamContentKind::Text,
                    });
                    index
                });
                out.push(CanonicalStreamEvent::TextDelta {
                    index,
                    delta: content.clone(),
                });
            }
            for call in &choice.delta.tool_calls {
                let (index, is_new) = match tool_output_indices.get(&call.index) {
                    Some(index) => (*index, false),
                    None => {
                        let index = next_output_index;
                        next_output_index += 1;
                        tool_output_indices.insert(call.index, index);
                        out.push(CanonicalStreamEvent::ContentStart {
                            index,
                            kind: StreamContentKind::ToolCall,
                        });
                        (index, true)
                    }
                };
                if is_new {
                    out.push(CanonicalStreamEvent::ToolCallStart {
                        index,
                        id: call
                            .id
                            .clone()
                            .filter(|id| !id.trim().is_empty())
                            .unwrap_or_else(|| format!("{response_id}_call_{}", call.index)),
                        name: call
                            .function
                            .as_ref()
                            .and_then(|function| function.name.clone())
                            .unwrap_or_default(),
                    });
                }
                if let Some(delta) = call
                    .function
                    .as_ref()
                    .and_then(|function| function.arguments.clone())
                {
                    out.push(CanonicalStreamEvent::ToolArgumentsDelta { index, delta });
                }
            }
            if let Some(reason) = &choice.finish_reason
                && !response_ended
            {
                if let Some(index) = text_output_index.filter(|index| closed.insert(*index)) {
                    out.push(CanonicalStreamEvent::ContentEnd { index });
                }
                if let Some(index) = reasoning_output_index.filter(|index| closed.insert(*index)) {
                    out.push(CanonicalStreamEvent::ContentEnd { index });
                }
                for index in tool_output_indices.values().copied() {
                    if closed.insert(index) {
                        out.push(CanonicalStreamEvent::ContentEnd { index });
                    }
                }
                out.push(CanonicalStreamEvent::ResponseEnd {
                    finish_reason: finish_reason(reason),
                    usage: chunk
                        .usage
                        .as_ref()
                        .map(wire_usage)
                        .or_else(|| Some(wire_usage(&snapshot.usage))),
                    model: (!chunk.model.is_empty()).then(|| chunk.model.clone()),
                });
                response_ended = true;
            }
        }
        if chunk.choices.is_empty() && chunk.usage.is_some() {
            // OpenAI's `stream_options.include_usage` emits a trailing usage-only
            // chunk. The usage is already attached to the preceding ResponseEnd.
        }
    }
    out
}

pub fn responses_stream_to_canonical(
    snapshot: &ResponsesStreamSnapshot,
) -> Vec<CanonicalStreamEvent> {
    let mut out = Vec::new();
    let mut ended = BTreeSet::new();
    let mut saw_tool_call = false;
    for event in &snapshot.events {
        let payload = &event.payload;
        match payload.kind.as_str() {
            "response.created" => {
                if let Some(response) = &payload.response {
                    out.push(CanonicalStreamEvent::ResponseStart {
                        id: response.id.clone(),
                        model: response.model.clone(),
                    });
                }
            }
            "response.output_item.added" => {
                if let Some(item) = &payload.item {
                    let index = payload.output_index.unwrap_or_default();
                    let kind = match item.kind.as_str() {
                        "function_call" | "custom_tool_call" => StreamContentKind::ToolCall,
                        "reasoning" => StreamContentKind::Reasoning,
                        _ => StreamContentKind::Text,
                    };
                    out.push(CanonicalStreamEvent::ContentStart { index, kind });
                    if matches!(item.kind.as_str(), "function_call" | "custom_tool_call") {
                        saw_tool_call = true;
                        out.push(CanonicalStreamEvent::ToolCallStart {
                            index,
                            id: item.call_id.clone().unwrap_or_else(|| item.id.clone()),
                            name: item.name.clone().unwrap_or_default(),
                        });
                    }
                }
            }
            "response.output_text.delta" => out.push(CanonicalStreamEvent::TextDelta {
                index: payload.output_index.unwrap_or_default(),
                delta: payload.delta.clone().unwrap_or_default(),
            }),
            "response.function_call_arguments.delta" => {
                out.push(CanonicalStreamEvent::ToolArgumentsDelta {
                    index: payload.output_index.unwrap_or_default(),
                    delta: payload.delta.clone().unwrap_or_default(),
                });
            }
            "response.custom_tool_call_input.delta" => {
                out.push(CanonicalStreamEvent::ToolArgumentsDelta {
                    index: payload.output_index.unwrap_or_default(),
                    delta: payload.delta.clone().unwrap_or_default(),
                });
            }
            "response.reasoning_summary_text.delta" | "response.reasoning_text.delta" => {
                out.push(CanonicalStreamEvent::ReasoningDelta {
                    index: payload.output_index.unwrap_or_default(),
                    delta: payload.delta.clone().unwrap_or_default(),
                });
            }
            "response.output_text.done"
            | "response.reasoning_summary_text.done"
            | "response.reasoning_text.done"
            | "response.function_call_arguments.done"
            | "response.custom_tool_call_input.done"
            | "response.output_item.done" => {
                let index = payload.output_index.unwrap_or_default();
                if ended.insert(index) {
                    out.push(CanonicalStreamEvent::ContentEnd { index });
                }
            }
            "response.completed" | "response.done" | "response.incomplete" => {
                let response = payload.response.as_ref();
                let finish_reason = if payload.kind == "response.incomplete" {
                    incomplete_finish_reason(response)
                } else if saw_tool_call
                    || response.is_some_and(|value| {
                        value.output.iter().any(|item| {
                            matches!(item.kind.as_str(), "function_call" | "custom_tool_call")
                        })
                    })
                {
                    FinishReason::ToolCalls
                } else {
                    FinishReason::Stop
                };
                out.push(CanonicalStreamEvent::ResponseEnd {
                    finish_reason,
                    usage: payload
                        .response
                        .as_ref()
                        .and_then(|response| response.usage.as_ref())
                        .map(wire_usage)
                        .or_else(|| Some(wire_usage(&snapshot.usage))),
                    model: response
                        .filter(|response| !response.model.is_empty())
                        .map(|response| response.model.clone()),
                });
            }
            "response.failed" | "response.error" => {
                let error = payload.error.as_ref().or_else(|| {
                    payload
                        .response
                        .as_ref()
                        .and_then(|response| response.error.as_ref())
                });
                out.push(CanonicalStreamEvent::Error {
                    code: error.and_then(|value| value.code.clone()),
                    message: error.map_or_else(
                        || "response failed".to_owned(),
                        |value| value.message.clone(),
                    ),
                });
            }
            "response.cancelled" => out.push(CanonicalStreamEvent::Cancelled),
            _ => {}
        }
    }
    out
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GoldenValidation {
    pub kind: FixtureKind,
    pub target: Protocol,
    pub event_count: usize,
    pub usage: Option<TokenUsage>,
}

pub fn validate_golden(
    kind: FixtureKind,
    target: Protocol,
    json: &str,
) -> Result<GoldenValidation, RelayConvertError> {
    let (event_count, usage) = match (kind, target) {
        (FixtureKind::Request, Protocol::OpenAi) => {
            serde_json::from_str::<OpenAiChatRequest>(json)?;
            (0, None)
        }
        (FixtureKind::Request, Protocol::OpenAiResponses) => {
            serde_json::from_str::<OpenAiResponsesRequest>(json)?;
            (0, None)
        }
        (FixtureKind::Request, Protocol::Claude) => {
            serde_json::from_str::<ClaudeRequest>(json)?;
            (0, None)
        }
        (FixtureKind::Request, Protocol::Gemini) => {
            serde_json::from_str::<GeminiRequest>(json)?;
            (0, None)
        }
        (FixtureKind::Response, Protocol::OpenAi) => {
            let value = serde_json::from_str::<OpenAiChatResponse>(json)?;
            (0, value.usage.as_ref().map(wire_usage))
        }
        (FixtureKind::Response, Protocol::OpenAiResponses) => {
            let value = serde_json::from_str::<ResponsesResponse>(json)?;
            (0, value.usage.as_ref().map(wire_usage))
        }
        (FixtureKind::Response, Protocol::Claude) => {
            let value = serde_json::from_str::<ClaudeResponse>(json)?;
            (0, value.usage.as_ref().map(claude_usage))
        }
        (FixtureKind::Response, Protocol::Gemini) => {
            let value = serde_json::from_str::<GeminiResponse>(json)?;
            (0, value.usage_metadata.as_ref().map(gemini_usage))
        }
        (FixtureKind::Stream, Protocol::OpenAi) => {
            let value = serde_json::from_str::<OpenAiStreamSnapshot>(json)?;
            (value.events.len(), Some(wire_usage(&value.usage)))
        }
        (FixtureKind::Stream, Protocol::OpenAiResponses) => {
            let value = serde_json::from_str::<ResponsesStreamSnapshot>(json)?;
            (value.events.len(), Some(wire_usage(&value.usage)))
        }
        (FixtureKind::Stream, Protocol::Claude) => {
            let value = serde_json::from_str::<ClaudeStreamSnapshot>(json)?;
            (value.events.len(), Some(wire_usage(&value.usage)))
        }
        (FixtureKind::Stream, Protocol::Gemini) => {
            let value = serde_json::from_str::<GeminiStreamSnapshot>(json)?;
            (value.events.len(), Some(wire_usage(&value.usage)))
        }
    };
    Ok(GoldenValidation {
        kind,
        target,
        event_count,
        usage,
    })
}

fn record_dropped(loss: &mut LossReport, field: &'static str) {
    if !loss.dropped_fields.contains(&field) {
        loss.dropped_fields.push(field);
    }
}

fn merge_loss(mut left: LossReport, right: LossReport) -> LossReport {
    for field in right.dropped_fields {
        record_dropped(&mut left, field);
    }
    for field in right.normalized_fields {
        if !left.normalized_fields.contains(&field) {
            left.normalized_fields.push(field);
        }
    }
    left
}

fn chat_content_to_canonical(
    content: Option<StringOrParts<OpenAiChatContentPart>>,
) -> Result<Vec<CanonicalContent>, RelayConvertError> {
    match content {
        Some(StringOrParts::String(text)) => Ok(vec![CanonicalContent::Text { text }]),
        Some(StringOrParts::Parts(parts)) => parts
            .into_iter()
            .map(|part| match part.kind.as_str() {
                "text" => Ok(CanonicalContent::Text {
                    text: part.text.unwrap_or_default(),
                }),
                "image_url" => {
                    let image = part
                        .image_url
                        .ok_or(RelayConvertError::Missing("image_url"))?;
                    let (url, detail) = match image {
                        JsonData::String(url) => (url, None),
                        JsonData::Object(mut object) => {
                            let url = match object.remove("url") {
                                Some(JsonData::String(url)) => url,
                                _ => return Err(RelayConvertError::Missing("image_url.url")),
                            };
                            let detail = match object.remove("detail") {
                                Some(JsonData::String(detail)) => Some(detail),
                                Some(_) => {
                                    return Err(RelayConvertError::Unsupported(
                                        "image_url.detail must be a string".to_owned(),
                                    ));
                                }
                                None => None,
                            };
                            (url, detail)
                        }
                        _ => return Err(RelayConvertError::Missing("image_url.url")),
                    };
                    Ok(CanonicalContent::Image { url, detail })
                }
                kind => Err(RelayConvertError::Unsupported(format!(
                    "unsupported Chat content part type {kind:?}"
                ))),
            })
            .collect(),
        None => Ok(Vec::new()),
    }
}

fn responses_content_to_canonical(
    content: Option<StringOrParts<ResponsesContentPart>>,
) -> Result<Vec<CanonicalContent>, RelayConvertError> {
    match content {
        Some(StringOrParts::String(text)) => Ok(vec![CanonicalContent::Text { text }]),
        Some(StringOrParts::Parts(parts)) => parts
            .into_iter()
            .map(|part| match part.kind.as_str() {
                "input_text" | "output_text" | "text" => Ok(CanonicalContent::Text {
                    text: part.text.unwrap_or_default(),
                }),
                "input_image" => Ok(CanonicalContent::Image {
                    url: part
                        .image_url
                        .ok_or(RelayConvertError::Missing("image_url"))?,
                    detail: None,
                }),
                kind => Err(RelayConvertError::Unsupported(format!(
                    "unsupported Responses content part type {kind:?}"
                ))),
            })
            .collect(),
        None => Ok(Vec::new()),
    }
}

fn role_from_wire(role: &str) -> Result<Role, RelayConvertError> {
    match role {
        "system" => Ok(Role::System),
        "developer" => Ok(Role::Developer),
        "user" => Ok(Role::User),
        "assistant" => Ok(Role::Assistant),
        "tool" | "function" => Ok(Role::Tool),
        "model" => Ok(Role::Model),
        value => Err(RelayConvertError::Unsupported(format!(
            "unsupported message role {value:?}"
        ))),
    }
}

fn role_to_chat(role: Role) -> &'static str {
    match role {
        Role::System => "system",
        Role::Developer => "developer",
        Role::User | Role::Model => "user",
        Role::Assistant => "assistant",
        Role::Tool => "tool",
    }
}

fn role_to_responses(role: Role) -> &'static str {
    match role {
        Role::Model => "assistant",
        other => role_to_chat(other),
    }
}

fn parse_tool_choice(value: &JsonData) -> Result<CanonicalToolChoice, RelayConvertError> {
    match value {
        JsonData::String(choice) => match choice.as_str() {
            "auto" => Ok(CanonicalToolChoice::Auto),
            "none" => Ok(CanonicalToolChoice::None),
            "required" | "any" => Ok(CanonicalToolChoice::Required),
            other => Err(RelayConvertError::Unsupported(format!(
                "unsupported tool choice {other:?}"
            ))),
        },
        JsonData::Object(object) => {
            let name = object.get("name").or_else(|| {
                object.get("function").and_then(|function| match function {
                    JsonData::Object(function) => function.get("name"),
                    _ => None,
                })
            });
            match name {
                Some(JsonData::String(name)) => {
                    Ok(CanonicalToolChoice::Function { name: name.clone() })
                }
                _ => Err(RelayConvertError::Missing("tool_choice.name")),
            }
        }
        _ => Err(RelayConvertError::Unsupported(
            "tool_choice must be a string or object".to_owned(),
        )),
    }
}

fn tool_choice_to_chat(choice: CanonicalToolChoice) -> JsonData {
    match choice {
        CanonicalToolChoice::Auto => JsonData::String("auto".to_owned()),
        CanonicalToolChoice::None => JsonData::String("none".to_owned()),
        CanonicalToolChoice::Required => JsonData::String("required".to_owned()),
        CanonicalToolChoice::Function { name } => JsonData::Object(
            [
                ("type".to_owned(), JsonData::String("function".to_owned())),
                (
                    "function".to_owned(),
                    JsonData::Object(
                        [("name".to_owned(), JsonData::String(name))]
                            .into_iter()
                            .collect(),
                    ),
                ),
            ]
            .into_iter()
            .collect(),
        ),
    }
}

fn tool_choice_to_responses(choice: CanonicalToolChoice) -> JsonData {
    match choice {
        CanonicalToolChoice::Function { name } => JsonData::Object(
            [
                ("type".to_owned(), JsonData::String("function".to_owned())),
                ("name".to_owned(), JsonData::String(name)),
            ]
            .into_iter()
            .collect(),
        ),
        other => tool_choice_to_chat(other),
    }
}

fn chat_format_to_responses_text(format: Option<JsonData>) -> Option<JsonData> {
    format.map(|value| {
        JsonData::Object(
            [("format".to_owned(), value)]
                .into_iter()
                .collect::<BTreeMap<_, _>>(),
        )
    })
}

fn responses_text_to_chat_format(text: Option<JsonData>) -> Option<JsonData> {
    match text {
        Some(JsonData::Object(mut object)) => object.remove("format"),
        _ => None,
    }
}

fn finish_reason(reason: &str) -> FinishReason {
    match reason {
        "stop" | "end_turn" | "completed" => FinishReason::Stop,
        "length" | "max_tokens" => FinishReason::Length,
        "tool_calls" | "tool_use" => FinishReason::ToolCalls,
        "content_filter" | "safety" => FinishReason::ContentFilter,
        "cancelled" => FinishReason::Cancelled,
        "error" | "failed" => FinishReason::Error,
        _ => FinishReason::Other,
    }
}

fn finish_reason_to_chat(reason: FinishReason) -> String {
    match reason {
        FinishReason::Stop => "stop",
        FinishReason::Length => "length",
        FinishReason::ToolCalls => "tool_calls",
        FinishReason::ContentFilter => "content_filter",
        FinishReason::Cancelled => "cancelled",
        FinishReason::Error => "error",
        FinishReason::Other => "stop",
    }
    .to_owned()
}

fn incomplete_finish_reason(response: Option<&ResponsesResponse>) -> FinishReason {
    match response
        .and_then(|value| value.incomplete_details.as_ref())
        .map(|details| details.reason.as_str())
    {
        Some("max_output_tokens") => FinishReason::Length,
        Some("content_filter") => FinishReason::ContentFilter,
        _ => FinishReason::Other,
    }
}

fn wire_usage(usage: &WireUsage) -> TokenUsage {
    let input = usage.input_tokens.max(usage.prompt_tokens);
    let output = usage.output_tokens.max(usage.completion_tokens);
    TokenUsage {
        input_tokens: input,
        output_tokens: output,
        total_tokens: usage.total_tokens.max(input + output),
        cached_input_tokens: usage
            .input_tokens_details
            .as_ref()
            .or(usage.prompt_tokens_details.as_ref())
            .map_or(0, |details| details.cached_tokens),
        reasoning_tokens: usage
            .completion_tokens_details
            .as_ref()
            .map_or(0, |details| details.reasoning_tokens),
    }
}

fn claude_usage(usage: &super::ClaudeUsage) -> TokenUsage {
    TokenUsage {
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens,
        total_tokens: usage.input_tokens + usage.output_tokens,
        cached_input_tokens: usage.cache_read_input_tokens,
        reasoning_tokens: 0,
    }
}

fn gemini_usage(usage: &super::GeminiUsage) -> TokenUsage {
    TokenUsage {
        input_tokens: usage.prompt_token_count,
        output_tokens: usage.candidates_token_count,
        total_tokens: usage.total_token_count,
        cached_input_tokens: usage.cached_content_token_count,
        reasoning_tokens: usage.thoughts_token_count,
    }
}

fn token_usage_to_wire(usage: &TokenUsage) -> WireUsage {
    WireUsage {
        prompt_tokens: usage.input_tokens,
        completion_tokens: usage.output_tokens,
        total_tokens: usage.total_tokens,
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens,
        prompt_tokens_details: Some(TokenDetails {
            cached_tokens: usage.cached_input_tokens,
            ..TokenDetails::default()
        }),
        completion_tokens_details: Some(TokenDetails {
            reasoning_tokens: usage.reasoning_tokens,
            ..TokenDetails::default()
        }),
        input_tokens_details: Some(TokenDetails {
            cached_tokens: usage.cached_input_tokens,
            ..TokenDetails::default()
        }),
        ..WireUsage::default()
    }
}

pub fn response_events_to_openai_chunks(events: &[CanonicalStreamEvent]) -> Vec<OpenAiStreamChunk> {
    let mut id = String::new();
    let mut model = String::new();
    let mut out = Vec::new();
    for event in events {
        let (delta, finish_reason, usage, error, cancelled) = match event {
            CanonicalStreamEvent::ResponseStart {
                id: event_id,
                model: event_model,
            } => {
                id.clone_from(event_id);
                model.clone_from(event_model);
                (
                    OpenAiStreamDelta {
                        role: Some("assistant".to_owned()),
                        content: Some(String::new()),
                        reasoning_content: None,
                        tool_calls: Vec::new(),
                    },
                    None,
                    None,
                    None,
                    false,
                )
            }
            CanonicalStreamEvent::ContentStart { .. } => continue,
            CanonicalStreamEvent::TextDelta { delta, .. } => (
                OpenAiStreamDelta {
                    content: Some(delta.clone()),
                    ..OpenAiStreamDelta::default()
                },
                None,
                None,
                None,
                false,
            ),
            CanonicalStreamEvent::ReasoningDelta { delta, .. } => (
                OpenAiStreamDelta {
                    reasoning_content: Some(delta.clone()),
                    ..OpenAiStreamDelta::default()
                },
                None,
                None,
                None,
                false,
            ),
            CanonicalStreamEvent::ToolCallStart { index, id, name } => (
                OpenAiStreamDelta {
                    tool_calls: vec![super::OpenAiStreamToolCall {
                        index: *index,
                        id: Some(id.clone()),
                        kind: Some("function".to_owned()),
                        function: Some(super::OpenAiStreamFunction {
                            name: Some(name.clone()),
                            arguments: Some(String::new()),
                        }),
                    }],
                    ..OpenAiStreamDelta::default()
                },
                None,
                None,
                None,
                false,
            ),
            CanonicalStreamEvent::ToolArgumentsDelta { index, delta } => (
                OpenAiStreamDelta {
                    tool_calls: vec![super::OpenAiStreamToolCall {
                        index: *index,
                        id: None,
                        kind: None,
                        function: Some(super::OpenAiStreamFunction {
                            name: None,
                            arguments: Some(delta.clone()),
                        }),
                    }],
                    ..OpenAiStreamDelta::default()
                },
                None,
                None,
                None,
                false,
            ),
            CanonicalStreamEvent::ResponseEnd {
                finish_reason,
                usage,
                model: final_model,
            } => (
                {
                    if let Some(final_model) = final_model {
                        model.clone_from(final_model);
                    }
                    OpenAiStreamDelta::default()
                },
                Some(finish_reason_to_chat(*finish_reason)),
                usage.as_ref().map(token_usage_to_wire),
                None,
                false,
            ),
            CanonicalStreamEvent::Error { code, message } => (
                OpenAiStreamDelta::default(),
                None,
                None,
                Some(WireError {
                    code: code.clone(),
                    message: message.clone(),
                }),
                false,
            ),
            CanonicalStreamEvent::Cancelled => {
                (OpenAiStreamDelta::default(), None, None, None, true)
            }
            CanonicalStreamEvent::ContentEnd { .. } => continue,
        };
        let choices = if error.is_some() || cancelled {
            Vec::new()
        } else {
            vec![super::OpenAiStreamChoice {
                delta,
                logprobs: None,
                finish_reason,
                index: 0,
            }]
        };
        out.push(OpenAiStreamChunk {
            id: id.clone(),
            object: "chat.completion.chunk".to_owned(),
            created: 0,
            model: model.clone(),
            system_fingerprint: None,
            choices,
            usage,
            error,
            cancelled,
        });
    }
    out
}

pub fn response_events_to_responses(events: &[CanonicalStreamEvent]) -> Vec<ResponsesStreamEvent> {
    let mut id = String::new();
    let mut model = String::new();
    let mut out = Vec::new();
    let mut items = BTreeMap::<usize, ResponsesOutputItem>::new();
    let mut open_items = BTreeSet::new();
    for event in events {
        let mut payloads = Vec::new();
        match event {
            CanonicalStreamEvent::ResponseStart {
                id: event_id,
                model: event_model,
            } => {
                id.clone_from(event_id);
                model.clone_from(event_model);
                let response = empty_responses_stream_response(&id, &model, "in_progress", None);
                let mut payload = responses_payload("response.created");
                payload.response = Some(response);
                payloads.push(payload);
            }
            CanonicalStreamEvent::ContentStart { index, kind } => {
                ensure_responses_item(
                    &mut payloads,
                    &mut items,
                    &mut open_items,
                    &id,
                    *index,
                    *kind,
                );
            }
            CanonicalStreamEvent::TextDelta { index, delta } => {
                ensure_responses_item(
                    &mut payloads,
                    &mut items,
                    &mut open_items,
                    &id,
                    *index,
                    StreamContentKind::Text,
                );
                let mut payload = responses_payload("response.output_text.delta");
                payload.delta = Some(delta.clone());
                payload.output_index = Some(*index);
                payload.content_index = Some(0);
                payload.item_id = Some(format!("{id}_msg_{index}"));
                payloads.push(payload);
                if let Some(item) = items.get_mut(index) {
                    let content = item.content.get_or_insert_default();
                    if let Some(part) = content.first_mut() {
                        part.text.push_str(delta);
                    } else {
                        content.push(ResponsesOutputContent {
                            kind: "output_text".to_owned(),
                            text: delta.clone(),
                            annotations: Some(Vec::new()),
                        });
                    }
                }
            }
            CanonicalStreamEvent::ReasoningDelta { index, delta } => {
                ensure_responses_item(
                    &mut payloads,
                    &mut items,
                    &mut open_items,
                    &id,
                    *index,
                    StreamContentKind::Reasoning,
                );
                let mut payload = responses_payload("response.reasoning_summary_text.delta");
                payload.delta = Some(delta.clone());
                payload.output_index = Some(*index);
                payload.summary_index = Some(0);
                payload.item_id = Some(format!("{id}_reasoning_{index}"));
                payloads.push(payload);
                if let Some(item) = items.get_mut(index) {
                    let summary = item.summary.get_or_insert_default();
                    if let Some(part) = summary.first_mut() {
                        part.text.push_str(delta);
                    } else {
                        summary.push(ResponsesOutputContent {
                            kind: "summary_text".to_owned(),
                            text: delta.clone(),
                            annotations: None,
                        });
                    }
                }
            }
            CanonicalStreamEvent::ToolCallStart {
                index,
                id: call_id,
                name,
            } => {
                let item = ResponsesOutputItem {
                    kind: "function_call".to_owned(),
                    id: format!("{id}_tool_{index}"),
                    status: "in_progress".to_owned(),
                    role: String::new(),
                    content: None,
                    summary: None,
                    quality: String::new(),
                    size: String::new(),
                    call_id: Some(call_id.clone()),
                    name: Some(name.clone()),
                    arguments: Some(String::new()),
                };
                items.insert(*index, item.clone());
                open_items.insert(*index);
                let mut payload = responses_payload("response.output_item.added");
                payload.output_index = Some(*index);
                payload.item = Some(item);
                payloads.push(payload);
            }
            CanonicalStreamEvent::ToolArgumentsDelta { index, delta } => {
                let mut payload = responses_payload("response.function_call_arguments.delta");
                payload.delta = Some(delta.clone());
                payload.output_index = Some(*index);
                payload.item_id = Some(
                    items
                        .get(index)
                        .map_or_else(|| format!("{id}_tool_{index}"), |item| item.id.clone()),
                );
                payloads.push(payload);
                if let Some(item) = items.get_mut(index) {
                    item.arguments.get_or_insert_default().push_str(delta);
                }
            }
            CanonicalStreamEvent::ContentEnd { index } => {
                finish_responses_item(&mut payloads, &mut items, &mut open_items, *index);
            }
            CanonicalStreamEvent::ResponseEnd {
                finish_reason,
                usage,
                model: _,
            } => {
                for index in open_items.clone() {
                    finish_responses_item(&mut payloads, &mut items, &mut open_items, index);
                }
                let (event_kind, status, incomplete_details) = match finish_reason {
                    FinishReason::Length => (
                        "response.incomplete",
                        "incomplete",
                        Some(super::IncompleteDetails {
                            reason: "max_output_tokens".to_owned(),
                        }),
                    ),
                    FinishReason::ContentFilter => (
                        "response.incomplete",
                        "incomplete",
                        Some(super::IncompleteDetails {
                            reason: "content_filter".to_owned(),
                        }),
                    ),
                    FinishReason::Cancelled => ("response.cancelled", "cancelled", None),
                    FinishReason::Error => ("response.failed", "failed", None),
                    _ => ("response.completed", "completed", None),
                };
                let mut response = empty_responses_stream_response(
                    &id,
                    &model,
                    status,
                    usage.as_ref().map(token_usage_to_wire),
                );
                response.output = items.values().cloned().collect();
                response.incomplete_details = incomplete_details;
                let mut payload = responses_payload(event_kind);
                payload.response = Some(response);
                payloads.push(payload);
            }
            CanonicalStreamEvent::Error { code, message } => {
                let mut payload = responses_payload("response.error");
                payload.error = Some(WireError {
                    code: code.clone(),
                    message: message.clone(),
                });
                payloads.push(payload);
            }
            CanonicalStreamEvent::Cancelled => {
                payloads.push(responses_payload("response.cancelled"));
            }
        }
        out.extend(payloads.into_iter().map(|payload| ResponsesStreamEvent {
            kind: payload.kind.clone(),
            payload,
        }));
    }
    out
}

fn responses_payload(kind: &str) -> super::ResponsesEventPayload {
    super::ResponsesEventPayload {
        kind: kind.to_owned(),
        response: None,
        item: None,
        delta: None,
        text: None,
        arguments: None,
        output_index: None,
        content_index: None,
        item_id: None,
        summary_index: None,
        part: None,
        error: None,
    }
}

fn ensure_responses_item(
    payloads: &mut Vec<super::ResponsesEventPayload>,
    items: &mut BTreeMap<usize, ResponsesOutputItem>,
    open_items: &mut BTreeSet<usize>,
    response_id: &str,
    index: usize,
    kind: StreamContentKind,
) {
    if items.contains_key(&index) {
        return;
    }
    let item = match kind {
        StreamContentKind::Text => ResponsesOutputItem {
            kind: "message".to_owned(),
            id: format!("{response_id}_msg_{index}"),
            status: "in_progress".to_owned(),
            role: "assistant".to_owned(),
            content: Some(Vec::new()),
            summary: None,
            quality: String::new(),
            size: String::new(),
            call_id: None,
            name: None,
            arguments: None,
        },
        StreamContentKind::Reasoning => ResponsesOutputItem {
            kind: "reasoning".to_owned(),
            id: format!("{response_id}_reasoning_{index}"),
            status: "in_progress".to_owned(),
            role: String::new(),
            content: None,
            summary: Some(Vec::new()),
            quality: String::new(),
            size: String::new(),
            call_id: None,
            name: None,
            arguments: None,
        },
        StreamContentKind::ToolCall => return,
    };
    items.insert(index, item.clone());
    open_items.insert(index);
    let mut payload = responses_payload("response.output_item.added");
    payload.output_index = Some(index);
    payload.item = Some(item);
    payloads.push(payload);
}

fn finish_responses_item(
    payloads: &mut Vec<super::ResponsesEventPayload>,
    items: &mut BTreeMap<usize, ResponsesOutputItem>,
    open_items: &mut BTreeSet<usize>,
    index: usize,
) {
    if !open_items.remove(&index) {
        return;
    }
    let Some(item) = items.get_mut(&index) else {
        return;
    };
    if item.kind == "function_call" {
        let mut arguments_done = responses_payload("response.function_call_arguments.done");
        arguments_done.output_index = Some(index);
        arguments_done.item_id = Some(item.id.clone());
        payloads.push(arguments_done);
    } else if item.kind == "reasoning" {
        let mut reasoning_done = responses_payload("response.reasoning_summary_text.done");
        reasoning_done.output_index = Some(index);
        reasoning_done.item_id = Some(item.id.clone());
        reasoning_done.summary_index = Some(0);
        reasoning_done.part = item
            .summary
            .as_ref()
            .and_then(|summary| summary.first())
            .cloned();
        payloads.push(reasoning_done);
    } else if item.kind == "message" {
        let mut text_done = responses_payload("response.output_text.done");
        text_done.output_index = Some(index);
        text_done.item_id = Some(item.id.clone());
        text_done.content_index = Some(0);
        payloads.push(text_done);
    }
    item.status = "completed".to_owned();
    let mut done = responses_payload("response.output_item.done");
    done.output_index = Some(index);
    done.item = Some(item.clone());
    payloads.push(done);
}

fn empty_responses_stream_response(
    id: &str,
    model: &str,
    status: &str,
    usage: Option<WireUsage>,
) -> ResponsesResponse {
    ResponsesResponse {
        id: id.to_owned(),
        object: "response".to_owned(),
        created_at: 0,
        status: status.to_owned(),
        instructions: None,
        max_output_tokens: 0,
        model: model.to_owned(),
        output: Vec::new(),
        parallel_tool_calls: false,
        previous_response_id: None,
        reasoning: None,
        store: false,
        temperature: 0.0,
        tool_choice: None,
        tools: None,
        top_p: 0.0,
        truncation: None,
        usage,
        user: None,
        metadata: None,
        incomplete_details: None,
        error: None,
    }
}
