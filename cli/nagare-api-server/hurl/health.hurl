# Liveness does no store IO; readiness reads a fresh bound head.
GET {{base_url}}/health/live
HTTP 200
[Asserts]
jsonpath "$.status" == "ok"

GET {{base_url}}/health/ready
HTTP 200
[Asserts]
jsonpath "$.status" == "ok"
