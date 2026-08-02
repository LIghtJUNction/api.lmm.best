# Billing compatibility capture

This is a static, synthetic contract capture of the ignored legacy Go backup at
`5418ce6b6d45ed69167b0aad53f2f595e5bc8de9`. It intentionally contains no
credentials, live endpoint, or executable payment request. It is input for a
future isolated differential runner only: fresh synthetic SQLite/PostgreSQL,
disposable Valkey, and mocked ePay/FastPay/Stripe/Creem clients are required.

`subscription-contracts.json` freezes the observable subscription purchase and
callback contracts, including the order and subscription transitions which a
new implementation must preserve.

Important legacy limitation: the per-process `LockOrder(tradeNo)` mutex is not
cross-process; cross-process correctness therefore relies on the transactional
`SELECT ... FOR UPDATE` in `CompleteSubscriptionOrder` / `ExpireSubscriptionOrder`
and the unique `subscription_orders.trade_no` constraint.
