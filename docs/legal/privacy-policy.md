# 隐私政策（同步说明）

本文档用于同步前后端展示中的“隐私政策”内容来源。

## 当前后端默认文本（系统默认）

当未在配置中覆盖时，`/api/privacy-policy` 返回的正文来自 `apps/api-go/setting/system_setting/legal.go`，对应 `defaultLegalSettings.PrivacyPolicy`：

```text
# Privacy Policy

We process account, usage, support, and payment-related information needed to provide and secure the service.

## Third-party processing

Inputs and related request information may be sent to third-party AI service providers. Those providers may process or retain information under their own terms and privacy policies. Review their terms before submitting sensitive information.

## Retention and security

We retain information only as needed for service operation, security, support, legal compliance, and financial records, subject to applicable requirements. No online service can guarantee absolute security or uninterrupted availability.

## Payments and legal compliance

Payment processors may receive the information necessary to complete or verify a transaction. Prices, credits, limits, refunds, and payment availability may vary by location. Confirm that access, registration, payment, and use comply with applicable local law.
```

## 同步链路

- 前端展示路径：`/privacy-policy`
- API 入口：`GET /api/privacy-policy`
- 前端实现：`apps/web/src/features/legal/privacy-policy.tsx` → `apps/web/src/features/legal/api.ts`
- 路由控制：`apps/web/src/routes/privacy-policy.tsx`
- 后端来源：`apps/api-go/setting/system_setting/legal.go` 中的 `legal.privacy_policy` 默认值（`PrivacyPolicy`）

## 维护要求

- 要在管理后台更新隐私政策，请修改 `legal.privacy_policy` 配置项并确保前后端配置一致后再发布。
- Rust 迁移候选路径为 `apps/api-rust/src/migration_routes/control_public.rs`，读取 `legal.privacy_policy` 选项；当候选路径未挂载时不影响现有 Go 生产行为。
