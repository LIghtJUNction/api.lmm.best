//! Provider-neutral relay model.
//!
//! This is intentionally smaller than any provider DTO: unsupported fields
//! are rejected or recorded by [`LossReport`] instead of being smuggled
//! through as an untyped JSON envelope.

use serde::{Deserialize, Serialize};

use super::JsonData;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Protocol {
    OpenAi,
    OpenAiResponses,
    Claude,
    Gemini,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FixtureKind {
    Request,
    Response,
    Stream,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    System,
    Developer,
    User,
    Assistant,
    Tool,
    Model,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CanonicalRequest {
    pub model: String,
    pub instructions: Vec<String>,
    pub messages: Vec<CanonicalMessage>,
    pub max_output_tokens: Option<u64>,
    pub temperature: Option<f64>,
    pub stream: bool,
    pub tools: Vec<CanonicalTool>,
    pub tool_choice: Option<CanonicalToolChoice>,
    pub options: RequestOptions,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct RequestOptions {
    pub top_p: Option<f64>,
    pub reasoning_effort: Option<String>,
    pub response_format: Option<JsonData>,
    pub parallel_tool_calls: Option<bool>,
    pub user: Option<JsonData>,
    pub store: Option<JsonData>,
    pub metadata: Option<JsonData>,
    pub stream_options: Option<JsonData>,
    pub top_logprobs: Option<i64>,
    pub safety_identifier: Option<JsonData>,
    pub prompt_cache_retention: Option<JsonData>,
    pub prompt_cache_key: Option<String>,
    pub service_tier: Option<String>,
    pub enable_thinking: Option<JsonData>,
    pub thinking_budget: Option<JsonData>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CanonicalMessage {
    pub role: Role,
    pub parts: Vec<CanonicalContent>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum CanonicalContent {
    Text {
        text: String,
    },
    Image {
        url: String,
        detail: Option<String>,
    },
    ToolCall {
        id: String,
        name: String,
        arguments: String,
    },
    ToolResult {
        id: String,
        output: JsonData,
    },
    Reasoning {
        text: String,
    },
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CanonicalTool {
    pub name: String,
    pub description: Option<String>,
    pub input_schema: JsonData,
    pub strict: Option<bool>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum CanonicalToolChoice {
    Auto,
    None,
    Required,
    Function { name: String },
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CanonicalResponse {
    pub id: String,
    pub model: String,
    pub created_at: i64,
    pub output: Vec<CanonicalContent>,
    pub finish_reason: Option<FinishReason>,
    pub usage: Option<TokenUsage>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FinishReason {
    Stop,
    Length,
    ToolCalls,
    ContentFilter,
    Cancelled,
    Error,
    Other,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct TokenUsage {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub total_tokens: u64,
    pub cached_input_tokens: u64,
    pub reasoning_tokens: u64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum CanonicalStreamEvent {
    ResponseStart {
        id: String,
        model: String,
    },
    ContentStart {
        index: usize,
        kind: StreamContentKind,
    },
    TextDelta {
        index: usize,
        delta: String,
    },
    ReasoningDelta {
        index: usize,
        delta: String,
    },
    ToolCallStart {
        index: usize,
        id: String,
        name: String,
    },
    ToolArgumentsDelta {
        index: usize,
        delta: String,
    },
    ContentEnd {
        index: usize,
    },
    ResponseEnd {
        finish_reason: FinishReason,
        usage: Option<TokenUsage>,
        model: Option<String>,
    },
    Error {
        code: Option<String>,
        message: String,
    },
    Cancelled,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StreamContentKind {
    Text,
    ToolCall,
    Reasoning,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct LossReport {
    pub dropped_fields: Vec<&'static str>,
    pub normalized_fields: Vec<&'static str>,
}

impl LossReport {
    pub fn is_lossless(&self) -> bool {
        self.dropped_fields.is_empty() && self.normalized_fields.is_empty()
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Converted<T> {
    pub value: T,
    pub loss: LossReport,
}
