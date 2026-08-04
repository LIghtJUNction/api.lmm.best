# Control-plane Go contract freeze

Source: ignored Go reference revision `5418ce6b6d45ed69167b0aad53f2f595e5bc8de9`.
This is a code-path freeze for follow-up isolated execution captures; it is not
a replacement for the existing flat replay fixtures. All rows run beneath the
API-wide `RouteTag(api)`, gzip, body-storage cleanup, and global API rate limit.
Successful JSON responses use `Content-Type: application/json; charset=utf-8`;
the process also emits the dynamic `X-New-API-Version` and
`X-Oneapi-Request-Id` headers. Normalize only the request id, start time,
generated task ids, and timestamps.

## Public content and status

| Request | Auth | Status and JSON contract | Postgres / Valkey effect | Failure and concurrency contract |
| --- | --- | --- | --- | --- |
| `GET /api/status` | none | `200 {success:true,message:"",data:{...}}`; content keys are option-backed and conditional: `api_info`, `announcements`, and `faq` appear only when their enable flags are true. | Reads in-memory option/settings snapshots; no write. | Holds `OptionMapRWMutex.RLock` while constructing the status map. No Valkey access. |
| `GET /api/notice` | none | `200 {success:true,message:"",data:<OptionMap.Notice>}` | no DB/cache write | Holds the same option read lock; no dependency failure branch. |
| `GET /api/about` | none | `200 {success:true,message:"",data:<OptionMap.About>}` | no DB/cache write | Same read-lock behavior as notice. |
| `GET /api/home_page_content` | none | `200 {success:true,message:"",data:<OptionMap.HomePageContent>}` | no DB/cache write | Same read-lock behavior as notice. |
| `GET /api/user-agreement` | none | `200 {success:true,message:"",data:<legal.UserAgreement>}` | no DB/cache write | settings getter only. |
| `GET /api/privacy-policy` | none | `200 {success:true,message:"",data:<legal.PrivacyPolicy>}` | no DB/cache write | settings getter only. |
| `GET /api/uptime/status` | none | no configured groups: `200 {success:true,message:"",data:[]}`; otherwise one result per configured group, preserving input order | no local DB/cache write; outbound HTTP only | Each group is fetched concurrently under a 10 s context timeout. An individual upstream error becomes that group's `{success:false,message:<error>,data:[]}` rather than failing the aggregate response. |

`GET /api/status/test` is admin-only: successful DB ping is
`200 {success:true,message:"Server is running",http_stats:<value>}`; failed
ping is HTTP `503 {success:false,message:"数据库连接失败"}`. It has no writes.

## Root option plane

All `/api/option/*` routes require `RootAuth`; an unauthenticated request is
rejected by middleware before the controller and has no data/cache effects.

| Request | Status and JSON contract | Postgres / Valkey effect | Failure/concurrency contract |
| --- | --- | --- | --- |
| `GET /api/option/` | `200 {success:true,message:"",data:[{key,value},...]}` plus synthetic `CompletionRatioMeta`; excludes `theme.frontend` and keys ending in `Token`, `Secret`, `Key`, `secret`, or `api_key`. | Values come from the in-memory option map; no write. | Uses the option **write lock** while enumerating/copying, then computes completion metadata after unlock. Map order is deliberately unspecified. |
| `PUT /api/option/` body `{"key":<string>,"value":<any>}` | malformed JSON: HTTP `400 {success:false,message:"无效的参数"}`. Valid update: `200 {success:true,message:""}`. Validation failures generally remain HTTP `200 {success:false,message:<exact validator text>}`. | `model.UpdateOption` persists the option row, updates the in-memory option map/settings projection, and writes a management audit log containing only `key`. No direct Valkey key is touched by the controller. | Payment-compliance fields cannot use this generic endpoint; positive invite quotas require compliance. OAuth/enabler, ratio, model, console JSON, rate-limit, and status-code settings validate before persistence. DB failure yields `200 {success:false,message:<db error>}` and no audit record. Serialize only through the option/model settings locks; do not expose an intermediate accepted response. |
| `POST /api/option/payment_compliance`, `GET /api/option/project-update`, and Waffo-Pancake routes | root-only control routes; capture separately with mocked external payment/update providers. | provider/options dependent | Do not claim success on dependency failure; response text is handler/provider-specific. |

## Admin groups

| Request | Status and JSON contract | Postgres / Valkey effect | Failure/concurrency contract |
| --- | --- | --- | --- |
| `GET /api/group/` | admin-only, `200 {success:true,message:"",data:[<group-name>...]}` | reads in-memory group-ratio copy; no write/cache | map iteration means order is unspecified. |
| `GET /api/prefill_group/?type=<optional>` | admin-only, `200 {success:true,message:"",data:[<prefill group>...]}` | SELECT `prefill_groups`; no Valkey effect | DB error is `200 {success:false,message:<db error>}`. |
| `POST /api/prefill_group/` body prefill group | successful insert: `200 {success:true,message:"",data:<inserted group with id>}` | duplicate-name SELECT then INSERT `prefill_groups`; no Valkey effect | invalid binding, empty name/type, duplicate, or DB error: `200 {success:false,message:<error>}`. Two concurrent creates can both pass the precheck; DB uniqueness constraint (if present) is the final arbiter. |
| `PUT /api/prefill_group/` body requires nonzero `id` | `200 {success:true,message:"",data:<updated group>}` | duplicate-name SELECT then UPDATE `prefill_groups`; no Valkey effect | missing ID/duplicate/DB error returns `200 {success:false,message:<error>}`. No optimistic version check. |
| `DELETE /api/prefill_group/:id` | `200 {success:true,message:"",data:null}` | DELETE `prefill_groups` by id; no Valkey effect | nonnumeric id/DB error uses `ApiError`: HTTP 200, `success:false`. Deleting a missing id remains controller-success unless the model returns an error. |

## System instances and tasks

All `/api/system-info/*` and `/api/system-task/*` routes require `RootAuth`.

| Request | Status and JSON contract | Postgres / Valkey effect | Failure/concurrency contract |
| --- | --- | --- | --- |
| `GET /api/system-info/instances` | `200 {success:true,message:"",data:[{node_name,status,stale_after_seconds:90,started_at,last_seen_at,info}]}` | SELECT `system_instances ORDER BY last_seen_at DESC`; no Valkey | `status` is computed against request-time epoch; DB error is HTTP 200 `success:false`. |
| `DELETE /api/system-info/stale-instances` | `200 {success:true,message:"",data:{deleted_count:<n>}}` | DELETE rows with `last_seen_at < now-90`; no Valkey | Concurrent heartbeat/upsert can win the race and survive; count is exact affected rows. |
| `DELETE /api/system-info/instances/:node_name` | stale row deleted: `200 {success:true,message:"",data:{deleted_count:1}}`; blank name or non-stale/missing: `200 {success:false,message:"node name is required"|"instance is not stale or no longer exists"}` | conditional DELETE by node and stale cutoff; no Valkey | Conditional predicate prevents deleting an instance refreshed concurrently. |
| `POST /api/system-task/log-cleanup?target_timestamp=<unix>` | zero/malformed timestamp: `200 {success:false,message:"target timestamp is required"}`; success returns `data:<SystemTaskResponse>`. | Reads active `log_cleanup`; inserts pending `system_tasks` with `active_key=log_cleanup`, payload `{target_timestamp,batch_size}`, then wakes runner. No Valkey. | Existing active task is returned rather than duplicated. Racy creates are backed by the unique active-key constraint; loser rereads and returns winner. IDs/timestamps/runner lock fields are dynamic. |
| `GET /api/system-task/current?type=<type>` | no type: `200 {success:false,message:"type is required"}`; absent active: `200 {success:true,message:"",data:null}`; otherwise task response. | SELECT active task (pending/running); no Valkey | DB failure is HTTP 200 `success:false`. |
| `GET /api/system-task/list?limit=<n>` | `200 {success:true,message:"",data:[<SystemTaskResponse>...]}` | SELECT `system_tasks ORDER BY id DESC LIMIT clamp(n,1..100; default 20)`; no Valkey | malformed/nonpositive limit falls to 20. |
| `GET /api/system-task/:task_id` | missing/not found: HTTP `404 {success:false,message:"task not found"}` (empty parameter has `task id is required` branch); found: `200` task response. | SELECT by unique task id; no Valkey | DB failure is HTTP 200 `success:false`. |

## User/admin task lists and remaining control routes

`GET /api/task/` requires admin and `GET /api/task/self` requires user auth.
Both return `200 {success:true,message:"",data:<PageInfo>}` and filter by
`p`, `page_size`, `platform`, `task_id`, `status`, `action`, timestamps, and
the admin-only `channel_id`. They read task rows and count separately; admin
mode additionally resolves user cache entries to fill usernames. The endpoints
do not write Postgres or Valkey, and concurrent creates/deletes can make
`items` and `total` observe different snapshots.

Other privileged control groups are route-frozen for later capture:

- Root: `/api/custom-oauth-provider/*`, `/api/performance/*`,
  `/api/ratio_sync/*`, `/api/channel/*`, `/api/authz/*`.
- Admin: `/api/vendors/*`, `/api/models/*`, `/api/deployments/*`,
  `/api/redemption/*`, `/api/log/*`, `/api/data/*` (with user-scoped variants).

They must retain middleware authorization before handler execution, the common
JSON envelope where their handlers use `ApiSuccess`/`ApiError`, and dependency
failures must be captured against isolated mocked providers rather than a live
control plane.
