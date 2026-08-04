# Channel tag operations oracle

Owned legacy endpoints:

- `POST /api/channel/tag/disabled`
- `POST /api/channel/tag/enabled`
- `PUT /api/channel/tag`
- `POST /api/channel/batch/tag`
- `GET /api/channel/tag/models`

Persistent effects are transactional over PostgreSQL `channels` and
`abilities`. Tag advisory locks plus ordered channel row locks serialize
concurrent writers across processes. A committed mutation then increments the
shared `lmm:channels:generation` Valkey key; a failed increment is returned as a
cache-invalidation failure without rolling back the durable PostgreSQL commit.

The production dashboard adapter accepts only a signed server-side user with
enabled status, administrator role (10 or greater), and the action-specific
channel permission; role-like request headers are never authorization input.
Audit entries and all non-tag channel operations are composed by the parent
migration router.

Notable frozen contracts: an empty tag on enable/disable or empty batch ids is
`200 {"success":false,"message":"参数错误"}`; missing `tag` for tag-models is
`400 {"success":false,"message":"tag不能为空"}`.
