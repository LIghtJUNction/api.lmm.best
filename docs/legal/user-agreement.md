# 用户协议（同步说明）

本文档用于同步前后端展示中的“用户协议”内容来源。

## 当前后端默认文本（系统默认）

当未在配置中覆盖时，`/api/user-agreement` 返回的正文来自 `apps/api-go/setting/system_setting/legal.go`，对应 `defaultLegalSettings.UserAgreement`：

```text
# User Agreement

You may use this service only for lawful purposes and only when you have the authorization required for the content and services you use.

## Third-party services

Requests and other inputs may be processed or retained by third-party AI service providers under their own terms and privacy policies. Their availability, terms, safeguards, and retention practices apply. Do not submit sensitive information or information that you are not authorized to share.

## Accounts and payments

Keep your account credentials secure. Usage limits, availability, pricing, credits, refunds, and payment methods may vary. A displayed balance or limit is not a guarantee of availability or a promise of future service.

## Compliance and availability

You are responsible for confirming that your access, registration, payment, and use comply with applicable law and third-party terms in your location. Service availability may vary by location. We may restrict or suspend access when required for security, compliance, or third-party obligations.
```

## 同步链路

- 前端展示路径：`/user-agreement`
- API 入口：`GET /api/user-agreement`
- 前端实现：`apps/web/src/features/legal/user-agreement.tsx` → `apps/web/src/features/legal/api.ts`
- 路由控制：`apps/web/src/routes/user-agreement.tsx`
- 后端来源：`apps/api-go/setting/system_setting/legal.go` 中的 `legal.user_agreement` 默认值（`UserAgreement`）

## 维护要求

- 要在管理后台更新用户协议，请修改 `legal.user_agreement` 配置项并确保前后端配置一致后再发布。
- Rust 迁移候选路径为 `apps/api-rust/src/migration_routes/control_public.rs`，读取 `legal.user_agreement` 选项；当候选路径未挂载时不影响现有 Go 生产行为。
