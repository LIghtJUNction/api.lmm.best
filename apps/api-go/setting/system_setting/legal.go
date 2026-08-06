package system_setting

import "github.com/QuantumNous/new-api/setting/config"

type LegalSettings struct {
	UserAgreement string `json:"user_agreement"`
	PrivacyPolicy string `json:"privacy_policy"`
}

var defaultLegalSettings = LegalSettings{
	UserAgreement: `# User Agreement

You may use this service only for lawful purposes and only when you have the authorization required for the content and services you use.

## Third-party services

Requests and other inputs may be processed or retained by third-party AI service providers under their own terms and privacy policies. Their availability, terms, safeguards, and retention practices apply. Do not submit sensitive information or information that you are not authorized to share.

## Accounts and payments

Keep your account credentials secure. Usage limits, availability, pricing, credits, refunds, and payment methods may vary. A displayed balance or limit is not a guarantee of availability or a promise of future service.

## Compliance and availability

You are responsible for confirming that your access, registration, payment, and use comply with applicable law and third-party terms in your location. Service availability may vary by location. We may restrict or suspend access when required for security, compliance, or third-party obligations.`,
	PrivacyPolicy: `# Privacy Policy

We process account, usage, support, and payment-related information needed to provide and secure the service.

## Third-party processing

Inputs and related request information may be sent to third-party AI service providers. Those providers may process or retain information under their own terms and privacy policies. Review their terms before submitting sensitive information.

## Retention and security

We retain information only as needed for service operation, security, support, legal compliance, and financial records, subject to applicable requirements. No online service can guarantee absolute security or uninterrupted availability.

## Payments and legal compliance

Payment processors may receive the information necessary to complete or verify a transaction. Prices, credits, limits, refunds, and payment availability may vary by location. Confirm that access, registration, payment, and use comply with applicable local law.`,
}

func init() {
	config.GlobalConfig.Register("legal", &defaultLegalSettings)
}

func GetLegalSettings() *LegalSettings {
	return &defaultLegalSettings
}
