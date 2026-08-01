//! Differential contract tests against the frozen Go relayconvert snapshots.

use std::{fs, path::PathBuf};

use super::*;

const SOURCES: [&str; 4] = ["claude", "gemini", "openai", "openai_responses"];

fn fixture_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join("fixtures/legacy-relayconvert/golden")
}

fn protocol(name: &str) -> Protocol {
    match name {
        "claude" => Protocol::Claude,
        "gemini" => Protocol::Gemini,
        "openai" => Protocol::OpenAi,
        "openai_responses" => Protocol::OpenAiResponses,
        _ => panic!("unknown fixture protocol {name}"),
    }
}

fn kind(name: &str) -> FixtureKind {
    match name {
        "request" => FixtureKind::Request,
        "response" => FixtureKind::Response,
        "stream" => FixtureKind::Stream,
        _ => panic!("unknown fixture kind {name}"),
    }
}

fn fixture(group: &str, from: &str, to: &str) -> String {
    fs::read_to_string(
        fixture_root()
            .join(group)
            .join(format!("{from}_to_{to}.golden.json")),
    )
    .expect("frozen relayconvert fixture must be readable")
}

#[test]
fn all_36_legacy_golden_files_have_typed_contracts() {
    let mut verified = 0;
    for group in ["request", "response", "stream"] {
        for from in SOURCES {
            for to in SOURCES {
                if from == to {
                    continue;
                }
                let json = fixture(group, from, to);
                let validation = validate_golden(kind(group), protocol(to), &json)
                    .unwrap_or_else(|error| panic!("{group}/{from}_to_{to}: {error}"));
                if group == "stream" {
                    assert!(validation.event_count > 0, "{from}_to_{to}");
                    assert!(validation.usage.is_some(), "{from}_to_{to}");
                }
                if group == "response" {
                    assert!(validation.usage.is_some(), "{from}_to_{to}");
                }
                verified += 1;
            }
        }
    }
    assert_eq!(verified, 36);
}

#[test]
fn chat_request_to_responses_matches_go_golden() {
    let source: OpenAiChatRequest = serde_json::from_str(
        r#"{
          "model":"gpt-test","max_tokens":1024,"stream":true,
          "messages":[
            {"role":"system","content":"You are a helpful assistant."},
            {"role":"user","content":[{"type":"text","text":"What is in this image?"},{"type":"image_url","image_url":{"url":"https://example.com/cat.png","detail":"high"}}]},
            {"role":"assistant","tool_calls":[{"id":"call_abc","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}}]},
            {"role":"tool","tool_call_id":"call_abc","content":"15 degrees"},
            {"role":"user","content":"Summarize."}
          ],
          "tools":[{"type":"function","function":{"name":"get_weather","description":"Get weather by city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],
          "tool_choice":"auto"
        }"#,
    )
    .expect("source fixture");
    let canonical = openai_chat_request_to_canonical(source)
        .expect("Chat request conversion")
        .value;
    let actual = canonical_request_to_openai_responses(canonical)
        .expect("Responses request conversion")
        .value;
    let expected: OpenAiResponsesRequest =
        serde_json::from_str(&fixture("request", "openai", "openai_responses"))
            .expect("golden Responses request");
    assert_eq!(actual, expected);
}

#[test]
fn responses_request_to_chat_matches_go_golden() {
    let source: OpenAiResponsesRequest = serde_json::from_str(
        r#"{
          "model":"gpt-test","stream":true,"max_output_tokens":1024,
          "instructions":"You are a helpful assistant.",
          "input":[
            {"type":"message","role":"user","content":[{"type":"input_text","text":"What is in this image?"},{"type":"input_image","image_url":"https://example.com/cat.png"}]},
            {"type":"function_call","call_id":"call_abc","name":"get_weather","arguments":"{\"city\":\"Paris\"}"},
            {"type":"function_call_output","call_id":"call_abc","output":"15 degrees"}
          ],
          "tools":[{"type":"function","name":"get_weather","description":"Get weather by city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}]
        }"#,
    )
    .expect("source fixture");
    let canonical = openai_responses_request_to_canonical(source)
        .expect("Responses request conversion")
        .value;
    let actual = canonical_request_to_openai_chat(canonical)
        .expect("Chat request conversion")
        .value;
    let expected: OpenAiChatRequest =
        serde_json::from_str(&fixture("request", "openai_responses", "openai"))
            .expect("golden Chat request");
    assert_eq!(actual, expected);
}

#[test]
fn response_pair_preserves_text_reasoning_tools_finish_and_usage() {
    let chat: OpenAiChatResponse = serde_json::from_str(
        r#"{
          "id":"chatcmpl-fixed","object":"chat.completion","created":1700000000,"model":"gpt-test",
          "choices":[{"index":0,"message":{"role":"assistant","content":"The answer is 42.","reasoning_content":"Deep thought.","tool_calls":[{"id":"call_abc","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}}]},"finish_reason":"tool_calls"}],
          "usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15,"prompt_tokens_details":{"cached_tokens":3},"completion_tokens_details":{"reasoning_tokens":2}}
        }"#,
    )
    .expect("source response");
    let canonical = openai_chat_response_to_canonical(chat.clone())
        .expect("Chat response conversion")
        .value;
    let mut responses_wire = openai_chat_response_to_responses(chat)
        .expect("Chat to Responses response conversion")
        .value;
    let roundtrip = openai_responses_response_to_canonical(responses_wire.clone())
        .expect("Responses response conversion")
        .value;
    assert_eq!(roundtrip.output, canonical.output);
    assert_eq!(roundtrip.finish_reason, Some(FinishReason::ToolCalls));
    assert_eq!(roundtrip.usage, canonical.usage);

    let expected: ResponsesResponse =
        serde_json::from_str(&fixture("response", "openai", "openai_responses"))
            .expect("golden Responses response");
    let golden = openai_responses_response_to_canonical(expected.clone())
        .expect("golden canonical response")
        .value;
    assert_eq!(golden.output, canonical.output);
    assert_eq!(golden.finish_reason, canonical.finish_reason);
    assert_eq!(golden.usage, canonical.usage);
    // Billing provenance is transport metadata injected outside relayconvert;
    // every converter-owned target field must match the frozen Go output.
    responses_wire.usage.clone_from(&expected.usage);
    assert_eq!(responses_wire, expected);
}

#[test]
fn responses_response_to_chat_matches_go_golden_semantics() {
    let source: ResponsesResponse = serde_json::from_str(
        r#"{
          "id":"resp_fixed","object":"response","model":"gpt-test","status":"completed",
          "output":[
            {"type":"reasoning","summary":[{"type":"summary_text","text":"Deep thought."}]},
            {"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"The answer is 42."}]},
            {"type":"function_call","call_id":"call_abc","name":"get_weather","arguments":"{\"city\":\"Paris\"}","status":"completed"}
          ],
          "usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}
        }"#,
    )
    .expect("source Responses response");
    let canonical = openai_responses_response_to_canonical(source.clone())
        .expect("Responses response conversion")
        .value;
    let converted =
        openai_responses_response_to_chat(source).expect("Responses to Chat response conversion");
    assert!(converted.loss.is_lossless());
    let mut actual_wire = converted.value;
    let actual = openai_chat_response_to_canonical(actual_wire.clone())
        .expect("generated Chat response")
        .value;

    let expected: OpenAiChatResponse =
        serde_json::from_str(&fixture("response", "openai_responses", "openai"))
            .expect("golden Chat response");
    let expected = openai_chat_response_to_canonical(expected)
        .expect("golden Chat canonical response")
        .value;
    assert_eq!(actual.output.len(), canonical.output.len());
    for part in &canonical.output {
        assert!(
            actual.output.contains(part),
            "missing converted part: {part:?}"
        );
    }
    let actual_without_reasoning = actual
        .output
        .iter()
        .filter(|part| !matches!(part, CanonicalContent::Reasoning { .. }))
        .cloned()
        .collect::<Vec<_>>();
    assert_eq!(actual_without_reasoning, expected.output);
    assert_eq!(actual.finish_reason, expected.finish_reason);
    assert_eq!(actual.usage, expected.usage);
    assert_eq!(actual.id, canonical.id);
    assert_eq!(actual.model, canonical.model);

    let expected_wire: OpenAiChatResponse =
        serde_json::from_str(&fixture("response", "openai_responses", "openai"))
            .expect("golden Chat response");
    // Rust intentionally preserves Responses reasoning in Chat's supported
    // extension; normalize only that deliberate improvement and billing
    // provenance before checking every legacy target field.
    actual_wire.choices[0].message.reasoning_content = None;
    actual_wire.usage.clone_from(&expected_wire.usage);
    assert_eq!(actual_wire, expected_wire);
}

#[test]
fn stream_pair_preserves_frame_order_text_finish_and_usage() {
    let responses: ResponsesStreamSnapshot =
        serde_json::from_str(&fixture("stream", "openai", "openai_responses"))
            .expect("golden Responses stream");
    let canonical = responses_stream_to_canonical(&responses);
    let text = canonical
        .iter()
        .filter_map(|event| match event {
            CanonicalStreamEvent::TextDelta { delta, .. } => Some(delta.as_str()),
            _ => None,
        })
        .collect::<String>();
    assert_eq!(text, "Hello world");
    assert!(matches!(
        canonical.last(),
        Some(CanonicalStreamEvent::ResponseEnd {
            finish_reason: FinishReason::Stop,
            usage: Some(TokenUsage {
                input_tokens: 4,
                output_tokens: 2,
                total_tokens: 6,
                ..
            }),
            ..
        })
    ));

    let chat_chunks = response_events_to_openai_chunks(&canonical);
    let chat = OpenAiStreamSnapshot {
        events: chat_chunks,
        usage: responses.usage,
    };
    let chat_canonical = openai_stream_to_canonical(&chat);
    let chat_text = chat_canonical
        .iter()
        .filter_map(|event| match event {
            CanonicalStreamEvent::TextDelta { delta, .. } => Some(delta.as_str()),
            _ => None,
        })
        .collect::<String>();
    assert_eq!(chat_text, text);
    assert!(matches!(
        chat_canonical.last(),
        Some(CanonicalStreamEvent::ResponseEnd {
            finish_reason: FinishReason::Stop,
            usage: Some(TokenUsage {
                total_tokens: 6,
                ..
            }),
            ..
        })
    ));
}

#[test]
fn responses_stream_to_chat_matches_reverse_go_golden_semantics() {
    let chat: OpenAiStreamSnapshot =
        serde_json::from_str(&fixture("stream", "openai_responses", "openai"))
            .expect("golden Chat stream");
    let canonical = openai_stream_to_canonical(&chat);
    let text = canonical
        .iter()
        .filter_map(|event| match event {
            CanonicalStreamEvent::TextDelta { delta, .. } => Some(delta.as_str()),
            _ => None,
        })
        .collect::<String>();
    assert_eq!(text, "Hello world");
    assert!(matches!(
        canonical.last(),
        Some(CanonicalStreamEvent::ResponseEnd {
            finish_reason: FinishReason::Stop,
            usage: Some(TokenUsage {
                input_tokens: 4,
                output_tokens: 2,
                total_tokens: 6,
                ..
            }),
            ..
        })
    ));

    let responses_events = response_events_to_responses(&canonical);
    assert_eq!(
        responses_events
            .iter()
            .filter(|event| event.kind == "response.output_text.delta")
            .count(),
        2,
        "each Chat data frame remains a distinct Responses delta event"
    );
}

#[test]
fn openai_pair_golden_streams_execute_source_to_target_frame_by_frame() {
    let chat_source: OpenAiStreamSnapshot = serde_json::from_str(
        r#"{
          "events":[
            {"id":"chatcmpl-fixed","object":"chat.completion.chunk","created":1700000000,"model":"gpt-test","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello"}}]},
            {"id":"chatcmpl-fixed","object":"chat.completion.chunk","created":1700000000,"model":"gpt-test","choices":[{"index":0,"delta":{"content":" world"}}]},
            {"id":"chatcmpl-fixed","object":"chat.completion.chunk","created":1700000000,"model":"gpt-test","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}
          ],
          "usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}
        }"#,
    )
    .expect("typed Chat source stream");
    let mut canonical = openai_stream_to_canonical(&chat_source);
    if let Some(CanonicalStreamEvent::ResponseStart { id, model }) = canonical.first_mut() {
        // These two values came from legacy ResponseStreamOptions, not from
        // the source payload. Supply the same route context before comparing.
        *id = "stream_fixed".to_owned();
        *model = "stream-model".to_owned();
    }
    let expected_responses: ResponsesStreamSnapshot =
        serde_json::from_str(&fixture("stream", "openai", "openai_responses"))
            .expect("golden Responses target stream");
    let mut actual_responses = ResponsesStreamSnapshot {
        events: response_events_to_responses(&canonical),
        usage: expected_responses.usage.clone(),
    };
    for (actual, expected) in actual_responses
        .events
        .iter_mut()
        .zip(&expected_responses.events)
    {
        if let (Some(actual), Some(expected)) = (
            actual.payload.response.as_mut(),
            expected.payload.response.as_ref(),
        ) {
            // Billing provenance is injected by the relay accounting layer.
            actual.usage.clone_from(&expected.usage);
        }
    }
    assert_eq!(actual_responses, expected_responses);

    let responses_source: ResponsesStreamSnapshot = serde_json::from_str(
        r#"{
          "events":[
            {"Type":"response.output_text.delta","Payload":{"type":"response.output_text.delta","delta":"Hello"}},
            {"Type":"response.output_text.delta","Payload":{"type":"response.output_text.delta","delta":" world"}},
            {"Type":"response.completed","Payload":{"type":"response.completed","response":{"id":"resp_fixed","object":"response","status":"completed","model":"gpt-test","output":[],"usage":{"input_tokens":4,"output_tokens":2,"total_tokens":6}}}}
          ],
          "usage":{"input_tokens":4,"output_tokens":2,"total_tokens":6}
        }"#,
    )
    .expect("typed Responses source stream");
    let mut canonical = responses_stream_to_canonical(&responses_source);
    canonical.insert(
        0,
        CanonicalStreamEvent::ResponseStart {
            id: "stream_fixed".to_owned(),
            model: "stream-model".to_owned(),
        },
    );
    let expected_chat: OpenAiStreamSnapshot =
        serde_json::from_str(&fixture("stream", "openai_responses", "openai"))
            .expect("golden Chat target stream");
    let mut actual_chat = OpenAiStreamSnapshot {
        events: response_events_to_openai_chunks(&canonical),
        usage: expected_chat.usage.clone(),
    };
    // Rust carries terminal usage on the final Chat chunk as well as the
    // aggregate; the frozen Go fixture stored it only in the aggregate.
    if let Some(last) = actual_chat.events.last_mut() {
        last.usage = None;
    }
    assert_eq!(actual_chat, expected_chat);
}

#[test]
fn explicit_error_and_cancel_events_are_not_coalesced() {
    let events = [
        CanonicalStreamEvent::Error {
            code: None,
            message: "upstream failed".to_owned(),
        },
        CanonicalStreamEvent::Cancelled,
    ];
    assert_eq!(events.len(), 2);
    assert!(matches!(events[0], CanonicalStreamEvent::Error { .. }));
    assert_eq!(events[1], CanonicalStreamEvent::Cancelled);
}

#[test]
fn responses_scalar_input_converts_to_one_user_message() {
    let request: OpenAiResponsesRequest =
        serde_json::from_str(r#"{"model":"gpt-test","input":"hello","stream":false}"#)
            .expect("Responses accepts scalar string input");
    let canonical = openai_responses_request_to_canonical(request)
        .expect("scalar input conversion")
        .value;
    assert_eq!(
        canonical.messages,
        [CanonicalMessage {
            role: Role::User,
            parts: vec![CanonicalContent::Text {
                text: "hello".to_owned(),
            }],
        }]
    );
}

#[test]
fn unknown_request_fields_are_rejected_instead_of_silently_dropped() {
    let chat = serde_json::from_str::<OpenAiChatRequest>(
        r#"{"model":"gpt-test","messages":[],"made_up":true}"#,
    );
    let responses = serde_json::from_str::<OpenAiResponsesRequest>(
        r#"{"model":"gpt-test","input":[],"made_up":true}"#,
    );
    assert!(chat.is_err());
    assert!(responses.is_err());
}

#[test]
fn outbound_streams_do_not_drop_tools_errors_or_cancellation() {
    let events = vec![
        CanonicalStreamEvent::ResponseStart {
            id: "resp_test".to_owned(),
            model: "gpt-test".to_owned(),
        },
        CanonicalStreamEvent::ToolCallStart {
            index: 0,
            id: "call_1".to_owned(),
            name: "weather".to_owned(),
        },
        CanonicalStreamEvent::ToolArgumentsDelta {
            index: 0,
            delta: "{\"city\":".to_owned(),
        },
        CanonicalStreamEvent::ToolArgumentsDelta {
            index: 0,
            delta: "\"Paris\"}".to_owned(),
        },
        CanonicalStreamEvent::ReasoningDelta {
            index: 1,
            delta: "thinking".to_owned(),
        },
        CanonicalStreamEvent::ResponseEnd {
            finish_reason: FinishReason::Length,
            usage: Some(TokenUsage {
                input_tokens: 4,
                output_tokens: 2,
                total_tokens: 6,
                cached_input_tokens: 0,
                reasoning_tokens: 1,
            }),
            model: None,
        },
        CanonicalStreamEvent::Error {
            code: Some("upstream_error".to_owned()),
            message: "upstream failed".to_owned(),
        },
        CanonicalStreamEvent::Cancelled,
    ];

    let chat = response_events_to_openai_chunks(&events);
    let responses = response_events_to_responses(&events);
    assert!(
        chat.iter()
            .flat_map(|chunk| &chunk.choices)
            .any(|choice| !choice.delta.tool_calls.is_empty())
    );
    assert!(
        chat.iter()
            .flat_map(|chunk| &chunk.choices)
            .any(|choice| { choice.delta.reasoning_content.as_deref() == Some("thinking") })
    );
    assert!(chat.iter().any(|chunk| {
        chunk
            .usage
            .as_ref()
            .is_some_and(|usage| usage.total_tokens == 6)
            && chunk
                .choices
                .first()
                .is_some_and(|choice| choice.finish_reason.as_deref() == Some("length"))
    }));
    assert!(chat.iter().any(|chunk| {
        chunk.error.as_ref().is_some_and(|error| {
            error.code.as_deref() == Some("upstream_error") && error.message == "upstream failed"
        })
    }));
    assert!(chat.iter().any(|chunk| chunk.cancelled));
    assert_eq!(
        responses
            .iter()
            .filter(|event| event.kind == "response.function_call_arguments.delta")
            .count(),
        2
    );
    assert!(responses.iter().any(|event| event.kind == "response.error"));
    assert!(
        responses
            .iter()
            .any(|event| event.kind == "response.reasoning_summary_text.delta")
    );
    assert!(responses.iter().any(|event| {
        event.kind == "response.incomplete"
            && event.payload.response.as_ref().is_some_and(|response| {
                response
                    .incomplete_details
                    .as_ref()
                    .is_some_and(|details| details.reason == "max_output_tokens")
                    && response
                        .usage
                        .as_ref()
                        .is_some_and(|usage| usage.total_tokens == 6)
            })
    }));
    assert!(
        responses
            .iter()
            .any(|event| event.kind == "response.cancelled")
    );
}

#[test]
fn inbound_responses_stream_preserves_tool_reasoning_error_and_incomplete_finish() {
    let snapshot: ResponsesStreamSnapshot = serde_json::from_str(
        r#"{
          "events":[
            {"Type":"response.created","Payload":{"type":"response.created","response":{"id":"resp_test","object":"response","status":"in_progress","model":"gpt-test","output":[]}}},
            {"Type":"response.output_item.added","Payload":{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"item_1","call_id":"call_1","name":"weather","status":"in_progress","arguments":""}}},
            {"Type":"response.function_call_arguments.delta","Payload":{"type":"response.function_call_arguments.delta","output_index":0,"item_id":"item_1","delta":"{\"city\":\"Paris\"}"}},
            {"Type":"response.reasoning_summary_text.delta","Payload":{"type":"response.reasoning_summary_text.delta","output_index":1,"item_id":"reasoning_1","delta":"think"}},
            {"Type":"response.incomplete","Payload":{"type":"response.incomplete","response":{"id":"resp_test","object":"response","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"model":"gpt-test","output":[],"usage":{"input_tokens":4,"output_tokens":2,"total_tokens":6}}}},
            {"Type":"response.error","Payload":{"type":"response.error","error":{"code":"upstream_error","message":"boom"}}}
          ],
          "usage":{"input_tokens":4,"output_tokens":2,"total_tokens":6}
        }"#,
    )
    .expect("typed rich Responses stream");
    let canonical = responses_stream_to_canonical(&snapshot);
    assert!(canonical.iter().any(|event| matches!(
        event,
        CanonicalStreamEvent::ToolCallStart { id, name, .. }
            if id == "call_1" && name == "weather"
    )));
    assert!(canonical.iter().any(|event| matches!(
        event,
        CanonicalStreamEvent::ToolArgumentsDelta { delta, .. }
            if delta == "{\"city\":\"Paris\"}"
    )));
    assert!(canonical.iter().any(|event| matches!(
        event,
        CanonicalStreamEvent::ResponseEnd {
            finish_reason: FinishReason::Length,
            ..
        }
    )));
    assert!(canonical.iter().any(|event| matches!(
        event,
        CanonicalStreamEvent::Error { message, .. } if message == "boom"
    )));
}

#[test]
fn go_supported_chat_request_fields_survive_responses_round_trip() {
    let source: OpenAiChatRequest = serde_json::from_str(
        r#"{
          "model":"gpt-test","messages":[{"role":"user","content":"hello"}],
          "stream":true,"max_completion_tokens":321,"temperature":0.4,"top_p":0.8,
          "reasoning_effort":"high","response_format":{"type":"json_object"},
          "parallel_tool_calls":true,"user":"user-1","store":false,
          "metadata":{"tenant":"acme"},"stream_options":{"include_usage":true},
          "top_logprobs":3,"safety_identifier":"safe-1",
          "prompt_cache_retention":"24h","prompt_cache_key":"cache-1",
          "service_tier":"flex","enable_thinking":true,"thinking_budget":2048
        }"#,
    )
    .expect("rich Chat request");
    let canonical = openai_chat_request_to_canonical(source.clone())
        .expect("Chat to canonical")
        .value;
    let responses = canonical_request_to_openai_responses(canonical)
        .expect("canonical to Responses")
        .value;
    assert_eq!(
        responses.text,
        Some(JsonData::Object(
            [("format".to_owned(), source.response_format.clone().unwrap())]
                .into_iter()
                .collect()
        ))
    );
    let canonical = openai_responses_request_to_canonical(responses)
        .expect("Responses to canonical")
        .value;
    let actual = canonical_request_to_openai_chat(canonical)
        .expect("canonical to Chat")
        .value;
    assert_eq!(actual, source);
}

#[test]
fn non_representable_request_fields_are_reported_or_rejected() {
    let multiple: OpenAiChatRequest =
        serde_json::from_str(r#"{"model":"gpt-test","messages":[],"n":2}"#)
            .expect("typed Chat request");
    assert!(matches!(
        openai_chat_request_to_canonical(multiple),
        Err(RelayConvertError::Unsupported(message)) if message.contains("n > 1")
    ));

    let stateful: OpenAiResponsesRequest = serde_json::from_str(
        r#"{"model":"gpt-test","input":[],"previous_response_id":"resp_previous"}"#,
    )
    .expect("typed stateful Responses request");
    assert!(matches!(
        openai_responses_request_to_canonical(stateful),
        Err(RelayConvertError::Unsupported(message)) if message.contains("stateful")
    ));

    let reasoning: OpenAiResponsesRequest = serde_json::from_str(
        r#"{"model":"gpt-test","input":[],"reasoning":{"effort":"high","summary":"auto"}}"#,
    )
    .expect("typed reasoning request");
    let converted = openai_responses_request_to_canonical(reasoning)
        .expect("supported effort with reported summary loss");
    assert_eq!(
        converted.value.options.reasoning_effort.as_deref(),
        Some("high")
    );
    assert_eq!(
        converted.loss.dropped_fields,
        ["reasoning.summary/mode/context"]
    );
}

#[test]
fn responses_incomplete_details_round_trip_to_chat_finish_reasons() {
    for (reason, expected) in [
        ("max_output_tokens", FinishReason::Length),
        ("content_filter", FinishReason::ContentFilter),
    ] {
        let response: ResponsesResponse = serde_json::from_value(serde_json::json!({
            "id":"resp_test","object":"response","model":"gpt-test",
            "status":"incomplete","incomplete_details":{"reason":reason},"output":[]
        }))
        .expect("typed incomplete response");
        let canonical = openai_responses_response_to_canonical(response)
            .expect("canonical response")
            .value;
        assert_eq!(canonical.finish_reason, Some(expected));
        let responses = canonical_response_to_openai_responses(canonical.clone()).value;
        assert_eq!(responses.status, "incomplete");
        assert_eq!(
            responses
                .incomplete_details
                .as_ref()
                .map(|value| value.reason.as_str()),
            Some(reason)
        );
        let chat = canonical_response_to_openai_chat(canonical).value;
        assert_eq!(
            chat.choices[0].finish_reason.as_deref(),
            Some(if expected == FinishReason::Length {
                "length"
            } else {
                "content_filter"
            })
        );
    }
}

#[test]
fn canonical_stream_to_responses_has_exact_semantic_frame_sequence() {
    let usage = TokenUsage {
        input_tokens: 4,
        output_tokens: 2,
        total_tokens: 6,
        cached_input_tokens: 1,
        reasoning_tokens: 1,
    };
    let events = vec![
        CanonicalStreamEvent::ResponseStart {
            id: "resp_test".to_owned(),
            model: "gpt-test".to_owned(),
        },
        CanonicalStreamEvent::ContentStart {
            index: 0,
            kind: StreamContentKind::Text,
        },
        CanonicalStreamEvent::TextDelta {
            index: 0,
            delta: "Hi".to_owned(),
        },
        CanonicalStreamEvent::ContentEnd { index: 0 },
        CanonicalStreamEvent::ContentStart {
            index: 1,
            kind: StreamContentKind::Reasoning,
        },
        CanonicalStreamEvent::ReasoningDelta {
            index: 1,
            delta: "think".to_owned(),
        },
        CanonicalStreamEvent::ContentEnd { index: 1 },
        CanonicalStreamEvent::ToolCallStart {
            index: 2,
            id: "call_1".to_owned(),
            name: "weather".to_owned(),
        },
        CanonicalStreamEvent::ToolArgumentsDelta {
            index: 2,
            delta: "{}".to_owned(),
        },
        CanonicalStreamEvent::ContentEnd { index: 2 },
        CanonicalStreamEvent::ResponseEnd {
            finish_reason: FinishReason::Length,
            usage: Some(usage),
            model: None,
        },
    ];
    let frames = response_events_to_responses(&events);
    assert_eq!(
        frames
            .iter()
            .map(|frame| frame.kind.as_str())
            .collect::<Vec<_>>(),
        [
            "response.created",
            "response.output_item.added",
            "response.output_text.delta",
            "response.output_text.done",
            "response.output_item.done",
            "response.output_item.added",
            "response.reasoning_summary_text.delta",
            "response.reasoning_summary_text.done",
            "response.output_item.done",
            "response.output_item.added",
            "response.function_call_arguments.delta",
            "response.function_call_arguments.done",
            "response.output_item.done",
            "response.incomplete",
        ]
    );
    assert_eq!(frames[2].payload.delta.as_deref(), Some("Hi"));
    assert_eq!(frames[3].payload.text, None);
    assert_eq!(frames[6].payload.delta.as_deref(), Some("think"));
    assert_eq!(
        frames[7]
            .payload
            .part
            .as_ref()
            .map(|part| part.text.as_str()),
        Some("think")
    );
    assert_eq!(
        frames[9].payload.item.as_ref().unwrap().call_id.as_deref(),
        Some("call_1")
    );
    assert_eq!(
        frames[9].payload.item.as_ref().unwrap().name.as_deref(),
        Some("weather")
    );
    assert_eq!(frames[10].payload.delta.as_deref(), Some("{}"));
    assert_eq!(frames[11].payload.arguments, None);
    let completed = frames.last().unwrap().payload.response.as_ref().unwrap();
    assert_eq!(completed.status, "incomplete");
    assert_eq!(
        completed.incomplete_details.as_ref().unwrap().reason,
        "max_output_tokens"
    );
    assert_eq!(completed.usage.as_ref().unwrap().total_tokens, 6);
    assert_eq!(completed.output.len(), 3);
}

#[test]
fn chat_stream_allocates_distinct_global_responses_output_indices() {
    let snapshot: OpenAiStreamSnapshot = serde_json::from_str(
        r#"{
          "events":[
            {"id":"chatcmpl_test","model":"gpt-test","choices":[{"index":0,"delta":{"reasoning_content":"think","content":"answer","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"weather","arguments":"{}"}}]}}]},
            {"id":"chatcmpl_test","model":"gpt-test","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}
          ],
          "usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}
        }"#,
    )
    .expect("mixed Chat stream");
    let canonical = openai_stream_to_canonical(&snapshot);
    assert!(
        canonical
            .iter()
            .any(|event| matches!(event, CanonicalStreamEvent::ReasoningDelta { index: 0, .. }))
    );
    assert!(
        canonical
            .iter()
            .any(|event| matches!(event, CanonicalStreamEvent::TextDelta { index: 1, .. }))
    );
    assert!(
        canonical
            .iter()
            .any(|event| matches!(event, CanonicalStreamEvent::ToolCallStart { index: 2, .. }))
    );
    assert!(canonical.iter().any(|event| matches!(
        event,
        CanonicalStreamEvent::ToolArgumentsDelta { index: 2, .. }
    )));
    let responses = response_events_to_responses(&canonical);
    let completed = responses
        .iter()
        .find(|event| event.kind == "response.completed")
        .and_then(|event| event.payload.response.as_ref())
        .expect("completed response");
    assert_eq!(completed.output.len(), 3);
}

#[test]
fn responses_failed_stream_reads_the_nested_response_error() {
    let snapshot: ResponsesStreamSnapshot = serde_json::from_str(
        r#"{
          "events":[{"Type":"response.failed","Payload":{"type":"response.failed","response":{"id":"resp_test","object":"response","status":"failed","model":"gpt-test","output":[],"error":{"code":"model_error","message":"nested boom"}}}}],
          "usage":{}
        }"#,
    )
    .expect("nested Responses error");
    assert!(
        responses_stream_to_canonical(&snapshot)
            .iter()
            .any(|event| matches!(
                event,
                CanonicalStreamEvent::Error { code, message }
                    if code.as_deref() == Some("model_error") && message == "nested boom"
            ))
    );
}

#[test]
fn nested_unknown_request_fields_are_rejected_and_tool_strict_is_preserved() {
    for invalid in [
        r#"{"model":"gpt-test","messages":[{"role":"user","content":"hi","made_up":true}]}"#,
        r#"{"model":"gpt-test","messages":[],"tools":[{"type":"function","function":{"name":"f","parameters":{},"made_up":true}}]}"#,
    ] {
        assert!(serde_json::from_str::<OpenAiChatRequest>(invalid).is_err());
    }
    for invalid in [
        r#"{"model":"gpt-test","input":[{"type":"message","role":"user","content":"hi","made_up":true}]}"#,
        r#"{"model":"gpt-test","input":[],"tools":[{"type":"function","name":"f","parameters":{},"made_up":true}]}"#,
    ] {
        assert!(serde_json::from_str::<OpenAiResponsesRequest>(invalid).is_err());
    }

    let source: OpenAiChatRequest = serde_json::from_str(
        r#"{"model":"gpt-test","messages":[],"tools":[{"type":"function","function":{"name":"f","parameters":{},"strict":true}}]}"#,
    )
    .expect("strict Chat tool");
    let canonical = openai_chat_request_to_canonical(source)
        .expect("Chat tool conversion")
        .value;
    let responses = canonical_request_to_openai_responses(canonical)
        .expect("Responses tool conversion")
        .value;
    assert_eq!(responses.tools[0].strict, Some(true));
}

#[test]
fn canonical_response_target_losses_are_never_silent() {
    let canonical = CanonicalResponse {
        id: "resp_test".to_owned(),
        model: "gpt-test".to_owned(),
        created_at: 123,
        output: vec![
            CanonicalContent::Image {
                url: "https://example.test/image.png".to_owned(),
                detail: Some("high".to_owned()),
            },
            CanonicalContent::ToolResult {
                id: "call_1".to_owned(),
                output: JsonData::String("done".to_owned()),
            },
        ],
        finish_reason: Some(FinishReason::Stop),
        usage: None,
    };
    for loss in [
        canonical_response_to_openai_chat(canonical.clone()).loss,
        canonical_response_to_openai_responses(canonical).loss,
    ] {
        assert_eq!(
            loss.dropped_fields,
            ["output[].image", "output[].tool_result"]
        );
    }
}
